import CoreGraphics
import Foundation

/// Local correction on top of one display's refinement model. Each refine point is an anchor: the
/// median prediction q of its frames and the residual r = target - q left by the regression, which
/// cannot tell the few refine frames from the many calibration frames. A prediction p moves by
/// sum w_i r_i / (sum w_i + shrinkage) with Gaussian weights w_i of |p - q_i|, so at an anchor most of
/// its residual is corrected and the correction fades to zero away from all anchors.
struct ResidualCorrection: Sendable {
    /// Gaussian radius of an anchor, in points.
    static let sigma = 260.0
    /// Added to the weight sum: a lone anchor corrects 1 / (1 + shrinkage) of its residual, about 87 %.
    static let shrinkage = 0.15

    struct Anchor: Sendable, Equatable {
        var prediction: CGPoint
        var residual: CGVector
    }

    let anchors: [Anchor]

    /// Nil without anchors.
    init?(anchors: [Anchor]) {
        guard !anchors.isEmpty else { return nil }
        self.anchors = anchors
    }

    /// One anchor per refine point from the uncorrected predictions of its frames; points without
    /// frames are skipped.
    init?(points: [(target: CGPoint, predictions: [CGPoint])]) {
        self.init(anchors: points.compactMap { target, predictions in
            guard !predictions.isEmpty else { return nil }
            let q = Self.median(predictions)
            return Anchor(prediction: q, residual: CGVector(dx: target.x - q.x, dy: target.y - q.y))
        })
    }

    func offset(at p: CGPoint) -> CGVector {
        var weightSum = 0.0, dx = 0.0, dy = 0.0
        for anchor in anchors {
            let distanceX = Double(p.x - anchor.prediction.x), distanceY = Double(p.y - anchor.prediction.y)
            let w = exp(-(distanceX * distanceX + distanceY * distanceY) / (2 * Self.sigma * Self.sigma))
            weightSum += w
            dx += w * Double(anchor.residual.dx)
            dy += w * Double(anchor.residual.dy)
        }
        let norm = weightSum + Self.shrinkage
        return CGVector(dx: dx / norm, dy: dy / norm)
    }

    func corrected(_ p: CGPoint) -> CGPoint {
        let d = offset(at: p)
        return CGPoint(x: p.x + d.dx, y: p.y + d.dy)
    }

    /// Component-wise median (upper middle for an even count).
    static func median(_ points: [CGPoint]) -> CGPoint {
        let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
        return CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
    }
}
