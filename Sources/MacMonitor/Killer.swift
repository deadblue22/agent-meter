import Darwin
import Foundation

/// A process to end: PID plus start time. A PID may be reused after a refresh; if the start time differs, it is left alone.
struct ProcessRef: Hashable {
    let pid: Int32
    let startTime: UInt64
}

enum Killer {
    struct Outcome {
        /// Exited after SIGTERM
        var terminated = 0
        /// Still running after 3 seconds and ended with SIGKILL
        var forced = 0
        /// Still running after SIGKILL
        var failed = 0
        /// Already gone (or PID reused) before anything was sent
        var gone = 0

        var summary: String {
            var parts = ["ended \(Format.processes(terminated + forced))"]
            if forced > 0 { parts.append("\(forced) forced") }
            if gone > 0 { parts.append("\(gone) already gone") }
            if failed > 0 { parts.append("\(failed) could not be ended") }
            return parts.joined(separator: ", ")
        }
    }

    /// Sends SIGTERM, waits up to 3 seconds, then sends SIGKILL to whatever is left. Blocks the calling thread.
    static func terminate(_ refs: [ProcessRef]) -> Outcome {
        var outcome = Outcome()
        let targets = refs.filter { $0.pid != getpid() && isAlive($0) }
        outcome.gone = refs.count - targets.count
        for ref in targets { kill(ref.pid, SIGTERM) }

        var remaining = targets
        let deadline = Date().addingTimeInterval(3)
        while !remaining.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            remaining = remaining.filter(isAlive)
        }
        outcome.terminated = targets.count - remaining.count
        guard !remaining.isEmpty else { return outcome }

        for ref in remaining { kill(ref.pid, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)
        let stuck = remaining.filter(isAlive)
        outcome.forced = remaining.count - stuck.count
        outcome.failed = stuck.count
        return outcome
    }

    private static func isAlive(_ ref: ProcessRef) -> Bool {
        guard let process = Procs.read(ref.pid) else { return false }
        return process.startTime == ref.startTime && !process.isZombie
    }
}
