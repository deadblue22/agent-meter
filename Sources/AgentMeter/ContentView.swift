import AppKit
import SwiftUI

/// Height of every row in the lists, including the list's own insets (4 points above and below the content).
/// Rows that have not been shown yet are assumed to be this tall; if they turn out taller or shorter, the list moves
/// under the pointer as they scroll into view, so every row's content is given exactly the height that makes it this.
let listRowHeight: CGFloat = 42
let listRowContentHeight: CGFloat = listRowHeight - 8

enum SortKey: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case cpu = "CPU"
    var id: String { rawValue }
}

/// One row of the outline: a session (expandable) or a process (leaf).
struct Row: Identifiable {
    enum Source { case claude, codex, none }

    /// What ending this row means; nil when ending is not offered (the apps themselves, their processes, Agent Meter itself)
    enum KillKind { case claudeSession, leftovers, codexThread, process }

    let id: String
    let source: Source
    let title: String
    let detail: String
    let isSession: Bool
    let isBusy: Bool
    let processCount: Int
    let cpu: Double
    let memory: UInt64
    let pid: Int32?
    /// Every process in the subtree (excluding Agent Meter itself)
    let refs: [ProcessRef]
    let killKind: KillKind?
    /// The session is over (for a process: its session is), so Clean Up applies here
    let isOver: Bool
    /// Processes in this subtree that Clean Up ends; 0 with `isOver` means everything here is a shared service and kept
    let cleanupCount: Int
    var children: [Row]?

    var pids: [Int32] { refs.map(\.pid) }

    static func session(_ node: SessionNode, sortKey: SortKey) -> Row {
        let source: Source = (node.kind == .codex || node.kind == .codexApp) ? .codex : .claude
        let isApp = node.kind == .claudeApp || node.kind == .codexApp
        let subSessions = sort(node.children, by: sortKey).map { session($0, sortKey: sortKey) }
        let processes = sort(node.processes, by: sortKey).map {
            process($0, source: source, killable: !isApp, isOver: node.isOver, cleanedUp: Cleanup.isTarget($0, in: node))
        }
        let children = subSessions + processes
        let killKind: KillKind? = switch node.kind {
        case .claude: node.isLeftover ? .leftovers : .claudeSession
        case .codex: .codexThread
        case .claudeApp, .codexApp: nil
        }
        return Row(id: node.id, source: source, title: node.title, detail: node.detail, isSession: true,
                   isBusy: node.isBusy, processCount: node.processCount, cpu: node.cpu, memory: node.memory,
                   pid: nil, refs: children.flatMap(\.refs), killKind: killKind, isOver: node.isOver,
                   cleanupCount: children.reduce(0) { $0 + $1.cleanupCount }, children: children)
    }

    static func process(_ item: ProcessItem, source: Source, killable: Bool, isOver: Bool = false,
                        cleanedUp: Bool = false) -> Row {
        let isSelf = item.pid == getpid()
        return Row(id: "pid-\(item.pid)", source: source, title: item.name, detail: item.command, isSession: false,
                   isBusy: false, processCount: 1, cpu: item.cpu, memory: item.memory, pid: item.pid,
                   refs: isSelf ? [] : [ProcessRef(pid: item.pid, startTime: item.startTime)],
                   killKind: killable && !isSelf ? .process : nil, isOver: isOver, cleanupCount: cleanedUp ? 1 : 0,
                   children: nil)
    }

