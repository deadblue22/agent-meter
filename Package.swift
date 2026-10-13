// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacMonitor",
            path: "Sources/MacMonitor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
