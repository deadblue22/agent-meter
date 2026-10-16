import Foundation

/// What a click on Delete would remove, shown to the user to confirm
struct DeletePlan: Identifiable {
    let id = UUID()
    let title: String
    let items: [DiskItem]
    /// The user chose to delete git-ignored files that are not known to be disposable
    var consent = false

    var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    var message: String {
        func line(_ what: String, _ kind: DiskItem.Kind) -> String? {
            let group = items.filter { $0.kind == kind }
            return group.isEmpty ? nil : "\(what): \(group.count), \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))"
        }
        let parts = [line("Scratch files", .scratch), line("Dependencies and caches", .dependencies),
                     line("Worktree files, whole worktrees removed", .worktree)].compactMap { $0 }
        let ignored = items.filter(\.needsConsent)
        var warning = ""
        if !ignored.isEmpty {
            // The same name turns up in many worktrees; add them up
            var sizes: [String: UInt64] = [:]
            for entry in ignored.flatMap(\.entries) { sizes[entry.name, default: 0] += entry.bytes }
            let names = sizes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) (\(Format.bytes($0.value)))" }.joined(separator: ", ")
            let places = Set(ignored.map(\.path)).count
            warning = "\n\nYou chose to delete files that git ignores, so they exist only on this Mac"
                + (places > 1 ? ", in \(places) worktrees" : "") + ": \(names). Nothing else restores them."
        }
        if consent, parts.isEmpty {
            return warning.trimmingCharacters(in: .whitespacesAndNewlines) + " This cannot be undone. Each one is checked again just before it is deleted."
        }
        return parts.joined(separator: "\n") + warning
            + "\n\nConversations are never deleted. Worktrees are removed with git worktree remove; their branches and commits stay. "
            + "Each part is checked again just before it is deleted and skipped if it is no longer safe. This cannot be undone."
    }
}

/// Everything the Disk tab remembers: the scan, where the chart is centred and how it got there, what has been
/// collected for deletion. Kept by the window so none of it is lost when switching tabs.
@MainActor
final class DiskExplorer: ObservableObject {
    @Published private(set) var report: DiskReport?
    @Published private(set) var tree: DiskNode?
    @Published var running = false
    @Published var progress = ""
    /// How much of the measuring is done, 0 to 1
    @Published var fraction: Double?
    /// Result of the last delete, or why something could not be collected
    @Published var notice: String?
    /// Node IDs from the top down to what the chart is centred on
    @Published private(set) var trail: [String]
    @Published private(set) var past: [[String]] = []
    @Published private(set) var future: [[String]] = []
    @Published var hovered: String?
    /// Sessions and parts collected for deletion
    @Published private(set) var collected: [String] = []
    /// Folders listed on demand, by the ID of the folder they are in
    @Published private(set) var listed: [String: [DiskNode]] = [:]
    @Published private(set) var listing = Set<String>()

    private var index: [String: DiskNode] = [:]
    private var parents: [String: String] = [:]
    private var listedNodes: [String: DiskNode] = [:]
    private var listedParents: [String: String] = [:]

    init(report: DiskReport? = nil, trail: [String] = []) {
        self.trail = trail
        install(report, keepingListings: false)
    }

    // MARK: Lookup

    func node(_ id: String) -> DiskNode? { index[id] ?? listedNodes[id] }

    func children(of node: DiskNode) -> [DiskNode] {
        node.children.isEmpty ? (listed[node.id] ?? []) : node.children
    }

    /// The IDs from the top down to a node, itself included
    func ancestry(of id: String) -> [String] {
        var result: [String] = []
        var current: String? = id
        while let id = current, id != "root" {
            result.append(id)
            current = parents[id] ?? listedParents[id]
        }
        return result.reversed()
    }

    /// What the chart is centred on
    var focus: DiskNode? {
        guard let tree else { return nil }
        return trail.last.flatMap(node) ?? tree
    }

    /// Whether a node is collected, or lies inside something that is
    func isCollected(_ id: String, among set: Set<String>) -> Bool {
        var current: String? = id
        while let id = current {
            if set.contains(id) { return true }
            current = parents[id] ?? listedParents[id]
        }
        return false
    }

    /// What deleting a collected node would free: its deletable part, not all of it
    func freed(by node: DiskNode) -> UInt64 { node.deletableBytes > 0 ? node.deletableBytes : node.bytes }

    // MARK: Report

    /// Replaces the scan; navigation and collection start over
    func setReport(_ report: DiskReport?) {
        install(report, keepingListings: false)
        trail = []; past = []; future = []; collected = []; hovered = nil
    }

