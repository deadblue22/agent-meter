import Foundation

/// `AgentMeter --dump`: samples once and prints the session tree, sorted by memory, as plain text.
/// `AgentMeter --dump-disk`: scans the disk and prints what each session occupies.
enum Dump {
    static func runDisk() {
        let report = DiskScanner.scan { _ in }
        let reclaimable = report.sessions.reduce(0) { $0 + $1.reclaimable }
        let kept = report.sessions.reduce(0) { $0 + $1.kept }
        print("Scanned in \(String(format: "%.1f", report.seconds)) s: reclaimable \(Format.bytes(reclaimable)), "
              + "kept \(Format.bytes(kept)) in \(report.sessions.count) sessions; "
              + "\(report.historyOnlyCount) more have only history (\(Format.bytes(report.historyOnlyBytes)))")
        for session in report.sessions.prefix(500) {
            print("\n\(session.source == .codex ? "[Codex] " : "[Claude]") \(session.title)  [\(session.detail)]  "
                  + "reclaimable \(Format.bytes(session.reclaimable))  kept \(Format.bytes(session.kept))")
            for item in session.items {
                print("    \(item.cleanable ? "✓" : "·") \(item.title.padding(toLength: 44, withPad: " ", startingAt: 0)) "
                      + "\(Format.bytes(item.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.note)")
            }
        }
    }

    static func run() {
        let report = Collector.collect()
        let m = report.memory
        print("CPU \(Format.percent(report.cpuTotal))%, memory \(Format.bytes(m.used)) / \(Format.bytes(m.total)), "
              + "swap \(Format.bytes(m.swapUsed)) / \(Format.bytes(m.swapTotal)), sampled over \(String(format: "%.1f", report.sampleSeconds)) s")
        section("Claude Code", report.claude)
        section("Codex", report.codex)
        let others = report.others.sorted { $0.memory > $1.memory }
        print("\nNot attributed to any session: \(Format.processes(others.count)), \(Format.bytes(others.reduce(0) { $0 + $1.memory }))")
        for item in others.prefix(8) { process(item, indent: 1) }
        let targets = Cleanup.targets(in: report)
        print("\nClean Up would end \(Format.processes(targets.count)), \(Format.bytes(targets.reduce(0) { $0 + $1.memory }))")
        for item in targets.sorted(by: { $0.memory > $1.memory }) { process(item, indent: 1) }
    }

    private static func section(_ title: String, _ nodes: [SessionNode]) {
        let memory = nodes.reduce(0) { $0 + $1.memory }
        let cpu = nodes.reduce(0) { $0 + $1.cpu }
        print("\n== \(title): \(nodes.count) groups, \(Format.bytes(memory)), CPU \(Format.percent(cpu))%")
        for node in nodes.sorted(by: { $0.memory > $1.memory }) { session(node, indent: 1) }
    }

    private static func session(_ node: SessionNode, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        print("\(pad)\(node.isBusy ? "●" : "○") \(node.title)  [\(node.detail)]  \(Format.processes(node.processCount))  "
              + "CPU \(Format.percent(node.cpu))%  \(Format.bytes(node.memory))")
        for child in node.children.sorted(by: { $0.memory > $1.memory }) { session(child, indent: indent + 1) }
        for item in node.processes.sorted(by: { $0.memory > $1.memory }).prefix(4) {
            process(item, indent: indent + 1, mark: node.isOver ? (Cleanup.isTarget(item, in: node) ? "[clean up] " : "[kept] ") : "")
        }
    }

    private static func process(_ item: ProcessItem, indent: Int, mark: String = "") {
        let pad = String(repeating: "  ", count: indent)
        print("\(pad)- \(mark)\(item.pid) \(item.name)  CPU \(Format.percent(item.cpu))%  \(Format.bytes(item.memory))  "
              + String(item.command.prefix(90)))
    }
}
