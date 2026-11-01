import CoreGraphics
import Foundation

struct DisplayInfo: Sendable, Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var name: String
}

struct ScreenSelector: Sendable {
    var displays: [DisplayInfo] {
        didSet {
            if let current, !displays.contains(where: { $0.id == current }) {
                self.current = nil
            }
            pending.reset()
        }
    }
    var dwell: TimeInterval
    var turnThreshold: Double
    var hysteresis: Double
    var ignoreMargin: Double
    private(set) var current: CGDirectDisplayID?
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
    }

    mutating func update(headPoint: CGPoint, at t: TimeInterval) -> CGDirectDisplayID? {
        guard displays.count >= 2 else { return nil }
        let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            .insetBy(dx: -ignoreMargin, dy: -ignoreMargin)
        guard bounds.contains(headPoint) else {
            pending.reset()
            return nil
        }
        guard let from = displays.first(where: { $0.id == current }) else {
            current = nearest(to: headPoint)?.id
            pending.reset()
            return nil
        }
        let required = turnThreshold + hysteresis
        let candidate = displays
            .filter { $0.id != from.id && Self.fraction(of: headPoint, from: from.frame, to: $0.frame) > required }
            .min { Self.distance(headPoint, $0.frame) < Self.distance(headPoint, $1.frame) }?
            .id
        pending.duration = dwell
        guard let fired = pending.update(candidate, at: t) else { return nil }
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