    /// Swaps in a newer report of the same scan, such as one that has measured a little more: where the chart is
    /// centred and what was collected stay
    func update(_ report: DiskReport) {
        install(report, keepingListings: true)
        if let missing = trail.firstIndex(where: { node($0) == nil }) { trail = Array(trail.prefix(missing)) }
        collected = collected.filter { node($0) != nil }
        if let hovered, node(hovered) == nil { self.hovered = nil }
    }

    private func install(_ report: DiskReport?, keepingListings: Bool) {
        self.report = report
        tree = report.map(DiskTree.build)
        index = [:]
        parents = [:]
        if !keepingListings { listed = [:]; listedNodes = [:]; listedParents = [:] }
        func add(_ node: DiskNode, parent: String?) {
            index[node.id] = node
            parents[node.id] = parent
            node.children.forEach { add($0, parent: node.id) }
        }
        if let tree { add(tree, parent: nil) }
    }

    // MARK: Navigation

    func navigate(_ target: [String]) {
        guard target != trail else { return }
        past.append(trail)
        future = []
        trail = target
        hovered = nil
        notice = nil
        listIfNeeded()
    }

    func goBack() {
        guard let previous = past.popLast() else { return }
        future.append(trail)
        trail = previous
        hovered = nil
        listIfNeeded()
    }

    func goForward() {
        guard let next = future.popLast() else { return }
        past.append(trail)
        trail = next
        hovered = nil
        listIfNeeded()
    }

    func goUp() {
        if !trail.isEmpty { navigate(Array(trail.dropLast())) }
    }

    /// Looks inside a slice or a row: centres the chart on it
    func open(_ id: String) {
        guard let node = node(id), node.kind != .others, node.kind != .root else { return }
        guard !children(of: node).isEmpty || node.expandable else {
            // Nothing inside: say what it is instead
            notice = node.detail.isEmpty ? "\(node.name): \(Format.bytes(node.bytes))" : node.detail
            return
        }
        navigate(ancestry(of: id))
    }

    /// Lists the focused folder and the biggest folders in it, so that deeper rings can be drawn
    func listIfNeeded() {
        guard let focus else { return }
        let targets = [focus] + children(of: focus).prefix(6).filter(\.expandable)
        for target in targets where target.expandable && target.children.isEmpty && listed[target.id] == nil && !listing.contains(target.id) {
            listing.insert(target.id)
            Task {
                let kids = await Task.detached(priority: .userInitiated) { DiskTree.listing(of: target) }.value
                store(kids, in: target)
            }
        }
    }

    func store(_ kids: [DiskNode], in target: DiskNode) {
        listed[target.id] = kids
        for kid in kids {
            listedNodes[kid.id] = kid
            listedParents[kid.id] = target.id
        }
        listing.remove(target.id)
        if target.id == focus?.id { listIfNeeded() }
    }

    // MARK: Collecting and deleting

    private func items(of node: DiskNode) -> [DiskItem] {
        if let item = node.item { return [item] }
        if let session = node.session { return session.items }
        return node.sessions.flatMap(\.items)
    }

    /// Puts a session or a part in the tray, if something in it can be deleted
    func collect(_ id: String) {
        guard !running else {
            notice = "Wait for the scan to finish before collecting."
            return
        }
        guard let node = node(id), !collected.contains(id) else { return }
        switch node.kind {
        case .session, .part:
            if plan(for: [id]) == nil {
                notice = node.kind == .session ? "Nothing in “\(node.name)” can be deleted now. Open it to see why."
                    : node.item?.kind == .history ? "Conversations are never deleted."
                    : "Not deletable: \(node.detail)"
                return
            }
        case .others:
            guard node.id == "others-sessions", plan(for: [id]) != nil else { notice = node.detail; return }
        case .folder:
            notice = "Only a whole part can be deleted. Collect the part this folder is in."
            return
        case .root:
            notice = "Collect a session or one of its parts."
            return
        }
        notice = nil
        // A session in the tray covers its deletable parts, but not git-ignored files, which are only ever collected
        // on their own
        let chosen = node.item?.needsConsent == true
        collected.removeAll { other in node.children.contains { $0.id == other && $0.item?.needsConsent != true } }
        if chosen || !collected.contains(where: { self.node($0)?.children.contains { $0.id == id } == true }) {
            collected.append(id)
        }
    }

    func uncollect(_ id: String) { collected.removeAll { $0 == id } }

    /// Everything that can be deleted
    func collectAll() {
        guard let tree else { return }
        collected = tree.children.filter { ($0.kind == .session || $0.id == "others-sessions") && $0.deletableBytes > 0 }.map(\.id)
    }

    /// The git-ignored files of a part, a session, or the sessions too small to be listed, which are kept unless the
    /// user says otherwise
    private func ignoredItems(of node: DiskNode) -> [DiskItem] {
        items(of: node).filter(\.needsConsent)
    }

