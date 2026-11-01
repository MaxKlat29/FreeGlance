import CoreGraphics
import Foundation

/// Fixation-aware smoothing of the gaze point: calm while the gaze rests, no lag on a saccade.
///
/// Points within `radius` of the current fixation pull it along as an exponentially weighted
/// mean (`timeConstant`). Points outside the radius are saccade candidates: once `saccadeFrames`
/// consecutive candidates agree (within `radius` of each other), a new fixation starts at their
/// mean immediately. A single stray frame never moves the output.
struct FixationFilter: Sendable {
    var radius: Double = 70
    var timeConstant: TimeInterval = 0.25
    var saccadeFrames = 2
    var resetGap: TimeInterval = 0.5

    private var fixation: (centre: CGPoint, t: TimeInterval)?
    private var candidates: [CGPoint] = []

    mutating func filter(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        guard let current = fixation, t > current.t, t - current.t <= resetGap else {
            start(at: p, t: t)
            return p
        }
        if distance(p, current.centre) <= radius {
            candidates = []
            let a = 1 - exp(-(t - current.t) / timeConstant)
            let centre = CGPoint(x: current.centre.x + a * (p.x - current.centre.x),
                                 y: current.centre.y + a * (p.y - current.centre.y))
            fixation = (centre, t)
            return centre
        }
        if let last = candidates.last, distance(p, last) > radius { candidates = [] }
        candidates.append(p)
        guard candidates.count >= saccadeFrames else {
            fixation = (current.centre, t)
            return current.centre
        }
        let count = CGFloat(candidates.count)
        let centre = CGPoint(x: candidates.reduce(0) { $0 + $1.x } / count,
                             y: candidates.reduce(0) { $0 + $1.y } / count)
        start(at: centre, t: t)
        return centre
    }

    mutating func reset() {
        fixation = nil
        candidates = []
    }

    private mutating func start(at p: CGPoint, t: TimeInterval) {
        fixation = (p, t)
        candidates = []
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }
}
