import Foundation
import Darwin

// Run: swiftc Sources/AgentMeter/Git.swift Tests/WorktreeDiscovery.swift -o /tmp/agent-meter-worktree-test
//      /tmp/agent-meter-worktree-test
@main
enum WorktreeDiscoveryTest {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let resolved = realpath(temporary.path, nil)!
        let base = String(cString: resolved)
        free(resolved)
        let repo = base + "/repo"
        let custom = base + "/mesh-wt/task with space\nand newline"
        let missing = base + "/missing"
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        try git(["init", repo])
        try git(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-m", "Initial"])
        try git(["-C", repo, "worktree", "add", "--detach", custom])
        try git(["-C", repo, "worktree", "add", "--detach", missing])
        try fm.removeItem(atPath: missing)
        try fm.createDirectory(atPath: custom + "/subdir", withIntermediateDirectories: true)
        let roots = Git.linkedWorktrees(among: [repo, custom, custom + "/subdir", base, missing])
        precondition(roots == [custom], "Discover custom worktrees once; exclude main checkouts and missing paths: \(roots)")
        let moved = base + "/moved"
        try fm.moveItem(atPath: custom, toPath: moved)
        try fm.createSymbolicLink(atPath: custom, withDestinationPath: moved)
        precondition(Git.linkedWorktrees(among: [repo]).isEmpty, "Do not follow symbolic links")
        print("Worktree discovery passed")
    }
}