    /// A plan to delete the git-ignored files of a part or of everything a session has, leaving out what cannot be
    /// deleted right now
    func consentPlan(for id: String) -> DeletePlan? {
        guard let node = node(id), node.kind == .part || node.kind == .session || node.id == "others-sessions" else { return nil }
        let items = ignoredItems(of: node).filter { $0.blocker == nil }
        guard !items.isEmpty else { return nil }
        let bytes = Format.bytes(items.reduce(0) { $0 + $1.bytes })
        return DeletePlan(title: "Delete \(bytes) of ignored files from “\(node.name)”?", items: items, consent: true)
    }

    /// Why the ignored files of a session or part cannot be deleted now, when there are some but all are held back
    func ignoredBlocker(for id: String) -> String? {
        guard let node = node(id), node.kind == .part || node.kind == .session || node.id == "others-sessions" else { return nil }
        let items = ignoredItems(of: node)
        guard !items.isEmpty, items.allSatisfy({ $0.blocker != nil }) else { return nil }
        return items.first?.blocker
    }

    var collectedPlan: DeletePlan? { plan(for: collected) }

    /// Everything that can be deleted, including sessions too small to be listed
    var allPlan: DeletePlan? {
        guard let report else { return nil }
        return plan(items: report.sessions.flatMap(\.items))
    }

    /// The deletable parts of the given sessions and parts. Git-ignored files are included only when their part is
    /// picked by itself: choosing a session, or everything, never takes them along.
    func plan(for ids: [String]) -> DeletePlan? {
        let nodes = ids.compactMap { node($0) }
        let byChoice = nodes.compactMap(\.item).filter(\.needsConsent)
        return plan(items: nodes.flatMap(items(of:)), chosen: byChoice)
    }

    private func plan(items all: [DiskItem], chosen: [DiskItem] = []) -> DeletePlan? {
        guard let report else { return nil }
        var picked = all.filter { $0.cleanable && $0.removal != nil } + chosen
        // A removed worktree takes its dependencies with it
        let trees = Set(picked.filter(\.removesWorktree).map(\.path))
        picked += report.sessions.flatMap(\.items).filter { $0.kind == .dependencies && $0.cleanable && trees.contains($0.path) }
        var seen = Set<String>()
        picked = picked.filter { seen.insert($0.id).inserted }
        guard !picked.isEmpty else { return nil }
        let ids = Set(picked.map(\.id))
        let sessions = report.sessions.filter { $0.items.contains { ids.contains($0.id) } }
        let bytes = Format.bytes(picked.reduce(0) { $0 + $1.bytes })
        let title = sessions.count == 1 ? "Delete \(bytes) from “\(sessions[0].title)”?" : "Delete \(bytes) from \(sessions.count) sessions?"
        return DeletePlan(title: title, items: picked, consent: picked.contains(where: \.needsConsent))
    }

    func delete(_ plan: DeletePlan) async {
        running = true
        notice = nil
        progress = "Deleting…"
        let items = plan.items, consent = plan.consent
        let outcome = await Task.detached(priority: .utility) {
            DiskCleaner.delete(items, consent: consent) { text in Task { @MainActor in self.progress = text } }
        }.value
        apply(outcome)
        if plan.consent, !outcome.deleted.isEmpty {
            notice = (notice ?? "") + ". Rescan to see whether the worktree itself can now be removed."
        }
        running = false
    }

    /// Drops what was deleted from the scan and says what happened
    func apply(_ outcome: DiskCleaner.Outcome) {
        if let report {
            setReport(report.removing(items: Set(outcome.deleted.map(\.id)), worktrees: outcome.removedWorktrees))
        }
        var text = "Deleted \(Format.bytes(outcome.freed))"
        if !outcome.skipped.isEmpty {
            let reasons = outcome.skipped.prefix(3).map { "\($0.item.title): \($0.reason)" }.joined(separator: "; ")
            text += "; \(outcome.skipped.count) skipped (\(reasons)\(outcome.skipped.count > 3 ? "; …" : ""))"
        }
        notice = text
    }

    /// Scans the disk. The chart and the list fill in while it goes, from reports of what has been measured so far.
    func scan() async {
        running = true
        notice = nil
        progress = "Reading sessions…"
        fraction = nil
        setReport(nil)
        let result = await Task.detached(priority: .utility) {
            DiskScanner.scan(
                progress: { text in Task { @MainActor in self.progress = text } },
                fraction: { value in Task { @MainActor in self.fraction = value } },
                partial: { report in Task { @MainActor in if self.running { self.update(report) } } })
        }.value
        update(result)
        running = false
        fraction = nil
    }
}
