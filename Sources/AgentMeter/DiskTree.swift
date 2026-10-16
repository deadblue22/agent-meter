import Foundation

/// One node of the hierarchy the ring chart shows: all sessions, a session, one of its parts, then folders
struct DiskNode: Identifiable {
    enum Kind { case root, session, part, folder, others }

    let id: String
    let kind: Kind
    var name: String
    /// Second line in the list
    var detail: String
    var bytes: UInt64
    /// How much of it can be deleted now
    var deletableBytes: UInt64
    var source: Row.Source?
    /// Where it is on disk, to show it in Finder
    var path: String?
    var children: [DiskNode] = []
    /// A folder whose contents can be listed on demand
    var expandable = false
    /// What a session or a part stands for, to delete it
    var session: DiskSession?
    var item: DiskItem?
    /// The sessions folded into an "others" node
    var sessions: [DiskSession] = []

    var isDeletable: Bool { bytes > 0 && deletableBytes == bytes }
}

enum DiskTree {
    static let sessionLimit = 40
    /// Folders smaller than this are not worth listing
    static let expandableBytes: UInt64 = 1 << 20

    /// The whole report as a tree: the largest sessions first, the rest folded into one node
    static func build(_ report: DiskReport) -> DiskNode {
        let all = report.sessions.map(sessionNode).sorted { $0.bytes > $1.bytes }
        var children = Array(all.prefix(sessionLimit))
        let rest = all.dropFirst(sessionLimit)
        if !rest.isEmpty {
            children.append(DiskNode(
                id: "others-sessions", kind: .others, name: "\(rest.count) smaller sessions",
                detail: "Each below \(Format.bytes(all[sessionLimit - 1].bytes))", bytes: rest.reduce(0) { $0 + $1.bytes },
                deletableBytes: rest.reduce(0) { $0 + $1.deletableBytes }, sessions: rest.compactMap(\.session)))
        }
        if report.historyOnlyCount > 0 {
            children.append(DiskNode(
                id: "history-only", kind: .others, name: "\(report.historyOnlyCount) sessions with only a conversation",
                detail: "Conversations are never deleted", bytes: report.historyOnlyBytes, deletableBytes: 0))
        }
        return DiskNode(
            id: "root", kind: .root, name: "All sessions", detail: "\(report.sessions.count) sessions with something to clean",
            bytes: children.reduce(0) { $0 + $1.bytes }, deletableBytes: children.reduce(0) { $0 + $1.deletableBytes },
            children: children)
    }

    static func sessionNode(_ session: DiskSession) -> DiskNode {
        let parts = session.items.map(partNode).sorted { $0.bytes > $1.bytes }
        return DiskNode(
            id: session.id, kind: .session, name: session.title, detail: session.detail,
            bytes: parts.reduce(0) { $0 + $1.bytes }, deletableBytes: parts.reduce(0) { $0 + $1.deletableBytes },
            source: session.source, children: parts, session: session)
    }

    static func partNode(_ item: DiskItem) -> DiskNode {
        let folders = item.entries.map { entry in
            DiskNode(id: item.id + "|" + entry.path, kind: .folder, name: entry.name, detail: "", bytes: entry.bytes,
                     deletableBytes: item.cleanable ? entry.bytes : 0, path: entry.path,
                     expandable: entry.bytes >= expandableBytes && isDirectory(entry.path))
        }
        // A part of a session that owns several worktrees is told apart by its worktree, so that leads
        let worktree = item.subject.flatMap { $0.split(separator: "/").first.map(String.init) }
        return DiskNode(id: item.id, kind: .part, name: worktree ?? item.title,
                        detail: worktree == nil ? item.note : item.baseTitle + " · " + item.note, bytes: item.bytes,
                        deletableBytes: item.cleanable ? item.bytes : 0, path: item.path, children: folders, item: item)
    }

