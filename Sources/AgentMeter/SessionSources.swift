import Foundation
import SQLite3

/// `~/.claude/sessions/<pid>.json`: the registry file Claude Code writes for each running session process.
struct ClaudeSession {
    let pid: Int32
    let sessionId: String
    let name: String
    let cwd: String
    /// "busy" or "idle"
    let status: String
    /// When `status` last changed; for an idle session, when it went idle
    let statusSince: Date?
    /// "claude-desktop", "cli", ...
    let entrypoint: String
}

enum ClaudeSessions {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func running() -> [Int32: ClaudeSession] {
        let dir = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [Int32: ClaudeSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String else { continue }
            result[Int32(pid)] = ClaudeSession(
                pid: Int32(pid),
                sessionId: sessionId,
                name: json["name"] as? String ?? "",
                cwd: json["cwd"] as? String ?? "",
                status: json["status"] as? String ?? "",
                statusSince: (json["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                entrypoint: json["entrypoint"] as? String ?? ""
            )
        }
        return result
    }

    /// The session a `claude` process was started to resume: `--resume=<id>` or `--resume <id>`
    static func resumeTarget(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let value: String?
            if argument.hasPrefix("--resume=") { value = String(argument.dropFirst("--resume=".count)) }
            else if argument == "--resume", index + 1 < arguments.count { value = arguments[index + 1] }
            else { continue }
            if let value, UUID(uuidString: value) != nil { return value.lowercased() }
        }
        return nil
    }

    /// Conversations that go on under a new session ID: a session that was resumed, or continued after the old one
    /// ran out of room, is a new session in Claude Code's registry, but it is the same conversation. Maps the ID of
    /// each such earlier session to the running session that continues it.
    static func predecessors(among live: [Int32: ClaudeSession]) -> [String: String] {
        let liveIds = Set(live.values.map(\.sessionId))
        var result: [String: String] = [:]
        for (pid, session) in live {
            guard let arguments = Procs.arguments(pid, environmentKeys: [])?.arguments,
                  let earlier = resumeTarget(in: arguments), earlier != session.sessionId, !liveIds.contains(earlier)
            else { continue }
            result[earlier] = session.sessionId
        }
        return result
    }

    /// One conversation transcript `~/.claude/projects/<project>/<id>.jsonl`, live or ended
    struct Transcript {
        let sessionId: String
        let file: String
        let modified: Date
        /// When the transcript file was created, which is when the session began
        let created: Date
        /// Bytes the transcript file occupies
        let fileBytes: UInt64
        /// Companion directory `<id>/` (sub-agent transcripts, saved tool results); may not exist
        let directory: String
        let cwd: String?
        /// Names of the sub-agents this session started, such as `agent-a888f7c00ceb0ffcd`
        let subagents: [String]
    }

    static func transcripts() -> [Transcript] {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects")
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var result: [Transcript] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .totalFileAllocatedSizeKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionId = file.deletingPathExtension().lastPathComponent
                guard sessionId.count == 36 else { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .totalFileAllocatedSizeKey])
                let directory = dir.appendingPathComponent(sessionId)
                let subagents = ((try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent("subagents").path)) ?? [])
                    .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
                    .map { String($0.dropLast(".jsonl".count)) }
                result.append(Transcript(
                    sessionId: sessionId,
                    file: file.path,
                    modified: values?.contentModificationDate ?? .distantPast,
                    created: values?.creationDate ?? .distantPast,
                    fileBytes: UInt64(values?.totalFileAllocatedSize ?? 0),
                    directory: directory.path,
                    cwd: workingDirectory(ofTranscript: file),
                    subagents: subagents
                ))
            }
        }
        return result
    }

    /// The session that created the worktree at `root`, for a worktree no session has as its working directory (an agent
    /// made it by hand, or a sub-agent did): among the sessions that were running when the directory was created, the
    /// one whose conversation, or a sub-agent's, mentions its path first. Later mentions, such as a session that only
    /// listed the worktrees, do not count.
    static func creator(of root: String, among transcripts: [Transcript]) -> Transcript? {
        guard let born = (try? FileManager.default.attributesOfItem(atPath: root))?[.creationDate] as? Date else { return nil }
        let slack: TimeInterval = 600
        let key = Array("/worktrees/\((root as NSString).lastPathComponent)".utf8)
        var best: (transcript: Transcript, when: Date)?
        for transcript in transcripts
            where transcript.created <= born.addingTimeInterval(slack) && transcript.modified >= born.addingTimeInterval(-slack) {
            let subagents = ((try? FileManager.default.contentsOfDirectory(atPath: transcript.directory + "/subagents")) ?? [])
                .filter { $0.hasSuffix(".jsonl") }.map { transcript.directory + "/subagents/" + $0 }
            for file in [transcript.file] + subagents {
                guard let when = firstMention(of: key, in: file), when >= born.addingTimeInterval(-slack) else { continue }
                if best == nil || when < best!.when { best = (transcript, when) }
            }
        }
        return best?.transcript
    }

    /// When the first record that contains `key` was written
    private static func firstMention(of key: [UInt8], in file: String) -> Date? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) else { return nil }
        let line: Data? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let hit = memmem(base, raw.count, key, key.count) else { return nil }
            let offset = base.distance(to: hit)
            var start = offset, end = offset
            while start > 0, raw[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            while end < raw.count, raw[end] != UInt8(ascii: "\n") { end += 1 }
            return Data(raw[start..<end])
        }
        guard let line, let stamp = line.range(of: Data("\"timestamp\":\"".utf8)) else { return nil }
        let text = String(decoding: line[stamp.upperBound...].prefix(32), as: UTF8.self).split(separator: "\"").first.map(String.init)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return text.flatMap(formatter.date(from:))
    }

    /// The `cwd` of the first record that has one. Every record carries it, so the head of the file is enough.
    private static func workingDirectory(ofTranscript file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 * 1024),
              let hit = head.range(of: Data("\"cwd\":\"".utf8)) else { return nil }
        var end = hit.upperBound
        while end < head.endIndex, head[end] != UInt8(ascii: "\"") {
            end += head[end] == UInt8(ascii: "\\") ? 2 : 1
        }
        let quoted = Data("\"".utf8) + head[hit.upperBound..<min(end, head.endIndex)] + Data("\"".utf8)
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }

    /// Title of an ended session: the last custom-title record in its transcript `~/.claude/projects/*/<id>.jsonl`.
    /// Transcripts can be tens of MB, so search the raw bytes backwards and parse only the matching line.
    static func title(ofEndedSession sessionId: String) -> String? {
        let projects = home.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        let marker = Data("\"customTitle\":".utf8)
        let newline = Data("\n".utf8)
        for dir in dirs {
            let file = dir.appendingPathComponent("\(sessionId).jsonl")
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            guard let hit = data.range(of: marker, options: .backwards) else { return nil }
            let start = data.range(of: newline, options: .backwards, in: data.startIndex..<hit.lowerBound)?.upperBound ?? data.startIndex
            let end = data.range(of: newline, in: hit.upperBound..<data.endIndex)?.lowerBound ?? data.endIndex
            let json = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any]
            return json?["customTitle"] as? String
        }
        return nil
    }
}

