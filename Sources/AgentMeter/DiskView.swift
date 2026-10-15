import AppKit
import SwiftUI

/// The disk tab's state, kept by the parent so a scan survives switching tabs
struct DiskScan {
    var report: DiskReport?
    var running = false
    var progress = ""
    /// Result of the last delete
    var notice: String?
}

/// What a click on Delete would remove, shown to the user to confirm
struct DeletePlan: Identifiable {
    let id = UUID()
    let title: String
    let items: [DiskItem]

    var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    var message: String {
        func line(_ what: String, _ kind: DiskItem.Kind) -> String? {
            let group = items.filter { $0.kind == kind }
            return group.isEmpty ? nil : "\(what): \(group.count), \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))"
        }
        let parts = [line("Scratch files", .scratch), line("Dependencies and caches", .dependencies),
                     line("Worktree files, whole worktrees removed", .worktree)].compactMap { $0 }
        return parts.joined(separator: "\n")
            + "\n\nConversations are never deleted. Worktrees are removed with git worktree remove; their branches and commits stay. "
            + "Each part is checked again just before it is deleted and skipped if it is no longer safe. This cannot be undone."
    }
}

struct DiskView: View {
    @Binding var scan: DiskScan
    @State private var selection = Set<String>()
    /// Expanded sessions, remembered by ID
    @State private var expanded: Set<String>
    @State private var pending: DeletePlan?

    init(scan: Binding<DiskScan>, expanded: Set<String> = []) {
        _scan = scan
        _expanded = State(initialValue: expanded)
    }