    /// The contents of a folder, as nodes below `parent`
    static func listing(of parent: DiskNode) -> [DiskNode] {
        guard let path = parent.path else { return [] }
        return DiskFolders.list(path).map { entry in
            DiskNode(id: parent.id + "/" + entry.name, kind: .folder, name: entry.name, detail: "", bytes: entry.bytes,
                     deletableBytes: parent.isDeletable ? entry.bytes : 0, path: entry.path,
                     expandable: entry.isDirectory && entry.bytes >= expandableBytes)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Folder contents measured on demand, for drilling below what the scan recorded
enum DiskFolders {
    struct Entry {
        let name: String
        let path: String
        let bytes: UInt64
        let isDirectory: Bool
    }

    static func list(_ path: String, limit: Int = 120) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let lock = NSLock()
        var entries: [Entry] = []
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        for name in names {
            queue.addOperation {
                let child = path + "/" + name
                var st = stat()
                guard lstat(child, &st) == 0 else { return }
                let isDirectory = (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                let bytes = isDirectory ? DiskSize.of(child) : UInt64(st.st_blocks) * 512
                lock.withLock { entries.append(Entry(name: name, path: child, bytes: bytes, isDirectory: isDirectory)) }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return Array(entries.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}

/// One slice of the chart. Angles are radians, clockwise from twelve o'clock.
struct SunburstArc: Identifiable, Equatable {
    let id: String
    /// 1 is the ring next to the centre
    let ring: Int
    let start: Double
    let end: Double
    /// Shared by a slice and everything below it
    let hue: Double
    /// Something in it can be deleted; slices with nothing deletable are drawn dim
    let vivid: Bool
    let interactive: Bool
    /// The node the chart is centred on: a slice that is not drawn, but that the animation uses to let a slice open
    /// into the middle and the middle grow back out into a ring
    var isCenter = false
}

enum SunburstLayout {
    static let maxRings = 4
    /// Slices narrower than this are left out
    static let minSweep = 0.8 * Double.pi / 180

    /// The slices around `focus`: its children in ring 1, theirs in ring 2, and so on. `children` returns the
    /// children of a node, including any that were loaded on demand.
    static func arcs(for focus: DiskNode, children: (DiskNode) -> [DiskNode]) -> [SunburstArc] {
        var result: [SunburstArc] = []

        func place(_ nodes: [DiskNode], parentBytes: UInt64, start: Double, span: Double, ring: Int, hue: Double?) {
            let total = max(parentBytes, nodes.reduce(0) { $0 + $1.bytes })
            guard total > 0 else { return }
            var angle = start
            for (index, node) in nodes.enumerated() {
                let sweep = span * Double(node.bytes) / Double(total)
                defer { angle += sweep }
                guard sweep >= minSweep else { continue }
                let nodeHue = hue ?? self.hue(index: index, count: nodes.count)
                result.append(SunburstArc(id: node.id, ring: ring, start: angle, end: angle + sweep, hue: nodeHue,
                                          vivid: node.deletableBytes > 0, interactive: node.kind != .others))
                if ring < maxRings {
                    place(children(node), parentBytes: node.bytes, start: angle, span: sweep, ring: ring + 1, hue: nodeHue)
                }
            }
        }
        result.append(SunburstArc(id: focus.id, ring: 0, start: 0, end: 2 * .pi, hue: 0, vivid: false, interactive: false,
                                  isCenter: true))
        place(children(focus), parentBytes: focus.bytes, start: 0, span: 2 * .pi, ring: 1, hue: nil)
        return result
    }

    /// Neighbouring slices get neighbouring hues, running from purple through orange and green to blue
    static func hue(index: Int, count: Int) -> Double {
        let h = 0.80 - 0.92 * Double(index) / Double(max(count - 1, 1))
        return h < 0 ? h + 1 : h
    }
}

/// The chart's circle: a hole in the middle, then rings of equal width
struct SunburstGeometry {
    let center: CGPoint
    let outerRadius: CGFloat
    var holeRadius: CGFloat { outerRadius * 0.27 }
    var ringWidth: CGFloat { (outerRadius - holeRadius) / CGFloat(SunburstLayout.maxRings) }

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outerRadius = max(min(size.width, size.height) / 2 - 8, 1)
    }

    enum Hit: Equatable {
        case center
        case arc(String)
        case none
    }

    func hit(_ point: CGPoint, in arcs: [SunburstArc]) -> Hit {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let distance = CGFloat((dx * dx + dy * dy).squareRoot())
        if distance < holeRadius { return .center }
        guard distance <= outerRadius else { return .none }
        let ring = Int((distance - holeRadius) / ringWidth) + 1
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return arcs.first { $0.ring == ring && $0.start <= angle && angle < $0.end }.map { .arc($0.id) } ?? .none
    }
}
