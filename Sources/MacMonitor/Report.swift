import Foundation

struct ProcessItem: Identifiable {
    let pid: Int32
    let name: String
    let command: String
    /// Percent of one core (100 = one core fully busy), the same scale as top and Activity Monitor
    let cpu: Double
    let memory: UInt64
    /// Start time in seconds; checked before ending a process to make sure the PID was not reused
    let startTime: UInt64

    var id: Int32 { pid }
}

struct SessionNode: Identifiable {
    enum Kind {
        case claude, codex, claudeApp, codexApp
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let isBusy: Bool
    var processes: [ProcessItem]
    var children: [SessionNode]
    /// The session has ended; only processes it started are left
    var isLeftover = false

    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } + children.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } + children.reduce(0) { $0 + $1.memory } }
    var processCount: Int { processes.count + children.reduce(0) { $0 + $1.processCount } }
}

struct Report {
    let time: Date
    let sampleSeconds: Double
    /// Percent of all cores
    let cpuTotal: Double
    let memory: MemoryInfo
    let claude: [SessionNode]
    let codex: [SessionNode]
    /// Processes not attributed to any session (current user's processes only)
    let others: [ProcessItem]
}

enum Collector {
    static let sampleSeconds = 1.5

    private enum Owner: Hashable {
        case claude(String)
        case codex(String)
        case claudeApp
        case codexApp
        case unattributed
    }

    private static let claudeSessionKey = "CLAUDE_CODE_SESSION_ID"
    private static let codexThreadKey = "CODEX_THREAD_ID"

    /// Samples twice (1.5 s apart) to compute CPU usage, then groups processes by session. Blocks the calling thread.
    static func collect() -> Report {
        let pids = Procs.allPIDs()
        let ticksBefore = SystemStats.cpuTicks()
        let clockBefore = DispatchTime.now().uptimeNanoseconds
        var before: [Int32: RawProcess] = [:]
        for pid in pids { before[pid] = Procs.read(pid) }

        Thread.sleep(forTimeInterval: sampleSeconds)

        let ticksAfter = SystemStats.cpuTicks()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clockBefore)
        var processes: [Int32: RawProcess] = [:]
        for pid in Procs.allPIDs() { processes[pid] = Procs.read(pid) }

        var cpu: [Int32: Double] = [:]
        for (pid, now) in processes {
            // A process missing from the first sample (or with a reused PID) started during the interval,
            // so all of its CPU time was spent within the interval
            let previous = before[pid].flatMap { $0.startTime == now.startTime ? $0.cpuNanos : nil } ?? 0
            cpu[pid] = Double(now.cpuNanos &- min(previous, now.cpuNanos)) / elapsed * 100
        }

        var arguments: [Int32: [String]] = [:]
        var environment: [Int32: [String: String]] = [:]
        for pid in processes.keys {
            if let info = Procs.arguments(pid, environmentKeys: [claudeSessionKey, codexThreadKey]) {
                arguments[pid] = info.arguments
                environment[pid] = info.environment
            }
        }
        var children: [Int32: [Int32]] = [:]
        for process in processes.values { children[process.ppid, default: []].append(process.pid) }

        let claudeSessions = ClaudeSessions.running().filter { processes[$0.key] != nil }
        let sessionIdByPid = claudeSessions.mapValues(\.sessionId)

        func executable(_ pid: Int32) -> String { arguments[pid]?.first ?? processes[pid]?.name ?? "" }

        // Attribution rules, first match wins:
        // 1. The process is a Claude Code session process itself
        // 2. Its environment carries a session ID (injected by Claude Code or Codex into tool commands);
        //    this also catches leftovers that were detached from their parent
        // 3. The desktop app's `disclaimer` launcher belongs to the session it launched
        // 4. Walk up the parent chain
        // 5. The Claude desktop app and the Codex / ChatGPT app themselves
        var owners: [Int32: Owner] = [:]
        func owner(_ pid: Int32, depth: Int = 0) -> Owner {
            if let cached = owners[pid] { return cached }
            guard depth < 64, let process = processes[pid] else { return .unattributed }
            var result: Owner = .unattributed
            let env = environment[pid] ?? [:]
            let exe = executable(pid)
            if let sessionId = sessionIdByPid[pid] {
                result = .claude(sessionId)
            } else if let sessionId = env[claudeSessionKey] {
                result = .claude(sessionId)
            } else if let threadId = env[codexThreadKey] {
                result = .codex(threadId)
            } else if process.name == "disclaimer",
                      let session = children[pid]?.compactMap({ sessionIdByPid[$0] }).first {
                result = .claude(session)
            } else {
                if process.ppid > 1 { result = owner(process.ppid, depth: depth + 1) }
                if result == .unattributed {
                    if exe.contains("/Claude.app/") {
                        result = .claudeApp
                    } else if exe.contains("/ChatGPT.app/") || exe.contains("@openai/codex") || exe.hasSuffix("/codex") {
                        result = .codexApp
                    }
                }
            }
            owners[pid] = result
            return result
        }

