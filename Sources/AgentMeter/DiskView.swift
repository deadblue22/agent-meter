import AppKit
import SwiftUI

private struct TrayFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Disk usage as a ring chart: click a slice or a row to look inside, drag slices or rows into the tray to collect
/// them, then delete what was collected.
struct DiskView: View {
    @ObservedObject var disk: DiskExplorer
    @State private var pending: DeletePlan?
    @State private var pendingQuit: QuitPlan?
    @State private var dragging: (id: String, location: CGPoint)?
    @State private var trayFrame = CGRect.zero
    /// The width of the list on the right; dragging the handle between it and the chart changes it
    @AppStorage("diskPanelWidth") private var storedPanelWidth = 500.0
    @State private var panelDragStart: CGFloat?
    @State private var handleHovered = false

    private let panelRange: ClosedRange<CGFloat> = 340...780
    private let chartMinimum: CGFloat = 440
    private let rowLimit = 80
    private let canDeleteWidth: CGFloat = 84
    private let sizeWidth: CGFloat = 74
    private let accent = Theme.accent

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                if let focus = disk.focus {
                    content(focus)
                } else {
                    start
                }
            }
            if let dragging, let node = disk.node(dragging.id) {
                chip(node, removable: false)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.36, green: 0.27, blue: 0.62)))
                    .shadow(radius: 8)
                    .position(x: dragging.location.x + 14, y: dragging.location.y + 20)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "disk")
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(minWidth: 860, minHeight: 560)
        .confirmationDialog(confirmation?.title ?? "",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { pending = nil; pendingQuit = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmation) { confirmation in
            Button(confirmation.button, role: .destructive, action: confirmation.action)
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// What the one confirmation dialog asks: to delete, or to end a session
    private struct Confirmation {
        let title: String
        let message: String
        let button: String
        let action: () -> Void
    }

    private var confirmation: Confirmation? {
        if let plan = pending {
            return Confirmation(title: plan.title, message: plan.message,
                                button: (plan.force ? "Force Delete " : "Delete ") + Format.bytes(plan.bytes),
                                action: { Task { await disk.delete(plan) } })
        }
        if let plan = pendingQuit {
            return Confirmation(title: plan.title, message: plan.message,
                                button: "Force Quit (\(Format.processes(plan.targets.count)))",
                                action: { Task { await disk.quit(plan) } })
        }
        return nil
    }

    private var start: some View {
        VStack(spacing: 10) {
            if disk.running {
                ProgressView(disk.progress)
            } else {
                Text("Scan the disk to see what each session leaves behind")
                    .font(.title3.weight(.semibold))
                Text("Scratch files, worktrees, dependencies and caches, and which of them can be deleted. This reads every file under those folders and takes about half a minute.")
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    Task { await disk.scan() }
                } label: {
                    Label("Scan Disk", systemImage: "arrow.clockwise").padding(.horizontal, 8)
                }
                .buttonStyle(ThemeButtonStyle(prominent: true, large: true))
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ focus: DiskNode) -> some View {
        let arcs = SunburstLayout.arcs(for: focus, children: { disk.children(of: $0) })
        let shown = disk.hovered.flatMap { disk.node($0) } ?? focus
        let collected = Set(disk.collected)
        let faded = collected.isEmpty ? [] : Set(arcs.map(\.id).filter { disk.isCollected($0, among: collected) })
        return GeometryReader { proxy in
            // Never so wide that the chart is squeezed below its minimum
            let room = proxy.size.width - 32 - 16 - chartMinimum
            let panelWidth = min(max(CGFloat(storedPanelWidth), panelRange.lowerBound), max(room, panelRange.lowerBound))
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 14) {
                    SunburstView(
                        arcs: arcs,
                        title: shown.name,
                        subtitle: Format.bytes(shown.bytes),
                        hovered: disk.hovered,
                        collected: faded,
                        onHover: { hit in
                            if case .arc(let id) = hit {
                                if disk.hovered != id { disk.hovered = id }
                            } else if disk.hovered != nil {
                                disk.hovered = nil
                            }
                        },
                        onClick: { hit in
                            switch hit {
                            case .center: disk.goUp()
                            case .arc(let id): disk.open(id)
                            case .none: break
                            }
                        },
                        onDrag: { id, location in dragging = (id, location) },
                        onDrop: { id, location in
                            dragging = nil
                            if trayFrame.contains(location) { disk.collect(id) }
                        })
                        .contextMenu { menu(for: disk.hovered) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    tray
                }
                resizeHandle(current: panelWidth)
                sidePanel(focus)
                    .frame(width: panelWidth)
            }
            .padding(16)
        }
    }

    /// A thin strip between the chart and the list: drag it to give the list more or less room
    private func resizeHandle(current: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(handleHovered || panelDragStart != nil ? 0.28 : 0.0))
            .frame(width: 3, height: 64)
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                handleHovered = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if panelDragStart == nil { panelDragStart = current }
                        let width = (panelDragStart ?? current) - value.translation.width
                        storedPanelWidth = Double(min(max(width, panelRange.lowerBound), panelRange.upperBound))
                    }
                    .onEnded { _ in panelDragStart = nil }
            )
            .help("Drag to resize the list")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { disk.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(disk.past.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
            Button { disk.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(disk.future.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])")
            breadcrumb
            if disk.running {
                if let fraction = disk.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 110)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(disk.progress).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            } else if let notice = disk.notice {
                Text(notice).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle).help(notice)
            } else if let report = disk.report {
                Text("Scanned \(report.time.formatted(date: .omitted, time: .shortened)) in \(String(format: "%.0f", report.seconds)) s")
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            if disk.report != nil {
                Button { Task { await disk.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(disk.running)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Rescan (⌘R)")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Where the chart is centred; each step can be clicked. The earliest steps are shortened first.
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            crumb("All sessions", to: [], isLast: disk.trail.isEmpty, priority: 0)
            ForEach(Array(disk.trail.enumerated()), id: \.offset) { offset, id in
                let isLast = offset == disk.trail.count - 1
                Text("/").foregroundStyle(.white.opacity(0.3))
                crumb(disk.node(id)?.name ?? "…", to: Array(disk.trail.prefix(offset + 1)), isLast: isLast, priority: isLast ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumb(_ name: String, to target: [String], isLast: Bool, priority: Double) -> some View {
        Button(name) { disk.navigate(target) }
            .foregroundStyle(isLast ? .white : .white.opacity(0.55))
            .lineLimit(1)
            .layoutPriority(priority)
    }

    // MARK: Side panel

    private func sidePanel(_ focus: DiskNode) -> some View {
        let kids = disk.children(of: focus)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(focus.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Text(Format.bytes(focus.bytes)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Text(summary(focus, kids))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(.top, 2)
                .padding(.bottom, 10)
            HStack(spacing: 0) {
                Spacer()
                Text("Can delete").frame(width: canDeleteWidth, alignment: .trailing)
                Text("Size").frame(width: sizeWidth + 6, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            if focus.expandable, kids.isEmpty {
                Text(disk.listing.contains(focus.id) ? "Measuring…" : "Empty").foregroundStyle(.white.opacity(0.5)).padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(kids.prefix(rowLimit).enumerated()), id: \.element.id) { index, child in
                        row(child, index: index, count: kids.count, total: focus.bytes)
                    }
                    if kids.count > rowLimit {
                        let rest = kids.dropFirst(rowLimit)
                        HStack {
                            Text("\(rest.count) more items…").foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Text(Format.bytes(rest.reduce(0) { $0 + $1.bytes })).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                    }
                }
            }
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 10)
            legend
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .themedPanel()
    }

    private func summary(_ focus: DiskNode, _ kids: [DiskNode]) -> String {
        switch focus.kind {
        case .root:
            let sessions = focus.children.filter { $0.kind == .session }.count
            return "\(sessions) sessions · \(Format.bytes(focus.deletableBytes)) can be deleted"
        case .session, .part:
            let deletable = focus.deletableBytes > 0 ? "\(Format.bytes(focus.deletableBytes)) can be deleted · " : ""
            return deletable + focus.detail
        case .others:
            return focus.detail
        case .folder:
            return [focus.path.map(Collector.shortPath), kids.isEmpty ? nil : "\(kids.count) items"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func row(_ child: DiskNode, index: Int, count: Int, total: UInt64) -> some View {
        let hue = SunburstLayout.hue(index: index, count: count)
        let vivid = child.deletableBytes > 0
        let hot = disk.hovered == child.id
        let share = total > 0 ? Double(child.bytes) / Double(total) : 0
        return HStack(spacing: 10) {
            Circle().fill(SunburstView.color(hue: hue, ring: 1, vivid: vivid, highlighted: hot)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let source = child.source { SourceBadge(source: source) }
                    if let detail = rowDetail(child) {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 8)
            Group {
                if child.deletableBytes > 0 {
                    Text(Format.bytes(child.deletableBytes)).foregroundStyle(Theme.positive).monospacedDigit()
                } else if child.kind == .part || child.kind == .session {
                    Image(systemName: "lock").font(.caption).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: canDeleteWidth, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(child.bytes)).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                Text(share < 0.005 ? "<1%" : String(format: "%.0f%%", share * 100))
                    .font(.caption2).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
            }
            .frame(width: sizeWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hot ? .white.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .help(child.detail.isEmpty ? child.name : "\(child.name)\n\(child.detail)")
        .onHover { inside in
            if inside { disk.hovered = child.id } else if disk.hovered == child.id { disk.hovered = nil }
        }
        .onTapGesture { disk.open(child.id) }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("disk"))
                .onChanged { dragging = (child.id, $0.location) }
                .onEnded { value in
                    dragging = nil
                    if trayFrame.contains(value.location) { disk.collect(child.id) }
                }
        )
        .contextMenu { menu(for: child.id) }
    }

    /// The second line of a row: what state a session is in, then where it is, so that a long path is what gets cut
    /// short; or why a part is deletable or not
    private func rowDetail(_ child: DiskNode) -> String? {
        switch child.kind {
        case .session:
            let segments = child.detail.components(separatedBy: " · ")
            return segments.count > 1 ? (Array(segments.dropFirst()) + [segments[0]]).joined(separator: " · ") : child.detail
        case .part, .others:
            return child.detail.isEmpty ? nil : child.detail
        case .folder, .root:
            return nil
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(SunburstView.color(hue: 0.62, ring: 1, vivid: true, highlighted: false)).frame(width: 9, height: 9)
                    Text("Can be deleted")
                }
                HStack(spacing: 6) {
                    Circle().fill(SunburstView.color(hue: 0.62, ring: 1, vivid: false, highlighted: false)).frame(width: 9, height: 9)
                    Text("Kept")
                }
            }
            .font(.caption)
            Text("Kept by default: running sessions, worktrees with changes or with files git ignores, and conversations, which are never deleted. Files git ignores can be collected on their own if you decide they are not needed. Deleting is permanent; every part is checked again right before it goes.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tray

    private var tray: some View {
        let plan = disk.collectedPlan
        let over = dragging.map { trayFrame.contains($0.location) } ?? false
        return HStack(spacing: 12) {
            if disk.collected.isEmpty {
                Text("Drag slices or rows here to collect them")
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !disk.running, let all = disk.allPlan {
                    Button("Add all (\(Format.bytes(all.bytes)))") { disk.collectAll() }
                        .buttonStyle(.link)
                        .foregroundStyle(accent)
                        .help("Collect everything that can be deleted")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(disk.collected, id: \.self) { id in
                            if let node = disk.node(id) {
                                chip(node, removable: true)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(.white.opacity(0.12)))
                            }
                        }
                    }
                }
            }
            Button(role: .destructive) {
                pending = plan
            } label: {
                Label(plan.map { "Delete \(Format.bytes($0.bytes))" } ?? "Delete", systemImage: "trash")
            }
            .buttonStyle(ThemeButtonStyle())
            .disabled(plan == nil || disk.running)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(over ? 0.16 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(over ? 0.9 : 0), lineWidth: 2))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TrayFrameKey.self, value: proxy.frame(in: .named("disk")))
        })
        .onPreferenceChange(TrayFrameKey.self) { trayFrame = $0 }
    }

    private func chip(_ node: DiskNode, removable: Bool) -> some View {
        HStack(spacing: 6) {
            if node.item?.needsConsent == true {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Files git ignores: they exist only on this Mac")
            }
            Text(node.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 190)
            Text(Format.bytes(disk.freed(by: node))).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
            if removable {
                Button { disk.uncollect(node.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    // MARK: Menu

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func menu(for id: String?) -> some View {
        if let id, let node = disk.node(id) {
            if node.kind != .others, node.kind != .root, !disk.children(of: node).isEmpty || node.expandable {
                Button("Open") { disk.open(id) }
            }
            Button("Copy Name") { copy(node.name) }
            if let path = node.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") { copy(path) }
            }
            if let consent = disk.consentPlan(for: id) {
                Divider()
                Button("Delete Ignored Files (\(Format.bytes(consent.bytes)))…", role: .destructive) { pending = consent }
            } else if let reason = disk.ignoredBlocker(for: id) {
                Divider()
                Button("Delete Ignored Files… (\(reason))") {}.disabled(true)
            }
            if node.kind == .session || node.kind == .part {
                Divider()
                Button("Add to Collection") { disk.collect(id) }
                if let plan = disk.plan(for: [id]) {
                    Button("Delete \(Format.bytes(plan.bytes))…", role: .destructive) { pending = plan }
                }
            }
            // Apart from the rest: it takes what the other entries leave alone
            if let force = disk.forcePlan(for: id) {
                Divider()
                Button("Force Delete \(Format.bytes(force.bytes))…", role: .destructive) { pending = force }
            } else if let reason = disk.forceBlocker(for: id) {
                Divider()
                Button("Force Delete… (\(reason))") {}.disabled(true)
            }
            // What holds a session's files back can be ended from here
            if disk.isHeld(id) {
                Divider()
                Button("Force Quit Session…", role: .destructive) {
                    Task { pendingQuit = await disk.prepareQuit(id) }
                }.disabled(disk.running)
            }
        }
    }
}
