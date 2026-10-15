import Darwin
import Foundation

/// One-click cleanup: ends the processes of sessions that are over, without asking.
/// A process qualifies when its session is over (see `SessionNode.isOver`) and it is not a shared service.
enum Cleanup {
    /// Codex threads have no process of their own to watch, so a thread counts as over once it is archived
    /// or has had no activity for this long
    static let codexIdleLimit: TimeInterval = 24 * 3600

    /// A Claude Code CLI session idle this long is ended as a whole; it can be resumed with `claude --resume`
    static let cliIdleLimit: TimeInterval = 6 * 3600

    /// Sessions started with channels are message-driven bots that sit idle by design; they are never ended
    static let channelFlags = ["--channels", "--dangerously-load-development-channels"]

    /// Background services that a session may have happened to start, but that other sessions and apps rely on.
    /// They and every process running under them are left alone. Matched against the process name.
    static let sharedServices: Set<String> = [
        "colima", "limactl", "docker", "com.docker.backend", "qemu-system-aarch64", "qemu-system-x86_64", "vfkit",
        "ssh-agent", "gpg-agent", "adb",
    ]

    static func isTarget(_ item: ProcessItem, in node: SessionNode) -> Bool {
        node.isOver && !item.isSharedService && item.pid != getpid()
    }

    static func targets(in report: Report) -> [ProcessItem] {
        func walk(_ node: SessionNode) -> [ProcessItem] {
            node.processes.filter { isTarget($0, in: node) } + node.children.flatMap(walk)
        }
        return (report.claude + report.codex).flatMap(walk)
    }
}