    static func sort(_ nodes: [SessionNode], by key: SortKey) -> [SessionNode] {
        nodes.sorted { key == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }

    static func sort(_ items: [ProcessItem], by key: SortKey) -> [ProcessItem] {
        items.sorted { key == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }

    /// Title and message of the confirmation dialog
    var killPrompt: (title: String, message: String)? {
        guard let killKind, !refs.isEmpty else { return nil }
        let size = "\(Format.processes(refs.count)), \(Format.bytes(memory)) in total"
        switch killKind {
        case .claudeSession:
            return ("End session “\(title)”?",
                    "Ends the session process and every process attributed to it (\(size)), including services it started in the background. The conversation can be resumed later: reopen it in the desktop app, or run `claude --resume` for a CLI session.")
        case .leftovers:
            return ("End processes left by “\(title)”?",
                    "This session has already ended. The processes it left running will be ended (\(size)).")
        case .codexThread:
            return ("End processes started by Codex thread “\(title)”?",
                    "Ends the processes started by this thread and its sub-agents (\(size)). The thread itself lives in the Codex app and is not affected.")
        case .process:
            return ("End process \(pid.map(String.init) ?? "") (\(title))?", "It uses \(Format.bytes(memory)).")
        }
    }
}

struct ContentView: View {
    @Binding var report: Report?
    @State private var loading = false
    @State private var sortKey = SortKey.memory
    @State private var selection = Set<Row.ID>()
    /// Expanded sessions, remembered by ID across refreshes
    @State private var expanded = Set<Row.ID>()
    @State private var pendingKill: Row?
    /// What is in progress besides sampling ("Ending processes…", "Cleaning up…"); nil when idle
    @State private var working: String?
    /// Result of the last kill; cleared on the next manual refresh
    @State private var notice: String?

    /// Only the top unattributed processes are listed
    private let otherLimit = 15

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if let report {
                list(report)
                Divider()
                Text("Only your own processes are counted; processes owned by root or system accounts are not visible. Claude Code sub-agents run inside the session process, so their usage counts toward the session. Codex sub-agents are separate threads and appear under their parent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ProgressView("Sampling (about \(String(format: "%.1f", Collector.sampleSeconds)) s)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { if report == nil { await refresh() } }
        .confirmationDialog(pendingKill?.killPrompt?.title ?? "",
                            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingKill) { row in
            Button("End \(Format.processes(row.refs.count))", role: .destructive) {
                Task { await terminate(row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(row.killPrompt?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    notice = nil
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(loading || working != nil)
                Button(role: .destructive) {
                    pendingKill = selectedRow
                } label: {
                    Label("End…", systemImage: "xmark.octagon")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedRow?.killPrompt == nil || loading || working != nil)
                .help("End the selected session or process (⌘⌫)")
                let targets = report.map(Cleanup.targets) ?? []
                Button {
                    Task { await cleanUp() }
                } label: {
                    Label(targets.isEmpty ? "Clean Up" : "Clean Up (\(targets.count))", systemImage: "sparkles")
                }
                .disabled(targets.isEmpty || loading || working != nil)
                .help(cleanupHelp(targets))
                if loading || working != nil {
                    ProgressView().controlSize(.small)
                    Text(working ?? "Sampling…").foregroundStyle(.secondary)
                } else if let report {
                    Text("\(report.time.formatted(date: .omitted, time: .standard)) · sampled over \(String(format: "%.1f", report.sampleSeconds)) s")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Sort by")
            }
            HStack(spacing: 10) {
                if let report {
                    let m = report.memory
                    Text("CPU \(Format.percent(report.cpuTotal))%   Memory \(Format.gigabytes(m.used)) / \(Format.gigabytes(m.total)) GB   Swap \(Format.gigabytes(m.swapUsed)) / \(Format.gigabytes(m.swapTotal)) GB")
                        .monospacedDigit()
                        .lineLimit(1)
                    PressureBadge(level: m.pressureLevel)
                }
                Spacer(minLength: 12)
                if let notice {
                    Text(notice)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(notice)
                }
            }
            .font(.callout)
        }
    }

    private func sessionRows(_ report: Report) -> [Row] {
        Row.sort(report.claude + report.codex, by: sortKey).map { Row.session($0, sortKey: sortKey) }
    }

    private func otherRows(_ report: Report) -> [Row] {
        Row.sort(report.others, by: sortKey).prefix(otherLimit).map { Row.process($0, source: .none, killable: true) }
    }

    private func rowsById(_ report: Report) -> [Row.ID: Row] {
        Dictionary((sessionRows(report) + otherRows(report)).flatMap(Self.flatten).map { ($0.id, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// The selected row, when exactly one row is selected
    private var selectedRow: Row? {
        guard selection.count == 1, let id = selection.first, let report else { return nil }
        return rowsById(report)[id]
    }

    private func list(_ report: Report) -> some View {
        let sessions = sessionRows(report)
        let others = Row.sort(report.others, by: sortKey)
        let otherRows = otherRows(report)
        let hidden = others.dropFirst(otherLimit)
        let claudeCount = report.claude.filter { $0.kind == .claude }.count
        let codexCount = report.codex.filter { $0.kind == .codex }.count
        let rowsById = rowsById(report)

        return List(selection: $selection) {
            Section {
                ForEach(visibleRows(sessions)) { entry in
                    RowView(row: entry.row, depth: entry.depth, isExpanded: expanded.contains(entry.row.id)) {
                        toggle(entry.row.id)
                    }
                }
            } header: {
                HStack {
                    Text("Sessions · Claude Code \(claudeCount) · Codex \(codexCount)")
                    Spacer()
                    Totals(count: sessions.reduce(0) { $0 + $1.processCount },
                           cpu: sessions.reduce(0) { $0 + $1.cpu },
                           memory: sessions.reduce(0) { $0 + $1.memory })
                }
            }
            Section {
                ForEach(otherRows) { RowView(row: $0) }
                if !hidden.isEmpty {
                    Text("\(Format.processes(hidden.count)) more: \(Format.bytes(hidden.reduce(0) { $0 + $1.memory })), CPU \(Format.percent(hidden.reduce(0) { $0 + $1.cpu }))%")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Not attributed to any session")
                    Spacer()
                    Totals(count: others.count, cpu: others.reduce(0) { $0 + $1.cpu },
                           memory: others.reduce(0) { $0 + $1.memory })
                }
            }
        }
        .environment(\.defaultMinListRowHeight, listRowHeight)
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            menu(ids.compactMap { rowsById[$0] })
        } primaryAction: { ids in
            // Double-clicking a session row expands or collapses it
            for id in ids where rowsById[id]?.children?.isEmpty == false { toggle(id) }
        }
    }

    @ViewBuilder
    private func menu(_ rows: [Row]) -> some View {
        if rows.count == 1, let row = rows.first {
            if row.isSession {
                Button("Copy Session Name") { copy(row.title) }
            } else {
                Button("Copy Command") { copy(row.detail) }
            }
        }
        if !rows.isEmpty {
            let pids = rows.flatMap(\.pids)
            Button(pids.count == 1 ? "Copy PID" : "Copy \(pids.count) PIDs") {
                copy(pids.map(String.init).joined(separator: " "))
            }
        }
        if rows.count == 1, let row = rows.first, row.killPrompt != nil {
            Divider()
            Button(row.isSession ? "End Session…" : "End Process…", role: .destructive) { pendingKill = row }
        }
    }

    private struct VisibleRow: Identifiable {
        let row: Row
        let depth: Int
        var id: Row.ID { row.id }
    }

    /// Flattens the session tree according to the expansion state. Expanding and collapsing only insert or
    /// remove rows, avoiding the outline control's transition animation, which briefly overlaps old and new rows.
    private func visibleRows(_ rows: [Row], depth: Int = 0) -> [VisibleRow] {
        rows.flatMap { row -> [VisibleRow] in
            let own = VisibleRow(row: row, depth: depth)
            guard expanded.contains(row.id), let children = row.children else { return [own] }
            return [own] + visibleRows(children, depth: depth + 1)
        }
    }

    private func toggle(_ id: Row.ID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private static func flatten(_ row: Row) -> [Row] {
        [row] + (row.children ?? []).flatMap(flatten)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func terminate(_ row: Row) async {
        working = "Ending processes…"
        let refs = row.refs
        let outcome = await Task.detached(priority: .userInitiated) { Killer.terminate(refs) }.value
        notice = "“\(row.title)”: \(outcome.summary)"
        working = nil
        selection.removeAll()
        await refresh()
    }

    private func cleanupHelp(_ targets: [ProcessItem]) -> String {
        let rule = "Clean Up ends, without asking: processes left by Claude Code sessions that have ended; Claude Code "
            + "CLI sessions idle for 6 hours, except channel bots; processes of Codex threads that are archived or have "
            + "had no activity for 24 hours. Shared services such as Colima, Docker and adb keep running."
        guard !targets.isEmpty else { return "Nothing to clean up. " + rule }
        return "Ends \(Format.processes(targets.count)), \(Format.bytes(targets.reduce(0) { $0 + $1.memory })) in total. " + rule
    }

    private func cleanUp() async {
        working = "Cleaning up…"
        // Decide on a fresh sample: since the last refresh a session may have been resumed and taken its processes back
        let fresh = await Task.detached(priority: .userInitiated) { Collector.collect() }.value
        let refs = Cleanup.targets(in: fresh).map { ProcessRef(pid: $0.pid, startTime: $0.startTime) }
        if refs.isEmpty {
            notice = "Clean Up: nothing to clean up"
        } else {
            let outcome = await Task.detached(priority: .userInitiated) { Killer.terminate(refs) }.value
            notice = "Clean Up: \(outcome.summary)"
        }
        working = nil
        selection.removeAll()
        await refresh()
    }

    private func refresh() async {
        loading = true
        report = await Task.detached(priority: .userInitiated) { Collector.collect() }.value
        loading = false
    }
}

struct RowView: View {
    let row: Row
    var depth = 0
    var isExpanded = false
    var onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onToggle {
                Group {
                    if row.children?.isEmpty == false {
                        Button(action: onToggle) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 14, height: 20)
                    }
                }
                .padding(.leading, CGFloat(depth) * 18)
            }
            if row.isSession {
                SourceBadge(source: row.source)
                Circle()
                    .fill(row.isBusy ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .help(row.isBusy ? "Running" : "Idle")
            } else if let pid = row.pid {
                Text(String(pid))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.title)
                        .fontWeight(row.isSession ? .medium : .regular)
                        .lineLimit(1)
                    CleanupMark(row: row)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Totals(count: row.isSession ? row.processCount : nil, cpu: row.cpu, memory: row.memory)
        }
        .frame(height: listRowContentHeight)
    }
}

/// Shows how Clean Up treats a row: a sparkle where it ends processes, a lock where it keeps a shared service
struct CleanupMark: View {
    let row: Row

    var body: some View {
        if row.cleanupCount > 0 {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.teal)
                .help(row.isSession ? "Clean Up ends \(Format.processes(row.cleanupCount)) here" : "Clean Up ends this process")
        } else if row.isOver {
            Image(systemName: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(row.isSession ? "Session is over, but Clean Up keeps its shared services running"
                                    : "Shared service: Clean Up keeps it running")
        }
    }
}

struct SourceBadge: View {
    let source: Row.Source

    var body: some View {
        let (label, color): (String, Color) = switch source {
        case .claude: ("Claude", .orange)
        case .codex: ("Codex", .blue)
        case .none: ("", .clear)
        }
        Text(label)
            .font(.caption2.bold())
            .frame(width: 46)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct Totals: View {
    let count: Int?
    let cpu: Double
    let memory: UInt64

    var body: some View {
        HStack(spacing: 0) {
            Text(count.map(Format.processes) ?? "").frame(width: 96, alignment: .trailing)
            Text("\(Format.percent(cpu))%").frame(width: 70, alignment: .trailing)
            Text(Format.bytes(memory)).frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

struct PressureBadge: View {
    let level: Int32

    var body: some View {
        let (label, color): (String, Color) = switch level {
        case 1: ("Pressure: Normal", .green)
        case 2: ("Pressure: Warning", .orange)
        case 4: ("Pressure: Critical", .red)
        default: ("Pressure: Unknown", .secondary)
        }
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .help("macOS memory pressure level")
    }
}