        var grouped: [Owner: [ProcessItem]] = [:]
        for (pid, process) in processes {
            let item = ProcessItem(
                pid: pid,
                name: displayName(pid: pid, process: process, arguments: arguments[pid], isSession: sessionIdByPid[pid] != nil),
                command: arguments[pid]?.joined(separator: " ") ?? process.name,
                cpu: cpu[pid] ?? 0,
                memory: process.memory,
                startTime: process.startTime
            )
            grouped[owner(pid), default: []].append(item)
        }

        // Claude Code: running sessions, plus processes left behind by sessions that have ended
        let sessionById = Dictionary(claudeSessions.values.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var claudeNodes: [SessionNode] = []
        var codexIds = Set<String>()
        for (key, items) in grouped {
            switch key {
            case .claude(let sessionId):
                if let session = sessionById[sessionId] {
                    claudeNodes.append(SessionNode(
                        id: "claude-\(sessionId)",
                        kind: .claude,
                        title: session.name.isEmpty ? (session.cwd as NSString).lastPathComponent : session.name,
                        detail: [shortPath(session.cwd), session.entrypoint == "claude-desktop" ? "Desktop" : "CLI",
                                 session.status == "busy" ? "Running" : "Idle"].joined(separator: " · "),
                        isBusy: session.status == "busy",
                        processes: items,
                        children: []
                    ))
                } else {
                    claudeNodes.append(SessionNode(
                        id: "claude-\(sessionId)",
                        kind: .claude,
                        title: ClaudeSessions.title(ofEndedSession: sessionId) ?? "Session \(sessionId.prefix(8))",
                        detail: "Session ended; these processes were left running",
                        isBusy: false,
                        processes: items,
                        children: [],
                        isLeftover: true
                    ))
                }
            case .codex(let threadId):
                codexIds.insert(threadId)
            case .claudeApp:
                claudeNodes.append(SessionNode(id: "claude-app", kind: .claudeApp, title: "Claude desktop app",
                                               detail: "UI, GPU, network and other helper processes", isBusy: false,
                                               processes: items, children: []))
            case .codexApp, .unattributed:
                break
            }
        }

        // Codex: threads with processes form a tree by parent; ancestors without processes are kept to hold their sub-agents
        let threads = CodexThreads.load(codexIds)
        var codexNodes: [String: SessionNode] = [:]
        for (id, thread) in threads {
            let title: String
            if let nickname = thread.nickname, !nickname.isEmpty {
                title = "Sub-agent \(nickname)" + (thread.role.map { " (\($0))" } ?? "")
            } else {
                title = thread.title.isEmpty ? "Thread \(id.prefix(8))" : String(thread.title.prefix(80))
            }
            codexNodes[id] = SessionNode(id: "codex-\(id)", kind: .codex, title: title,
                                         detail: shortPath(thread.cwd), isBusy: false,
                                         processes: grouped[.codex(id)] ?? [], children: [])
        }
        for id in codexIds where threads[id] == nil {
            codexNodes[id] = SessionNode(id: "codex-\(id)", kind: .codex, title: "Thread \(id.prefix(8))",
                                         detail: "Not found in the Codex database", isBusy: false,
                                         processes: grouped[.codex(id)] ?? [], children: [])
        }
        func build(_ id: String) -> SessionNode {
            var node = codexNodes[id]!
            node.children = threads.values.filter { $0.parentId == id }.map { build($0.id) }
            return node
        }
        let roots = codexNodes.keys.filter { threads[$0]?.parentId.flatMap { codexNodes[$0] } == nil }
        var codexTree = roots.map(build)
        if let app = grouped[.codexApp] {
            codexTree.append(SessionNode(id: "codex-app", kind: .codexApp, title: "Codex / ChatGPT app",
                                         detail: "App UI and codex app-server", isBusy: false,
                                         processes: app, children: []))
        }

        var cpuTotal = 0.0
        if let a = ticksBefore, let b = ticksAfter {
            let busy = Double(b.user &- a.user) + Double(b.nice &- a.nice) + Double(b.system &- a.system)
            let all = busy + Double(b.idle &- a.idle)
            cpuTotal = all > 0 ? busy / all * 100 : 0
        }

        return Report(
            time: Date(),
            sampleSeconds: elapsed / 1e9,
            cpuTotal: cpuTotal,
            memory: SystemStats.memory() ?? MemoryInfo.empty,
            claude: claudeNodes,
            codex: codexTree,
            others: grouped[.unattributed] ?? []
        )
    }

    private static func displayName(pid: Int32, process: RawProcess, arguments: [String]?, isSession: Bool) -> String {
        if isSession { return "Claude Code session process" }
        if process.name == "disclaimer" { return "disclaimer (desktop launcher)" }
        let base = arguments?.first.map { ($0 as NSString).lastPathComponent } ?? ""
        return base.isEmpty ? process.name : base
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        if let range = short.range(of: "/.claude/worktrees/") {
            short = short[..<range.lowerBound] + " ▸ " + short[range.upperBound...]
        }
        return short
    }
}