    /// One line of the list: a session, or one kind of disk space of the session above it
    private struct Entry: Identifiable {
        let session: DiskSession
        let item: DiskItem?
        var id: String { item?.id ?? session.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if let report = scan.report {
                list(report)
                Divider()
                Text("Can delete is what is safe to remove now: scratch files and git-ignored dependencies and caches of sessions that are not running, and whole worktrees that have no uncommitted changes, whose commits are all on a remote branch and that hold no other ignored files. Conversations are never deleted. Deleting is permanent; every part is checked again right before it is deleted and skipped if it is no longer safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    if scan.running {
                        ProgressView(scan.progress)
                    } else {
                        Text("Scan the disk to see what each session leaves behind")
                            .font(.headline)
                        Text("Scratch files, worktrees, dependencies and caches, and which of them can be deleted. This reads every file under those folders and takes about half a minute.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .confirmationDialog(pending?.title ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { plan in
            Button("Delete \(Format.bytes(plan.bytes))", role: .destructive) {
                Task { await delete(plan) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.message)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    Task { await run() }
                } label: {
                    Label(scan.report == nil ? "Scan Disk" : "Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scan.running)
                let selected = selectedPlan
                Button(role: .destructive) {
                    pending = selected
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected == nil || scan.running)
                .help("Delete the deletable parts of the selected rows (⌘⌫)")
                let all = allPlan
                Button(role: .destructive) {
                    pending = all
                } label: {
                    Label(all.map { "Delete All (\(Format.bytes($0.bytes)))…" } ?? "Delete All…", systemImage: "trash.slash")
                }
                .disabled(all == nil || scan.running)
                .help("Delete every part marked deletable")
                if scan.running {
                    ProgressView().controlSize(.small)
                    Text(scan.progress).foregroundStyle(.secondary)
                } else if let report = scan.report {
                    Text("\(report.time.formatted(date: .omitted, time: .standard)) · scanned in \(String(format: "%.0f", report.seconds)) s")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let report = scan.report {
                let totals = Self.totals(report)
                HStack(spacing: 14) {
                    Text("Can delete \(Format.bytes(totals.reclaimable))")
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                    Text("Kept: \(Format.bytes(totals.review)) in worktrees with changes or ignored files, \(Format.bytes(totals.history)) of conversations")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let notice = scan.notice {
                        Text(notice)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(notice)
                    }
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    private static func totals(_ report: DiskReport) -> (reclaimable: UInt64, review: UInt64, history: UInt64) {
        var reclaimable: UInt64 = 0, review: UInt64 = 0, history = report.historyOnlyBytes
        for item in report.sessions.flatMap(\.items) {
            if item.cleanable { reclaimable += item.bytes }
            else if item.kind == .history { history += item.bytes }
            else { review += item.bytes }
        }
        return (reclaimable, review, history)
    }

    private func list(_ report: DiskReport) -> some View {
        let entries = visibleEntries(report)
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let claude = report.sessions.filter { $0.source == .claude }.count
        let codex = report.sessions.filter { $0.source == .codex }.count

        return List(selection: $selection) {
            Section {
                ForEach(entries) { entry in
                    DiskRowView(session: entry.session, item: entry.item, isExpanded: expanded.contains(entry.session.id)) {
                        toggle(entry.session.id)
                    }
                }
                if report.historyOnlyCount > 0 {
                    Text("\(report.historyOnlyCount) more sessions have nothing but their conversation: \(Format.bytes(report.historyOnlyBytes))")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Sessions · Claude Code \(claude) · Codex \(codex)")
                    Spacer()
                    DiskColumns(first: "Can delete", second: "Kept")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids.compactMap { byId[$0] })
        } primaryAction: { ids in
            // Double-clicking a session row expands or collapses it
            for id in ids where byId[id]?.item == nil { toggle(id) }
        }
    }

    @ViewBuilder
    private func menu(_ entries: [Entry]) -> some View {
        if entries.count == 1, let entry = entries.first {
            if let item = entry.item {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                Button("Copy Path") { copy(item.path) }
            } else {
                Button("Copy Session Name") { copy(entry.session.title) }
            }
        }
        if !entries.isEmpty, let report = scan.report, let plan = plan(for: entries, in: report) {
            Divider()
            Button("Delete \(Format.bytes(plan.bytes))…", role: .destructive) { pending = plan }
        }
    }

    /// Every session and every part, by row ID
    private func lookup(_ report: DiskReport) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for session in report.sessions {
            result[session.id] = Entry(session: session, item: nil)
            for item in session.items { result[item.id] = Entry(session: session, item: item) }
        }
        return result
    }

    private var selectedPlan: DeletePlan? {
        guard let report = scan.report, !selection.isEmpty else { return nil }
        let rows = lookup(report)
        return plan(for: selection.compactMap { rows[$0] }, in: report)
    }

    private var allPlan: DeletePlan? {
        guard let report = scan.report else { return nil }
        return plan(for: report.sessions.map { Entry(session: $0, item: nil) }, in: report)
    }

    /// The deletable parts among the given rows; selecting a session means all its deletable parts
    private func plan(for entries: [Entry], in report: DiskReport) -> DeletePlan? {
        var picked = entries.flatMap { $0.item.map { [$0] } ?? $0.session.items }.filter { $0.cleanable && $0.removal != nil }
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
        return DeletePlan(title: title, items: picked)
    }

    private func delete(_ plan: DeletePlan) async {
        scan.running = true
        scan.notice = nil
        scan.progress = "Deleting…"
        let binding = $scan
        let items = plan.items
        let outcome = await Task.detached(priority: .utility) {
            DiskCleaner.delete(items) { text in Task { @MainActor in binding.wrappedValue.progress = text } }
        }.value
        if let report = scan.report {
            scan.report = report.removing(items: Set(outcome.deleted.map(\.id)), worktrees: outcome.removedWorktrees)
        }
        var notice = "Deleted \(Format.bytes(outcome.freed))"
        if !outcome.skipped.isEmpty {
            let reasons = outcome.skipped.prefix(3).map { "\($0.item.title): \($0.reason)" }.joined(separator: "; ")
            notice += "; \(outcome.skipped.count) skipped (\(reasons)\(outcome.skipped.count > 3 ? "; …" : ""))"
        }
        scan.notice = notice
        scan.running = false
        selection.removeAll()
    }

    /// Sessions, each followed by its parts when expanded. Expanding only inserts or removes rows, as in the
    /// process list, which avoids the outline control's overlapping transition.
    private func visibleEntries(_ report: DiskReport) -> [Entry] {
        report.sessions.flatMap { session -> [Entry] in
            let own = Entry(session: session, item: nil)
            guard expanded.contains(session.id) else { return [own] }
            // Deletable parts first, the conversation last
            func rank(_ item: DiskItem) -> Int { item.cleanable ? 2 : item.kind == .history ? 0 : 1 }
            let items = session.items.sorted { (rank($0), $0.bytes) > (rank($1), $1.bytes) }
            return [own] + items.map { Entry(session: session, item: $0) }
        }
    }

    private func toggle(_ id: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func run() async {
        scan.running = true
        scan.notice = nil
        scan.progress = "Reading sessions…"
        let binding = $scan
        let report = await Task.detached(priority: .utility) {
            DiskScanner.scan { text in Task { @MainActor in binding.wrappedValue.progress = text } }
        }.value
        scan.report = report
        scan.running = false
    }
}

struct DiskRowView: View {
    let session: DiskSession
    let item: DiskItem?
    var isExpanded = false
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let item {
                Image(systemName: Self.icon(item.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.leading, 36)
            } else {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SourceBadge(source: session.source)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item?.title ?? session.title)
                    .fontWeight(item == nil ? .medium : .regular)
                    .lineLimit(1)
                Text(item?.note ?? session.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item?.note ?? session.detail)
            }
            Spacer(minLength: 12)
            if let item {
                DiskColumns(first: item.cleanable ? Format.bytes(item.bytes) : "",
                            second: item.cleanable ? "" : Format.bytes(item.bytes), highlight: item.cleanable)
            } else {
                DiskColumns(first: session.reclaimable > 0 ? Format.bytes(session.reclaimable) : "",
                            second: session.kept > 0 ? Format.bytes(session.kept) : "",
                            highlight: session.reclaimable > 0)
            }
        }
        .padding(.vertical, 2)
    }

    private static func icon(_ kind: DiskItem.Kind) -> String {
        switch kind {
        case .scratch: "tray"
        case .dependencies: "shippingbox"
        case .worktree: "folder"
        case .ignored: "eye.slash"
        case .history: "text.bubble"
        }
    }
}

/// The two size columns shared by the section header and the rows
struct DiskColumns: View {
    let first: String
    let second: String
    var highlight = false

    var body: some View {
        HStack(spacing: 0) {
            Text(first)
                .fontWeight(highlight ? .semibold : .regular)
                .foregroundStyle(highlight ? Color.green : Color.primary)
                .frame(width: 96, alignment: .trailing)
            Text(second)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
        .monospacedDigit()
    }
}
