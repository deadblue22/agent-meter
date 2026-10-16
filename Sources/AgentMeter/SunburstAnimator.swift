import Foundation

/// Moves the chart's slices from where they are to where the layout now wants them.
///
/// Every slice keeps its state under the ID of the node it stands for, so that when the layout changes, a slice that
/// exists in both the old and the new layout glides from its old angles and ring to the new ones: opening a slice
/// makes it expand into the middle, going back up lets the middle grow out into a ring again, and while a scan
/// fills in, slices swell as their sizes grow. New slices fade in and grow outward; slices that are gone fade out.
final class SunburstAnimator {
    struct Segment {
        let key: String
        /// Ring position: 0 is the middle disc, 1 the ring around it. Between two numbers it is in between.
        var ring: Double
        var start: Double
        var end: Double
        var hue: Double
        /// 1 for slices with something deletable, 0 for dim ones
        var vivid: Double
        var alpha: Double
        /// Radial growth of a slice that just appeared, 0 to 1; negative values wait before growing
        var grow: Double
        /// 1 while the pointer is over it
        var hover: Double = 0
        /// 1 once it is in the tray
        var collected: Double = 0
        var alive = true
        var targetRing: Double
        var targetStart: Double
        var targetEnd: Double
        var targetHue: Double
        var targetVivid: Double
        var targetAlpha: Double
    }

    private(set) var segments: [String: Segment] = [:]
    /// Inner rings first
    private(set) var order: [String] = []
    var hovered: String?
    var collected = Set<String>()
    /// Jump to the targets instead of gliding
    var reduceMotion = false

    /// Rate of the glide: the share of the remaining distance covered per second is 1 - e^-rate
    private let rate = 11.0
    private let hoverRate = 18.0

    /// Points the slices at a new layout. The first layout is introduced with a stagger from the inside out.
    func setTarget(_ arcs: [SunburstArc]) {
        let intro = segments.isEmpty
        for key in segments.keys { segments[key]?.alive = false }
        order = []
        for arc in arcs {
            order.append(arc.id)
            let alpha = arc.isCenter ? 0.0 : 1.0
            if var segment = segments[arc.id] {
                segment.alive = true
                segment.targetRing = Double(arc.ring)
                segment.targetStart = arc.start
                segment.targetEnd = arc.end
                if !arc.isCenter {
                    segment.targetHue = arc.hue
                    segment.targetVivid = arc.vivid ? 1 : 0
                }
                segment.targetAlpha = alpha
                segments[arc.id] = segment
            } else {
                let delay = intro ? -(0.12 * Double(arc.ring) + 0.25 * arc.start / (2 * .pi)) : 0
                segments[arc.id] = Segment(
                    key: arc.id, ring: Double(arc.ring), start: arc.start, end: arc.end, hue: arc.hue,
                    vivid: arc.vivid ? 1 : 0, alpha: 0, grow: delay,
                    targetRing: Double(arc.ring), targetStart: arc.start, targetEnd: arc.end, targetHue: arc.hue,
                    targetVivid: arc.vivid ? 1 : 0, targetAlpha: alpha)
            }
        }
        if reduceMotion { snap() }
    }

    /// Advances every slice by `dt` seconds. Returns whether anything is still moving.
    @discardableResult
    func step(dt: Double) -> Bool {
        if reduceMotion { snap() }
        let glide = 1 - exp(-dt * rate)
        let quick = 1 - exp(-dt * hoverRate)
        var moving = false
        segments = segments.filter { $0.value.alive || $0.value.alpha > 0.01 }
        for key in segments.keys {
            guard var s = segments[key] else { continue }
            let hoverTarget = key == hovered ? 1.0 : 0.0
            let collectedTarget = collected.contains(key) ? 1.0 : 0.0
            s.hover += (hoverTarget - s.hover) * quick
            s.collected += (collectedTarget - s.collected) * quick
            if abs(s.hover - hoverTarget) > 0.01 || abs(s.collected - collectedTarget) > 0.01 { moving = true }
            if s.alive {
                s.start += (s.targetStart - s.start) * glide
                s.end += (s.targetEnd - s.end) * glide
                s.ring += (s.targetRing - s.ring) * glide
                s.hue += Self.shortest(from: s.hue, to: s.targetHue) * glide
                s.vivid += (s.targetVivid - s.vivid) * glide
                s.alpha += (s.targetAlpha - s.alpha) * glide
                s.grow = min(s.grow + dt * 2.6, 1)
                if abs(s.targetStart - s.start) > 1e-4 || abs(s.targetEnd - s.end) > 1e-4 || abs(s.targetRing - s.ring) > 1e-3
                    || abs(s.targetAlpha - s.alpha) > 0.005 || abs(s.targetVivid - s.vivid) > 0.005
                    || abs(Self.shortest(from: s.hue, to: s.targetHue)) > 1e-3 || s.grow < 1 {
                    moving = true
                }
            } else {
                s.alpha = max(0, s.alpha - (s.alpha * glide * 1.4 + dt * 0.5))
                moving = true
            }
            segments[key] = s
        }
        return moving
    }

    /// Fading slices first, so that they sit behind the live ones
    var drawList: [Segment] {
        let fading = segments.values.filter { !$0.alive && $0.alpha > 0.01 }
        return fading + order.compactMap { segments[$0] }.filter(\.alive)
    }

    var isSettled: Bool {
        segments.values.allSatisfy { s in
            s.alive ? (abs(s.targetStart - s.start) < 1e-4 && abs(s.targetEnd - s.end) < 1e-4 && abs(s.targetRing - s.ring) < 1e-3
                       && abs(s.targetAlpha - s.alpha) < 0.005 && s.grow >= 1) : s.alpha <= 0.01
        }
    }

    private func snap() {
        segments = segments.filter { $0.value.alive }
        for key in segments.keys {
            guard var s = segments[key] else { continue }
            s.start = s.targetStart; s.end = s.targetEnd; s.ring = s.targetRing; s.hue = s.targetHue
            s.vivid = s.targetVivid; s.alpha = s.targetAlpha; s.grow = 1
            s.hover = key == hovered ? 1 : 0
            s.collected = collected.contains(key) ? 1 : 0
            segments[key] = s
        }
    }

    /// The signed distance from one hue to another the short way round the colour wheel
    static func shortest(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        return delta
    }

    /// 0 to 1, fast at first and slowing down
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - pow(1 - t, 3)
    }
}
