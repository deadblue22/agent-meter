import Darwin
import Foundation

/// Deletes the parts of sessions that the Disk tab marks as deletable.
///
/// A scan can be minutes old, so every part is checked again right before it is deleted and skipped if it is no
/// longer safe: the session may be running again, a process may have started in it, a worktree may have gained
/// changes. Only paths of the three expected shapes are ever deleted. Conversations have no removal and are never
/// touched.
enum DiskCleaner {
    struct Outcome {
        var deleted: [DiskItem] = []
        var skipped: [(item: DiskItem, reason: String)] = []
        /// Worktrees removed in this run
        var removedWorktrees = Set<String>()

        var freed: UInt64 { deleted.reduce(0) { $0 + $1.bytes } }
    }

    static func delete(_ items: [DiskItem], progress: (String) -> Void) -> Outcome {
        var outcome = Outcome()
        let liveClaude = Set(ClaudeSessions.running().filter { Procs.read($0.key) != nil }.values.map(\.sessionId))
        let activeCodex = Set(CodexThreads.loadAll()
            .filter { Date().timeIntervalSince($0.updatedAt) < DiskScanner.codexActiveWindow }.map(\.id))
        let directories: [(pid: Int32, path: String)] = Procs.allPIDs().compactMap { pid in
            Procs.workingDirectory(pid).map { (pid, $0) }
        }

        func isWholeWorktree(_ item: DiskItem) -> Bool {
            if case .worktree = item.removal { return true }
            return false
        }
        // Whole worktrees first: they take their dependencies with them
        let ordered = items.filter(isWholeWorktree) + items.filter { !isWholeWorktree($0) }

        for (index, item) in ordered.enumerated() {
            progress("Deleting \(index + 1) of \(ordered.count)…")
            func skip(_ reason: String) { outcome.skipped.append((item, reason)) }

            guard let removal = item.removal, item.cleanable else { skip("Not deletable"); continue }
            switch item.owner {
            case .claude(let id) where liveClaude.contains(id): skip("The session is running again"); continue
            case .codex(let id) where activeCodex.contains(id): skip("The thread was active in the last hour"); continue
            default: break
            }

            let location: String
            switch removal {
            case .directory(let path): location = path
            case .ignoredDirectories(let root, _): location = root
            case .worktree(let root): location = root
            }
            if case .ignoredDirectories(let root, _) = removal, outcome.removedWorktrees.contains(root) {
                outcome.deleted.append(item)  // went with its worktree
                continue
            }
            if let pid = directories.first(where: { $0.path == location || $0.path.hasPrefix(location + "/") })?.pid {
                skip("\(Procs.read(pid)?.name ?? "A process") (pid \(pid)) is running in this directory")
                continue
            }

            switch removal {
            case .directory(let path):
                guard isScratchDirectory(path) else { skip("Not a scratch directory"); continue }
                guard exists(path) else { outcome.deleted.append(item); continue }
                guard isPlainDirectory(path) else { skip("Not a plain directory"); continue }
                if let error = remove(path) { skip(error) } else { outcome.deleted.append(item) }

            case .ignoredDirectories(let root, let paths):
                guard isWorktree(root) else { skip("Not a worktree"); continue }
                var failure: String?
                for path in paths where exists(path) {
                    let name = (path as NSString).lastPathComponent
                    guard path.hasPrefix(root + "/"), DiskScanner.dependencyNames.contains(name), isPlainDirectory(path) else {
                        failure = "\(name) is not a plain dependency directory"
                        break
                    }
                    guard Git.isIgnored(String(path.dropFirst(root.count + 1)), in: root) else {
                        failure = "\(name) is no longer ignored by git"
                        break
                    }
                    if let error = remove(path) { failure = error; break }
                }
                if let failure { skip(failure) } else { outcome.deleted.append(item) }

            case .worktree(let root):
                guard isWorktree(root) else { skip("Not a worktree"); continue }
                guard exists(root) else { outcome.deleted.append(item); outcome.removedWorktrees.insert(root); continue }
                guard let git = Git.state(of: root) else { skip("Git cannot read the worktree"); continue }
                if git.changes > 0 { skip("It now has \(git.changes) uncommitted change(s)"); continue }
                if git.unpushed > 0 { skip("It now has \(git.unpushed) commit(s) not on any remote branch"); continue }
                guard DiskScanner.isDisposable(git) else { skip("It holds git-ignored files that would be lost"); continue }
                if let error = Git.removeWorktree(at: root) { skip(error); continue }
                if exists(root) { skip("The directory is still there after git removed the worktree"); continue }
                outcome.deleted.append(item)
                outcome.removedWorktrees.insert(root)
            }
        }
        return outcome
    }

    /// `/private/tmp/claude-<uid>/<project>/<session id>`
    private static func isScratchDirectory(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return path.hasPrefix("/") && parts.count == 5 && parts[0] == "private" && parts[1] == "tmp"
            && parts[2] == "claude-\(getuid())" && !parts[3].hasPrefix(".") && parts[4].count == 36
    }

    /// A linked git worktree in one of the two places the agents put them: `<repo>/.claude/worktrees/<name>`
    /// or `~/.codex/worktrees/<hash>/<repo>`
    private static func isWorktree(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), isPlainDirectory(path) else { return false }
        // A linked worktree has a `.git` file; a main checkout has a `.git` directory
        var st = stat()
        guard lstat(path + "/.git", &st) == 0, (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        if parts.count >= 3, parts[parts.count - 3] == ".claude", parts[parts.count - 2] == "worktrees" { return true }
        let codex = FileManager.default.homeDirectoryForCurrentUser.path + "/.codex/worktrees/"
        return path.hasPrefix(codex) && path.dropFirst(codex.count).split(separator: "/").count == 2
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// A directory that is not a symbolic link
    private static func isPlainDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func remove(_ path: String) -> String? {
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
