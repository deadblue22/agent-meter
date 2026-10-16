import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The window: a switch between the live process list and the disk usage scan. Both results are kept here so
/// neither is lost, or taken again, when switching.
struct RootView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case processes = "Processes"
        case disk = "Disk"
        var id: String { rawValue }
    }

    @State private var mode = Mode.processes
    @State private var report: Report?
    @StateObject private var disk = DiskExplorer()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch mode {
            case .processes: ContentView(report: $report)
            case .disk: DiskView(disk: disk)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accentStrong)
        .background(WindowStyler())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--dump-disk") {
            Dump.runDisk()
            exit(0)
        }
    }

    var body: some Scene {
        Window("Agent Meter", id: "main") {
            RootView()
        }
        .defaultSize(width: 1040, height: 820)
    }
}
