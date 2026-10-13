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
                entrypoint: json["entrypoint"] as? String ?? ""
            )
        }
        return result
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

    private static func fetch(_ db: OpaquePointer?, _ id: String) -> CodexThread? {
        let sql = """
            SELECT coalesce(nullif(t.name, ''), t.title), t.cwd, t.agent_nickname, t.agent_role, e.parent_thread_id
            FROM threads t LEFT JOIN thread_spawn_edges e ON e.child_thread_id = t.id
            WHERE t.id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        return CodexThread(
            id: id,
            title: text(0) ?? "",
            cwd: text(1) ?? "",
            nickname: text(2),
            role: text(3),
            parentId: text(4)
        )
    }
}
