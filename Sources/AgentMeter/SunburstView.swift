import SwiftUI

/// The ring chart: slices for what is inside the focused node, a hole in the middle that names it. It draws, animates
/// and reports what happened; the owner decides what a hover, a click or a drag means.
///
/// Slices glide between layouts (see `SunburstAnimator`). A frame loop runs only while something is moving, so a chart
/// at rest costs nothing.
struct SunburstView: View {
    let arcs: [SunburstArc]
    let title: String
    let subtitle: String
    let hovered: String?
    /// Slices that were collected for deletion, drawn faded
    let collected: Set<String>
    var onHover: (SunburstGeometry.Hit) -> Void
    var onClick: (SunburstGeometry.Hit) -> Void
    /// While dragging a slice: its ID and where the pointer is, in the "disk" coordinate space
    var onDrag: (String, CGPoint) -> Void
    var onDrop: (String, CGPoint) -> Void

    @State private var dragStart: SunburstGeometry.Hit?
    @State private var animator = SunburstAnimator()
    /// Bumped on every animation frame so that the canvas draws again
    @State private var frame = 0
    @State private var ticker: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size)
            let _ = frame
            ZStack {
                Canvas { context, size in draw(context, SunburstGeometry(size: size)) }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: subtitle)
                .frame(width: geometry.holeRadius * 1.6)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): onHover(geometry.hit(point, in: arcs))
                case .ended: onHover(.none)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("disk"))
                    .onChanged { value in
                        let origin = proxy.frame(in: .named("disk")).origin
                        if dragStart == nil {
                            dragStart = geometry.hit(CGPoint(x: value.startLocation.x - origin.x,
                                                             y: value.startLocation.y - origin.y), in: arcs)
                        }
                        if Self.travel(value) >= 5, case .arc(let id)? = dragStart { onDrag(id, value.location) }
                    }
                    .onEnded { value in
                        defer { dragStart = nil }
                        if Self.travel(value) < 5 {
                            onClick(dragStart ?? .none)
                        } else if case .arc(let id)? = dragStart {
                            onDrop(id, value.location)
                        }
                    }
            )
        }
        .onAppear {
            animator.reduceMotion = reduceMotion
            animator.hovered = hovered
            animator.collected = collected
            animator.setTarget(arcs)
            kick()
        }
        .onChange(of: arcs) { _, new in
            animator.reduceMotion = reduceMotion
            animator.setTarget(new)
            kick()
        }
        .onChange(of: hovered) { _, new in
            animator.hovered = new
            kick()
        }
        .onChange(of: collected) { _, new in
            animator.collected = new
            kick()
        }
        .onDisappear {
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: Animation

    /// Starts the frame loop if it is not running; it stops by itself once everything has settled
    private func kick() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let dt = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let moving = animator.step(dt: min(dt, 0.05))
                frame &+= 1
                if !moving { break }
            }
            ticker = nil
        }
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, _ geometry: SunburstGeometry) {
        for segment in animator.drawList {
            let grow = SunburstAnimator.ease(segment.grow)
            guard grow > 0, segment.alpha > 0.005, segment.end - segment.start > 1e-4 else { continue }
            let (inner, outer) = Self.radii(ring: segment.ring, geometry)
            // A raised slice stands out a little; one that has just appeared grows outward from its inner edge
            let top = inner + (outer + 4 * segment.hover - inner) * grow
            let path = Self.path(start: segment.start, end: segment.end, inner: inner, outer: top, center: geometry.center)
            let opacity = segment.alpha * (1 - 0.75 * segment.collected)
            let color = Self.color(hue: segment.hue, depth: max(segment.ring - 1, 0), vivid: segment.vivid, hover: segment.hover)
            context.fill(path, with: .color(color.opacity(opacity)))
            context.stroke(path, with: .color(.black.opacity(0.55 * opacity)), lineWidth: 1)
        }
    }

    private static func travel(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    /// The inner and outer radius of a ring position: 0 is the disc in the middle, 1 the ring around it
    static func radii(ring: Double, _ geometry: SunburstGeometry) -> (inner: CGFloat, outer: CGFloat) {
        let hole = geometry.holeRadius, width = geometry.ringWidth
        let p = CGFloat(max(ring, 0))
        return (p <= 1 ? hole * p : hole + (p - 1) * width, hole + p * width)
    }

    /// A ring segment
    static func path(start: Double, end: Double, inner: CGFloat, outer: CGFloat, center: CGPoint) -> Path {
        let from = Angle.radians(start - .pi / 2), to = Angle.radians(end - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Inner rings are deeper and more saturated, outer rings lighter; slices with nothing deletable are dim, and the
    /// one under the pointer is lit
    static func color(hue: Double, depth: Double, vivid: Double, hover: Double) -> Color {
        let vividSaturation = max(0.28, 0.66 - 0.10 * depth), vividBrightness = min(1, 0.82 + 0.05 * depth)
        let dimSaturation = 0.18, dimBrightness = 0.38 + 0.03 * depth
        let saturation = dimSaturation + (vividSaturation - dimSaturation) * vivid + hover * 0.16 * (1 - vivid)
        let brightness = dimBrightness + (vividBrightness - dimBrightness) * vivid + hover * (0.18 * vivid + 0.28 * (1 - vivid))
        var wrapped = hue.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        return Color(hue: wrapped, saturation: min(saturation, 1), brightness: min(brightness, 1))
    }

    /// The same colour for a dot in the list
    static func color(hue: Double, ring: Int, vivid: Bool, highlighted: Bool) -> Color {
        color(hue: hue, depth: Double(ring - 1), vivid: vivid ? 1 : 0, hover: highlighted ? 1 : 0)
    }
}
