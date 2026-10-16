import Darwin
import Foundation

/// Finds what every Claude Code session and Codex thread leaves on disk and decides what can be deleted.
///
/// A session can own three things besides its transcript:
/// - scratch files: `/tmp/claude-<uid>/<project>/<session id>/` (Claude Code)
/// - a worktree: `<repo>/.claude/worktrees/<name>` (Claude Code) or `~/.codex/worktrees/<hash>/<repo>` (Codex),
///   including those a sub-agent created
/// - nothing else; the transcript itself is history and is never offered for deletion
///
/// Rules for what is cleanable, all of which need the session not to be running and no process to be working in the
/// directory:
/// - scratch files: always
/// - dependencies and caches inside a worktree (git-ignored `node_modules`, `__pycache__`, ...): always
/// - the rest of a worktree: only if git reports no uncommitted changes, every commit is on some remote branch, and
///   the worktree holds no other git-ignored files, since those would be lost with it
enum DiskScanner {
    static let dependencyNames: Set<String> = [
        "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".vite", ".cache", ".gradle", ".terraform", "dist", "build",
        "coverage", "target",
    ]

    /// A Codex thread counts as running if it had activity this recently
    static let codexActiveWindow: TimeInterval = 3600

    struct WorktreeUsage {
        var files: UInt64 = 0
        var dependencies: UInt64 = 0
        var ignored: UInt64 = 0
        /// Largest first
        var dependencyNames: [String] = []
        var ignoredNames: [String] = []
        /// The git-ignored dependency directories, relative to the worktree
        var dependencyPaths: [String] = []
        /// Largest first: files by top-level folder, each dependency directory, ignored files by top-level folder
        var fileEntries: [(name: String, bytes: UInt64)] = []
        var dependencyEntries: [(name: String, bytes: UInt64)] = []
        var ignoredEntries: [(name: String, bytes: UInt64)] = []
        var git: GitState?
    }

    /// Whether removing the worktree loses nothing: no uncommitted changes, every commit on a remote branch, and the
    /// only git-ignored files are dependencies and caches that can be rebuilt
    static func isDisposable(_ git: GitState) -> Bool {
        git.changes == 0 && git.unpushed == 0 && git.ignoredFiles.isEmpty
            && git.ignoredDirectories.allSatisfy { dependencyNames.contains(($0 as NSString).lastPathComponent) }
    }

    /// Collects results from the measuring threads
    private final class Results {
        private let lock = NSLock()
        private var finished = 0
        private var weightDone = 0
        private(set) var worktrees: [String: WorktreeUsage] = [:]
        private(set) var sizes: [String: UInt64] = [:]
        private(set) var owners: [String: String?] = [:]
        private(set) var breakdowns: [String: [String: UInt64]] = [:]

        func store(breakdown: [String: UInt64], at path: String) { lock.withLock { breakdowns[path] = breakdown } }

        func store(owner: String?, at path: String) { lock.withLock { owners[path] = owner } }
        func worktree(_ path: String) -> WorktreeUsage? { lock.withLock { worktrees[path] } }
        func size(_ path: String) -> UInt64? { lock.withLock { sizes[path] } }
        func breakdown(_ path: String) -> [String: UInt64]? { lock.withLock { breakdowns[path] } }
        func store(worktree usage: WorktreeUsage, at path: String) { lock.withLock { worktrees[path] = usage } }
        func store(size: UInt64, at path: String) { lock.withLock { sizes[path] = size } }
        func finishOne() -> Int { lock.withLock { finished += 1; return finished } }
        /// Counts a job as done and returns the weight done so far
        func finish(weight: Int) -> Int { lock.withLock { weightDone += weight; return weightDone } }
        /// nil: not decided yet; .some(nil): no thread made it; .some(id): the thread that did
        func decision(_ path: String) -> String?? { lock.withLock { owners[path] } }
    }