/// A Codex thread from `~/.codex/state_5.sqlite`. Sub-agents are threads too, linked to their parent via thread_spawn_edges.
struct CodexThread {
    let id: String
    let title: String
    let cwd: String
    let nickname: String?
    let role: String?
    let parentId: String?
    let isArchived: Bool
    /// Last activity
    let updatedAt: Date
    /// The conversation log `~/.codex/sessions/.../rollout-*.jsonl`
    let rolloutPath: String
    let createdAt: Date
    /// Sub-agents only: where the parent placed them, such as `/root/review_billing_logic`
    let agentPath: String?

    /// What to show for the thread. Sub-agents have no title of their own, but the task name their parent gave them
    /// says what they are doing.
    var displayTitle: String {
        if !title.isEmpty { return String(title.prefix(80)) }
        if let task = agentPath?.split(separator: "/").last, !task.isEmpty {
            let words = task.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        if let nickname, !nickname.isEmpty { return "Sub-agent \(nickname)" }
        return "Thread \(id.prefix(8))"
    }

    /// "Sub-agent Cicero the 2nd (worker)", for sub-agents
    var subAgentLabel: String? {
        guard let nickname, !nickname.isEmpty else { return nil }
        return "Sub-agent \(nickname)" + (role.map { " (\($0))" } ?? "")
    }
}

enum CodexThreads {
    private static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite").path

    /// Loads the given threads and all of their ancestors.
    static func load(_ ids: Set<String>) -> [String: CodexThread] {
        guard !ids.isEmpty else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }

        var result: [String: CodexThread] = [:]
        var pending = Array(ids)
        while let id = pending.popLast() {
            guard result[id] == nil, let thread = fetch(db, id) else { continue }
            result[id] = thread
            if let parent = thread.parentId { pending.append(parent) }
        }
        return result
    }

    /// Every thread, archived ones included
    static func loadAll() -> [CodexThread] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [CodexThread] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(thread(statement)) }
        return result
    }

    private static let select = """
        SELECT t.id, coalesce(nullif(t.name, ''), t.title), t.cwd, t.agent_nickname, t.agent_role, e.parent_thread_id,
               t.archived, t.updated_at, t.rollout_path, t.created_at, t.agent_path
        FROM threads t LEFT JOIN thread_spawn_edges e ON e.child_thread_id = t.id
        """

    private static func fetch(_ db: OpaquePointer?, _ id: String) -> CodexThread? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, select + " WHERE t.id = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return thread(statement)
    }

    private static func thread(_ statement: OpaquePointer?) -> CodexThread {
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        return CodexThread(
            id: text(0) ?? "",
            title: text(1) ?? "",
            cwd: text(2) ?? "",
            nickname: text(3),
            role: text(4),
            parentId: text(5),
            isArchived: sqlite3_column_int(statement, 6) != 0,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 7))),
            rolloutPath: text(8) ?? "",
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
            agentPath: text(10)
        )
    }
}
