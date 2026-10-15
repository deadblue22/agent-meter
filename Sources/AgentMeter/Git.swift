import Foundation

/// What git says about one working tree
struct GitState {
    /// Checked-out branch; empty when HEAD is detached
    var branch = ""
    /// Entries with uncommitted changes, including untracked ones (a new directory counts once)
    var changes = 0
    /// Commits reachable from HEAD that no remote-tracking branch has
    var unpushed = 0
    /// Ignored directories and files, relative to the working tree
    var ignoredDirectories = Set<String>()
    var ignoredFiles = Set<String>()
}

enum Git {
    /// nil when git cannot read the working tree (for example the repository it belongs to was deleted)
    static func state(of directory: String) -> GitState? {
        guard let status = run(["status", "--porcelain=v1", "-z", "--ignored=traditional"], in: directory),
              let count = run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: directory),
              let branch = run(["branch", "--show-current"], in: directory),
              let unpushed = Int(String(decoding: count, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        var state = GitState(branch: String(decoding: branch, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             unpushed: unpushed)
        // Entries are "XY path" separated by NUL; a rename or copy is followed by an extra field holding its origin
        var fields = status.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
            .makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = field.prefix(2)
            let path = String(field.dropFirst(3))
            if code == "!!" {
                if path.hasSuffix("/") { state.ignoredDirectories.insert(String(path.dropLast())) }
                else { state.ignoredFiles.insert(path) }
            } else {
                state.changes += 1
                if code.hasPrefix("R") || code.hasPrefix("C") { _ = fields.next() }
            }
        }
        return state
    }

    /// Whether git ignores `path` (relative to `directory`)
    static func isIgnored(_ path: String, in directory: String) -> Bool {
        run(["check-ignore", "-q", "--", path], in: directory) != nil
    }

    /// Removes the working tree at `root` together with its registration in the repository. Returns git's error
    /// message when that fails, nil on success. The caller has to make sure nothing in it is worth keeping.
    static func removeWorktree(at root: String) -> String? {
        guard let common = run(["rev-parse", "--git-common-dir"], in: root) else { return "Git cannot read the worktree" }
        let text = String(decoding: common, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = URL(fileURLWithPath: text, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardized.path
        // From the directory above, with the repository named explicitly: not from inside what is being removed
        let parent = (root as NSString).deletingLastPathComponent
        guard let result = execute(["--git-dir", repository, "worktree", "remove", "--force", root], in: parent, mergeErrors: true)
        else { return "Could not run git" }
        guard result.status != 0 else { return nil }
        let message = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.split(separator: "\n").last.map(String.init) ?? "git worktree remove failed"
    }

    private static func run(_ arguments: [String], in directory: String) -> Data? {
        guard let result = execute(arguments, in: directory), result.status == 0 else { return nil }
        return result.output
    }

    private static func execute(_ arguments: [String], in directory: String, mergeErrors: Bool = false)
        -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // No index refresh, no file system monitor daemon
        process.arguments = ["-C", directory, "-c", "core.fsmonitor=false", "--no-optional-locks"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = mergeErrors ? output : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