    /// Scans the disk. `progress` gets what is going on, `fraction` how much of the measuring is done, and `partial`
    /// a report of what has been measured so far, about once a second, so that results can be shown as they arrive.
    static func scan(progress: @escaping (String) -> Void, fraction: ((Double) -> Void)? = nil,
                     partial: ((DiskReport) -> Void)? = nil) -> DiskReport {
        let started = Date()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        progress("Reading sessions…")
        let liveClaude = ClaudeSessions.running().filter { Procs.read($0.key) != nil }
        let liveById = Dictionary(liveClaude.values.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let transcripts = ClaudeSessions.transcripts()
        let threads = CodexThreads.loadAll()
        let processDirectories: [(pid: Int32, path: String)] = Procs.allPIDs().compactMap { pid in
            Procs.workingDirectory(pid).map { (pid, $0) }
        }

        // Scratch directories, by session id
        let tmpRoot = "/private/tmp/claude-\(getuid())"
        var scratch: [String: [String]] = [:]
        for project in (try? fm.contentsOfDirectory(atPath: tmpRoot)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(tmpRoot)/\(project)")) ?? [] where name.count == 36 {
                scratch[name, default: []].append("\(tmpRoot)/\(project)/\(name)")
            }
        }

        // Worktrees and the session each one belongs to. When several sessions used one worktree (a resumed
        // conversation, or the sub-agents of a Codex thread), it goes to the one that was active last.
        var claudeOwner: [String: (id: String, active: Date)] = [:]
        var repos = Set<String>()
        func claim(_ root: String, _ id: String, _ active: Date) {
            guard fm.fileExists(atPath: root) else { return }
            if let current = claudeOwner[root], current.active >= active { return }
            claudeOwner[root] = (id, active)
        }
        for transcript in transcripts {
            guard let cwd = transcript.cwd else { continue }
            var repo = cwd
            if let range = cwd.range(of: "/.claude/worktrees/") {
                repo = String(cwd[..<range.lowerBound])
                if let name = cwd[range.upperBound...].split(separator: "/").first {
                    claim(String(cwd[..<range.upperBound]) + name, transcript.sessionId, transcript.modified)
                }
            }
            if fm.fileExists(atPath: repo + "/.claude/worktrees") { repos.insert(repo) }
            for agent in transcript.subagents {
                claim("\(repo)/.claude/worktrees/\(agent)", transcript.sessionId, transcript.modified)
            }
        }
        // Worktrees no session has as its working directory; which session made each is worked out below
        var claudeUnmatched: [String] = []
        for repo in repos {
            for name in (try? fm.contentsOfDirectory(atPath: repo + "/.claude/worktrees")) ?? [] {
                let root = "\(repo)/.claude/worktrees/\(name)"
                if claudeOwner[root] == nil, isDirectory(root) { claudeUnmatched.append(root) }
            }
        }

        let codexPrefix = home + "/.codex/worktrees/"
        var codexByRoot: [String: [CodexThread]] = [:]
        for thread in threads where thread.cwd.hasPrefix(codexPrefix) {
            let parts = thread.cwd.dropFirst(codexPrefix.count).split(separator: "/").prefix(2)
            guard parts.count == 2 else { continue }
            let root = codexPrefix + parts.joined(separator: "/")
            if fm.fileExists(atPath: root) { codexByRoot[root, default: []].append(thread) }
        }
        var codexOwner: [String: String] = [:]
        for (root, owners) in codexByRoot {
            let top = owners.filter { $0.parentId == nil }
            codexOwner[root] = (top.isEmpty ? owners : top).max { $0.updatedAt < $1.updatedAt }?.id
        }
        // Worktrees an agent made by hand (`git worktree add ~/.codex/worktrees/<name>/<repo>`) are in no thread's
        // `cwd`. The thread that made one is the earliest thread alive when it was created whose log mentions it.
        var unmatched: [String] = []
        for hash in (try? fm.contentsOfDirectory(atPath: codexPrefix)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: codexPrefix + hash)) ?? [] {
                let root = "\(codexPrefix)\(hash)/\(name)"
                if codexOwner[root] == nil, fm.fileExists(atPath: root + "/.git") { unmatched.append(root) }
            }
        }
        // Measure everything a few jobs at a time so the disk is not saturated. The quick jobs go first, so that
        // there is something to show early.
        // Worktrees an agent made by hand are in no thread's `cwd`; which thread made one is worked out in the same
        // queue, and the worktree shows up under that thread once it is known
        let results = Results()
        let creators = Results()
        var jobs: [(weight: Int, run: () -> Void)] = []
        for root in unmatched {
            jobs.append((weight: 4, run: { creators.store(owner: creator(of: root, among: threads), at: root) }))
        }
        for root in claudeUnmatched {
            jobs.append((weight: 4, run: {
                creators.store(owner: ClaudeSessions.creator(of: root, among: transcripts)?.sessionId, at: root)
            }))
        }
        for transcript in transcripts {
            jobs.append((weight: 1, run: { results.store(size: DiskSize.of(transcript.directory), at: transcript.directory) }))
        }
        for path in scratch.values.joined() {
            jobs.append((weight: 1, run: {
                let m = DiskSize.measure(path, buckets: 1, breakdown: true) { _, _ in nil }
                results.store(size: m.buckets[0], at: path)
                results.store(breakdown: m.topLevel, at: path)
            }))
        }
        // A worktree takes much longer than a scratch directory, so it counts for more in the progress bar
        for root in Set(claudeOwner.keys).union(codexOwner.keys).union(unmatched).union(claudeUnmatched) {
            jobs.append((weight: 15, run: { results.store(worktree: analyze(root), at: root) }))
        }

        func busyProcess(in path: String) -> Int32? {
            processDirectories.first { $0.path == path || $0.path.hasPrefix(path + "/") }?.pid
        }

        func worktreeItems(root: String, running: Bool, owner: DiskOwner) -> [DiskItem] {
            guard let usage = results.worktree(root) else { return [] }
            let subject = root.contains("/.codex/")
                ? root.split(separator: "/").suffix(2).joined(separator: "/") : (root as NSString).lastPathComponent
            var blocker: String?
            if running {
                blocker = runningNote(owner)
            } else if let pid = busyProcess(in: root) {
                blocker = "\(Procs.read(pid)?.name ?? "A process") (pid \(pid)) is running in this directory"
            }
            var items: [DiskItem] = []
            if usage.dependencies > 0 {
                items.append(DiskItem(
                    id: root + "#dependencies", kind: .dependencies, subject: subject, path: root, bytes: usage.dependencies,
                    cleanable: blocker == nil,
                    note: blocker ?? "\(usage.dependencyNames.prefix(3).joined(separator: ", ")): can be reinstalled or rebuilt",
                    removal: .ignoredDirectories(root: root, paths: usage.dependencyPaths.map { root + "/" + $0 }),
                    owner: owner, entries: entries(root, usage.dependencyEntries)))
            }
            if usage.ignored > 0 {
                items.append(DiskItem(
                    id: root + "#ignored", kind: .ignored, subject: subject, path: root, bytes: usage.ignored, cleanable: false,
                    note: "\(usage.ignoredNames.prefix(3).joined(separator: ", ")): ignored by git, so it is lost if the worktree is removed",
                    owner: owner, entries: entries(root, usage.ignoredEntries)))
            }
            let reason: String?
            if let blocker { reason = blocker }
            else if let git = usage.git {
                if git.changes > 0 { reason = count(git.changes, "uncommitted change") }
                else if git.unpushed > 0 { reason = count(git.unpushed, "commit") + " not on any remote branch" }
                else if !isDisposable(git) { reason = "Also holds \(Format.bytes(usage.ignored)) of ignored files" }
                else { reason = nil }
            } else { reason = "Git cannot read this worktree" }
            items.append(DiskItem(
                id: root + "#files", kind: .worktree, subject: subject, path: root, bytes: usage.files, cleanable: reason == nil,
                note: reason ?? "No uncommitted changes and every commit is on a remote branch: the whole worktree can be removed",
                removal: .worktree(root: root), owner: owner, entries: entries(root, usage.fileEntries)))
            return items
        }

        func entries(_ base: String, _ list: [(name: String, bytes: UInt64)]) -> [DiskEntry] {
            list.prefix(120).map { DiskEntry(path: base + "/" + $0.name, name: $0.name, bytes: $0.bytes) }
        }

        func runningNote(_ owner: DiskOwner) -> String {
            if case .codex = owner { return "The thread was active in the last hour" }
            return "The session is running"
        }

        func scratchItems(sessionId: String, running: Bool) -> [DiskItem] {
            (scratch[sessionId] ?? []).compactMap { path in
                guard let bytes = results.size(path), bytes > 0 else { return nil }
                let blocker = running ? "The session is running"
                    : busyProcess(in: path).map { "\(Procs.read($0)?.name ?? "A process") (pid \($0)) is running in this directory" }
                return DiskItem(id: path, kind: .scratch, path: path, bytes: bytes, cleanable: blocker == nil,
                                note: blocker ?? "Temporary working files of the session", removal: .directory(path),
                                owner: .claude(sessionId),
                                entries: (results.breakdown(path) ?? [:]).sorted { $0.value > $1.value }.prefix(120)
                                    .map { DiskEntry(path: path + "/" + $0.key, name: $0.key, bytes: $0.value) })
            }
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        func ago(_ date: Date) -> String { formatter.localizedString(for: date, relativeTo: Date()) }

        // Titles of ended sessions are read from their transcripts; once is enough
        var titles: [String: String?] = [:]
        func endedTitle(_ id: String) -> String? {
            if let known = titles[id] { return known }
            let title = ClaudeSessions.title(ofEndedSession: id)
            titles[id] = .some(title)
            return title
        }

        /// Everything measured so far as a report: parts appear as their measurements finish
        func assemble() -> DiskReport {
            var codexNow = codexOwner
            var claudeNow = claudeOwner
            var orphans: [String] = []
            for root in claudeUnmatched {
                switch creators.decision(root) {
                case .some(.some(let id)): claudeNow[root] = (id, Date())
                case .some(.none): orphans.append(root)
                case .none: break  // not worked out yet
                }
            }
            for root in unmatched {
                switch creators.decision(root) {
                case .some(.some(let id)): codexNow[root] = id
                case .some(.none): orphans.append(root)
                case .none: break  // not worked out yet
                }
            }
            var sessions: [DiskSession] = []
            var knownScratch = Set<String>()

            for transcript in transcripts {
                knownScratch.insert(transcript.sessionId)
                let live = liveById[transcript.sessionId]
                let running = live != nil
                var items = [DiskItem(
                    id: transcript.file, kind: .history, path: transcript.file,
                    bytes: transcript.fileBytes + (results.size(transcript.directory) ?? 0), cleanable: false,
                    note: "The conversation; needed to resume the session")]
                items += scratchItems(sessionId: transcript.sessionId, running: running)
                for (root, owner) in claudeNow where owner.id == transcript.sessionId {
                    items += worktreeItems(root: root, running: running, owner: .claude(transcript.sessionId))
                }
                let session = DiskSession(
                    id: "claude-\(transcript.sessionId)", source: .claude,
                    title: live.map { $0.name.isEmpty ? ($0.cwd as NSString).lastPathComponent : $0.name }
                        ?? (items.count > 1 ? endedTitle(transcript.sessionId) : nil)
                        ?? "Session \(transcript.sessionId.prefix(8))",
                    detail: [transcript.cwd.map(Collector.shortPath), running ? "Running" : "Ended",
                             running ? nil : "last active " + ago(transcript.modified)].compactMap { $0 }.joined(separator: " · "),
                    items: items)
                sessions.append(session)
            }

            for thread in threads {
                let active = Date().timeIntervalSince(thread.updatedAt) < codexActiveWindow
                let rollout = (try? URL(fileURLWithPath: thread.rolloutPath).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
                var items: [DiskItem] = []
                if rollout > 0 {
                    items.append(DiskItem(id: thread.rolloutPath, kind: .history, path: thread.rolloutPath,
                                          bytes: UInt64(rollout), cleanable: false,
                                          note: "The conversation log; needed to reopen the thread"))
                }
                for (root, owner) in codexNow where owner == thread.id {
                    items += worktreeItems(root: root, running: active, owner: .codex(thread.id))
                }
                sessions.append(DiskSession(
                    id: "codex-\(thread.id)", source: .codex, title: thread.displayTitle,
                    detail: [thread.subAgentLabel, Collector.shortPath(thread.cwd),
                             thread.isArchived ? "Archived" : active ? "Active" : "Idle",
                             "last active " + ago(thread.updatedAt)].compactMap { $0 }.joined(separator: " · "),
                    items: items))
            }

            // Scratch files whose transcript is gone, and worktrees no session claims
            for (id, paths) in scratch where !knownScratch.contains(id) {
                let items = scratchItems(sessionId: id, running: liveById[id] != nil)
                if !items.isEmpty {
                    sessions.append(DiskSession(id: "claude-\(id)", source: .claude, title: "Session \(id.prefix(8))",
                                                detail: "Transcript not found · " + Collector.shortPath(paths[0]), items: items))
                }
            }
            for root in orphans {
                let items = worktreeItems(root: root, running: false, owner: .nobody)
                if !items.isEmpty {
                    sessions.append(DiskSession(
                        id: "worktree-\(root)", source: root.contains("/.codex/") ? .codex : .claude,
                        title: root.contains("/.codex/") ? String(root.split(separator: "/").suffix(2).first ?? "")
                                                         : (root as NSString).lastPathComponent,
                        detail: [Collector.shortPath(root), results.worktree(root)?.git?.branch.nilIfEmpty.map { "branch \($0)" },
                                 "No session found"].compactMap { $0 }.joined(separator: " · "),
                        items: items))
                }
            }

            let listed = sessions.filter { !$0.isHistoryOnly }
                .sorted { ($0.reclaimable, $0.kept) > ($1.reclaimable, $1.kept) }
            let historyOnly = sessions.filter(\.isHistoryOnly)
            return DiskReport(
                time: Date(), seconds: Date().timeIntervalSince(started), sessions: listed,
                historyOnlyCount: historyOnly.count, historyOnlyBytes: historyOnly.reduce(0) { $0 + $1.kept })
        }

        let total = jobs.reduce(0) { $0 + $1.weight }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        let group = DispatchGroup()
        let jobCount = jobs.count
        for job in jobs {
            group.enter()
            queue.addOperation {
                job.run()
                let finished = results.finishOne()
                if finished % 8 == 0 || finished == jobCount { progress("Measuring \(finished) of \(jobCount)…") }
                fraction?(Double(results.finish(weight: job.weight)) / Double(total))
                group.leave()
            }
        }
        while group.wait(timeout: .now() + 1) == .timedOut { partial?(assemble()) }
        progress("Preparing the list…")
        return assemble()
    }

    /// The thread that created the worktree at `root`: among the threads that were running when the directory was
    /// created, the earliest whose conversation log mentions its path.
    private static func creator(of root: String, among threads: [CodexThread]) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: root)
        guard let born = attributes?[.creationDate] as? Date else { return nil }
        let key = Array(".codex/worktrees/\(root.split(separator: "/").suffix(2).first ?? "")/".utf8)
        let slack: TimeInterval = 600
        let candidates = threads.filter {
            $0.createdAt <= born.addingTimeInterval(slack) && born.addingTimeInterval(-slack) <= $0.updatedAt
        }.sorted { $0.createdAt < $1.createdAt }
        for thread in candidates {
            guard let log = try? Data(contentsOf: URL(fileURLWithPath: thread.rolloutPath), options: .mappedIfSafe) else { continue }
            let found = log.withUnsafeBytes { raw in
                raw.baseAddress.map { memmem($0, raw.count, key, key.count) != nil } ?? false
            }
            if found { return thread.id }
        }
        return nil
    }

    private static func analyze(_ root: String) -> WorktreeUsage {
        let git = Git.state(of: root)
        let measurement = DiskSize.measure(root, buckets: 3, breakdown: true) { path, isDirectory in
            guard let git else { return nil }
            if isDirectory {
                guard git.ignoredDirectories.contains(path) else { return nil }
                return dependencyNames.contains((path as NSString).lastPathComponent) ? 1 : 2
            }
            return git.ignoredFiles.contains(path) ? 2 : nil
        }
        func largest(_ bucket: Int, name: (String) -> String) -> [String] {
            var sizes: [String: UInt64] = [:]
            for entry in measurement.classified where entry.bucket == bucket { sizes[name(entry.path), default: 0] += entry.bytes }
            return sizes.sorted { $0.value > $1.value }.map(\.key)
        }
        func sizes(_ bucket: Int, name: (String) -> String) -> [(name: String, bytes: UInt64)] {
            var result: [String: UInt64] = [:]
            for entry in measurement.classified where entry.bucket == bucket { result[name(entry.path), default: 0] += entry.bytes }
            return result.sorted { $0.value > $1.value }.map { (name: $0.key, bytes: $0.value) }
        }
        return WorktreeUsage(
            files: measurement.buckets[0], dependencies: measurement.buckets[1], ignored: measurement.buckets[2],
            dependencyNames: largest(1) { ($0 as NSString).lastPathComponent },
            ignoredNames: largest(2) { String($0.split(separator: "/").first ?? "") },
            dependencyPaths: measurement.classified.filter { $0.bucket == 1 }.map(\.path),
            fileEntries: measurement.topLevel.sorted { $0.value > $1.value }.map { (name: $0.key, bytes: $0.value) },
            dependencyEntries: sizes(1) { $0 },
            ignoredEntries: sizes(2) { String($0.split(separator: "/").first ?? "") },
            git: git)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
