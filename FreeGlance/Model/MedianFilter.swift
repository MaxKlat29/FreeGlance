import CoreGraphics
import Foundation

/// Component-wise median of the last three points: a single-frame spike never gets through,
/// a real step passes on its second frame. Starts over after a gap of `resetGap`.
struct MedianFilter: Sendable {
    var resetGap: TimeInterval = 0.5

    private var recent: [CGPoint] = []
    private var lastTime: TimeInterval?

    mutating func filter(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        if let lastTime, t <= lastTime || t - lastTime > resetGap { recent = [] }
        lastTime = t
        recent.append(p)
        if recent.count > 3 { recent.removeFirst() }
        guard recent.count == 3 else { return p }
        return CGPoint(x: Self.median(recent.map(\.x)), y: Self.median(recent.map(\.y)))
    }

    mutating func reset() {
        recent = []
        lastTime = nil
    }

    private static func median(_ v: [CGFloat]) -> CGFloat {
        max(min(v[0], v[1]), min(max(v[0], v[1]), v[2]))
    }
}
