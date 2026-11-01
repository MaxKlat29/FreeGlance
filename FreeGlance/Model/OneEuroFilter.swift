import CoreGraphics
import Foundation

/// One Euro filter (Casiez et al. 2012) on a 2D point: heavy smoothing while the gaze rests,
/// almost no lag while it moves, so a turn registers immediately but fixation jitter does not.
struct OneEuroFilter: Sendable {
    var minCutoff: Double = 0.8   // Hz, jitter suppression at rest
    var beta: Double = 0.004      // per pt/s, how fast the cutoff opens with speed
    var derivativeCutoff: Double = 1.0
    var resetGap: TimeInterval = 0.5

    private var last: (point: CGPoint, velocity: CGVector, t: TimeInterval)?

    mutating func filter(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        guard let prev = last, t > prev.t, t - prev.t <= resetGap else {
            last = (p, .zero, t)
            return p
        }
        let dt = t - prev.t
        let raw = CGVector(dx: (p.x - prev.point.x) / dt, dy: (p.y - prev.point.y) / dt)
        let ad = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let v = CGVector(dx: prev.velocity.dx + ad * (raw.dx - prev.velocity.dx),
                         dy: prev.velocity.dy + ad * (raw.dy - prev.velocity.dy))
        let speed = hypot(Double(v.dx), Double(v.dy))
        let a = Self.alpha(cutoff: minCutoff + beta * speed, dt: dt)
        let out = CGPoint(x: prev.point.x + a * (p.x - prev.point.x), y: prev.point.y + a * (p.y - prev.point.y))
        last = (out, v, t)
        return out
    }

    mutating func reset() { last = nil }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
