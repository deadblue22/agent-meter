import Darwin
import Foundation

/// A process that ending a session would end
struct QuitTarget: Hashable {
    let ref: ProcessRef
    let name: String
    let memory: UInt64
}

/// What a forced quit of a session from the Disk tab would end, shown to the user to confirm
struct QuitPlan: Identifiable {
    let id = UUID()
    let sessionTitle: String
    let source: Row.Source
    let targets: [QuitTarget]
    /// Shared background services (a container VM, an agent) the session started; other sessions rely on them, so they stay
    let sharedKept: [String]

    var memory: UInt64 { targets.reduce(0) { $0 + $1.memory } }
    var title: String { "Force quit “\(sessionTitle)”?" }

    var message: String {
        let listed = targets.prefix(6).map { "\($0.name) (pid \($0.ref.pid))" }.joined(separator: ", ")
        let more = targets.count > 6 ? " and \(targets.count - 6) more" : ""
        var text = "Ends \(Format.processes(targets.count)), \(Format.bytes(memory)) in total: \(listed)\(more). "
            + "Whatever the session is doing stops at once, and so do the services it started in the background."
        if !sharedKept.isEmpty {
            text += " Shared services stay running: \(Set(sharedKept).sorted().joined(separator: ", "))."
        }
        text += source == .codex
            ? " The thread itself lives in the Codex app and is not affected."
            : " The conversation is kept and can be resumed later: reopen it in the desktop app, or run `claude --resume` for a CLI session."
        return text + " The disk is scanned again afterwards."
    }
}

/// Finds what belongs to a session so that it can be ended and its files deleted: the processes the process list
/// attributes to it, those left running in its worktrees, and any other process working in a folder of the session.
enum SessionQuit {
    /// Samples the processes for a second and a half, so it must not run on the main thread
    static func plan(for session: DiskSession) -> QuitPlan {
        let report = Collector.collect()
        var found: [Int32: QuitTarget] = [:]
        var shared: [String] = []

        func add(_ item: ProcessItem) {
            guard item.pid != getpid() else { return }
            if item.isSharedService { shared.append(item.name); return }
            found[item.pid] = QuitTarget(ref: ProcessRef(pid: item.pid, startTime: item.startTime), name: item.name, memory: item.memory)
        }
        func take(_ node: SessionNode) {
            node.processes.forEach(add)
            node.children.forEach(take)
        }
        func find(_ id: String, in nodes: [SessionNode]) -> SessionNode? {
            for node in nodes {
                if node.id == id { return node }
                if let inner = find(id, in: node.children) { return inner }
            }
            return nil
        }

        // The session's own group: the session process and what it started, or what it left behind
        if let node = find(session.id, in: report.claude + report.codex) { take(node) }
        // Detached processes in its worktrees, which are listed under the worktree when no session works in it any more
        let folders = session.items.filter { $0.kind != .history }.map(\.path)
        for node in report.claude where node.isUnclaimed {
            if folders.contains(String(node.id.dropFirst("worktree-".count))) { take(node) }
        }
        // Anything else that has one of its folders as the working directory
        for pid in Procs.allPIDs() where found[pid] == nil && pid != getpid() {
            guard let cwd = Procs.workingDirectory(pid), folders.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }),
                  let process = Procs.read(pid), !process.isZombie else { continue }
            if Cleanup.sharedServices.contains(process.name) { shared.append(process.name); continue }
            found[pid] = QuitTarget(ref: ProcessRef(pid: pid, startTime: process.startTime), name: process.name, memory: process.memory)
        }
        return QuitPlan(sessionTitle: session.title, source: session.source,
                        targets: found.values.sorted { $0.memory > $1.memory }, sharedKept: shared)
    }
}
