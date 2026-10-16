import Foundation

/// Who a part belongs to, to check again before deleting it that the session has not started up again
enum DiskOwner: Equatable {
    case claude(String)
    case codex(String)
    case nobody
}

/// How a deletable part is deleted
enum DiskRemoval {
    /// Delete this directory (scratch files)
    case directory(String)
    /// Delete these git-ignored directories inside a worktree
    case ignoredDirectories(root: String, paths: [String])
    /// Remove the whole worktree with `git worktree remove`
    case worktree(root: String)
    /// Delete these git-ignored files and folders of a worktree, which only the user can say are not needed
    case ignoredEntries(root: String, paths: [String])
}

/// A folder or file inside a part, to show where the space goes
struct DiskEntry: Identifiable {
    let path: String
    let name: String
    let bytes: UInt64
    var id: String { path }
}

/// One kind of disk space a session occupies, with a verdict on whether it can be deleted
struct DiskItem: Identifiable {
    enum Kind {
        /// Temporary files the session wrote under /tmp
        case scratch
        /// node_modules, Python caches and the like in the session's worktree: ignored by git and rebuildable
        case dependencies
        /// The checked-out files of the session's worktree
        case worktree
        /// Files in the worktree that git ignores but that are not known to be rebuildable
        case ignored
        /// The conversation transcript
        case history
    }

    let id: String
    let kind: Kind
    /// Which worktree, for the kinds that live in one
    var subject: String?
    /// Where to look at it in Finder
    let path: String
    let bytes: UInt64
    /// Safe to delete now
    let cleanable: Bool
    /// Why it is or is not cleanable
    let note: String
    /// Nil for conversations, which are never deleted
    var removal: DiskRemoval?
    var owner: DiskOwner = .nobody
    /// What stands in the way of deleting it right now, if anything: the session is running, a process is working in it
    var blocker: String?
    /// The largest folders and files inside, largest first
    var entries: [DiskEntry] = []

    var baseTitle: String {
        switch kind {
        case .scratch: "Scratch files"
        case .dependencies: "Dependencies and caches"
        case .worktree: "Worktree files"
        case .ignored: "Ignored files"
        case .history: "Conversation history"
        }
    }

    var title: String { subject.map { "\(baseTitle) · \($0)" } ?? baseTitle }
}

extension DiskItem {
    /// Not deletable by default, but the user can choose to delete it
    var needsConsent: Bool { kind == .ignored && removal != nil && !cleanable }

    /// Deleting it removes the whole worktree, dependencies included
    var removesWorktree: Bool {
        if case .worktree = removal { return true }
        return false
    }
}

struct DiskSession: Identifiable {
    let id: String
    let source: Row.Source
    let title: String
    let detail: String
    let items: [DiskItem]

    var reclaimable: UInt64 { items.filter(\.cleanable).reduce(0) { $0 + $1.bytes } }
    var kept: UInt64 { items.filter { !$0.cleanable }.reduce(0) { $0 + $1.bytes } }
    var isHistoryOnly: Bool { items.allSatisfy { $0.kind == .history } }
}

struct DiskReport {
    let time: Date
    let seconds: Double
    /// Sessions that occupy something besides their transcript, the most reclaimable first
    let sessions: [DiskSession]
    /// Sessions that only have a transcript: not listed, but counted
    let historyOnlyCount: Int
    let historyOnlyBytes: UInt64

    /// The report without parts that were just deleted: the given items, and everything in a removed worktree
    func removing(items deleted: Set<String>, worktrees: Set<String>) -> DiskReport {
        var listed: [DiskSession] = []
        var historyOnlyCount = historyOnlyCount
        var historyOnlyBytes = historyOnlyBytes
        for session in sessions {
            let items = session.items.filter {
                !deleted.contains($0.id) && !(worktrees.contains($0.path) && $0.kind != .history && $0.kind != .scratch)
            }
            guard !items.isEmpty else { continue }
            let rest = DiskSession(id: session.id, source: session.source, title: session.title, detail: session.detail,
                                   items: items)
            if rest.isHistoryOnly {
                historyOnlyCount += 1
                historyOnlyBytes += rest.kept
            } else {
                listed.append(rest)
            }
        }
        listed.sort { ($0.reclaimable, $0.kept) > ($1.reclaimable, $1.kept) }
        return DiskReport(time: time, seconds: seconds, sessions: listed, historyOnlyCount: historyOnlyCount,
                          historyOnlyBytes: historyOnlyBytes)
    }
}
