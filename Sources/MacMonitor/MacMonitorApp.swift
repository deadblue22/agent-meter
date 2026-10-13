import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
            exit(0)
        }
    }

    var body: some Scene {
        Window("Mac Monitor", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1040, height: 820)
    }
}
