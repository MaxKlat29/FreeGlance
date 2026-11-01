import CoreGraphics
import Foundation

struct DisplayInfo: Sendable, Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var name: String
}

struct ScreenSelector: Sendable {
    /// Points this far (fraction of its height) below the lowest display count as away.
    static let belowLowestFraction = 0.1

    var displays: [DisplayInfo] {
        didSet {
            if let current, !displays.contains(where: { $0.id == current }) {
                self.current = nil
            }
            pending.reset()
            pendingSwitch = nil
        }
    }
    var dwell: TimeInterval
    var turnThreshold: Double
    var hysteresis: Double
    var ignoreMargin: Double
    private(set) var current: CGDirectDisplayID?
    /// A fired switch that focus has not applied yet (typing, mouse in use) and the screen it left.
    private(set) var pendingSwitch: (to: CGDirectDisplayID, from: CGDirectDisplayID)?
    private var pending: Dwell<CGDirectDisplayID>

    init(displays: [DisplayInfo], dwell: TimeInterval = 0.3, turnThreshold: Double = 0.5,
         hysteresis: Double = 0.12, ignoreMargin: Double? = nil) {
        self.displays = displays
        self.dwell = dwell
        self.turnThreshold = turnThreshold
        self.hysteresis = hysteresis
        self.ignoreMargin = ignoreMargin ?? Self.defaultIgnoreMargin(for: displays)
        self.pending = Dwell(duration: dwell)
    }

    static func defaultIgnoreMargin(for displays: [DisplayInfo]) -> Double {
        0.35 * Double(displays.map(\.frame.width).min() ?? 0)
    }

    mutating func setCurrent(_ id: CGDirectDisplayID?) {
        current = id.flatMap { id in displays.contains { $0.id == id } ? id : nil }
        pending.reset()
        pendingSwitch = nil
    }

    /// Hands a fired switch to focus; it counts as applied from here on.
    mutating func takePendingSwitch() -> CGDirectDisplayID? {
        defer { pendingSwitch = nil }
        return pendingSwitch?.to
    }

    /// Holds the screen focus is on: drops the pending dwell and undoes a switch not applied yet.
    mutating func hold() {
        if let from = pendingSwitch?.from { current = from }
        pendingSwitch = nil
        pending.reset()
    }

    /// Geometric away rule: far outside every screen, or clearly below the lowest one (keyboard, desk).
    func isAway(_ p: CGPoint) -> Bool {
        guard let lowest = displays.min(by: { $0.frame.minY < $1.frame.minY }) else { return false }
        let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            .insetBy(dx: -ignoreMargin, dy: -ignoreMargin)
        let floor = Double(lowest.frame.minY) - Self.belowLowestFraction * Double(lowest.frame.height)
        return !bounds.contains(p) || Double(p.y) < floor
    }

    /// Feeds one gaze point. `away` (from the keyboard classifier) holds the current screen like
    /// the geometric rule does. Returns the display id only when a switch fires.
    @discardableResult
    mutating func update(point: CGPoint, away: Bool = false, at t: TimeInterval) -> CGDirectDisplayID? {
        guard displays.count >= 2 else { return nil }
        guard !away, !isAway(point) else {
            hold()
            return nil
        }
        guard let from = displays.first(where: { $0.id == current }) else {
            current = nearest(to: point)?.id
            pending.reset()
            return nil
        }
        let required = turnThreshold + hysteresis
        let candidate = displays
            .filter { $0.id != from.id }
            .map { (id: $0.id, frame: $0.frame, fraction: Self.fraction(of: point, from: from.frame, to: $0.frame)) }
            .filter { $0.fraction > required }
            .min { Self.distance(point, $0.frame) < Self.distance(point, $1.frame) }
        pending.duration = (candidate?.fraction ?? 0) >= 1 ? dwell / 2 : dwell
        guard let fired = pending.update(candidate?.id, at: t) else { return nil }
        let origin = pendingSwitch?.from ?? from.id
        pendingSwitch = fired == origin ? nil : (fired, origin)
        current = fired
        return fired
    }

    static func fraction(of p: CGPoint, from a: CGRect, to b: CGRect) -> Double {
        let ax = Double(a.midX), ay = Double(a.midY)
        let dx = Double(b.midX) - ax, dy = Double(b.midY) - ay
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return 0 }
        return ((Double(p.x) - ax) * dx + (Double(p.y) - ay) * dy) / length2
    }

    private func nearest(to p: CGPoint) -> DisplayInfo? {
        displays.min { Self.distance(p, $0.frame) < Self.distance(p, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(Double(r.minX) - Double(p.x), 0, Double(p.x) - Double(r.maxX))
        let dy = max(Double(r.minY) - Double(p.y), 0, Double(p.y) - Double(r.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}
