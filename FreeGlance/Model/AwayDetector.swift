import Foundation

/// Tells "looking at the keyboard" apart from "looking at a screen": two-class linear
/// discriminant on standardized full feature vectors with a shared, ridge-stabilized covariance.
/// Without keyboard samples it never reports away; the geometric rule in ScreenSelector remains.
struct AwayDetector: Sendable {
    static let ridge = 0.3

    private let mean: [Double]
    private let scale: [Double]
    private let discriminant: (weights: [Double], bias: Double)?

    init(samples: [CalibrationSample]) {
        let usable = samples.filter { s in
            s.weight > 0 && s.weight.isFinite && s.features.fullVector.allSatisfy(\.isFinite)
        }
        let inputs = usable.map(\.features.fullVector)
        let weights = usable.map(\.weight)
        let total = weights.reduce(0, +)
        guard let width = inputs.first?.count, total > 0 else {
            mean = []
            scale = []
            discriminant = nil
            return
        }
        let standard = LinearAlgebra.standardization(of: inputs, weights: weights, total: total)
        mean = standard.mean
        scale = standard.scale
        discriminant = Self.fit(rows: inputs.map { Self.apply($0, mean: standard.mean, scale: standard.scale) },
                                away: usable.map(\.isAway), weights: weights, total: total, width: width)
    }

    /// True when the log-odds of "away" versus "screen" are positive. Priors are equal: calibration time
    /// per class says nothing about how often the user looks at the keyboard.
    func isAway(_ f: GazeFeatures) -> Bool {
        guard let discriminant else { return false }
        let z = Self.apply(f.fullVector, mean: mean, scale: scale)
        return zip(discriminant.weights, z).reduce(discriminant.bias) { $0 + $1.0 * $1.1 } > 0
    }

    private static func fit(rows: [[Double]], away: [Bool], weights: [Double], total: Double, width: Int)
        -> (weights: [Double], bias: Double)? {
        var sums = [[Double](repeating: 0, count: width), [Double](repeating: 0, count: width)]
        var classWeight = [0.0, 0.0]
        for (row, (isAway, w)) in zip(rows, zip(away, weights)) {
            let c = isAway ? 1 : 0
            classWeight[c] += w
            for i in 0..<width { sums[c][i] += w * row[i] }
        }
        guard classWeight[0] > 0, classWeight[1] > 0 else { return nil }
        let means = (0..<2).map { c in sums[c].map { $0 / classWeight[c] } }

        var covariance = [Double](repeating: 0, count: width * width)
        for (row, (isAway, w)) in zip(rows, zip(away, weights)) {
            let m = means[isAway ? 1 : 0]
            for i in 0..<width {
                let di = w * (row[i] - m[i])
                for j in i..<width { covariance[i * width + j] += di * (row[j] - m[j]) }
            }
        }
        for i in 0..<width {
            for j in i..<width { covariance[i * width + j] /= total }
            covariance[i * width + i] += ridge
            for j in 0..<i { covariance[i * width + j] = covariance[j * width + i] }
        }
        guard let factor = LinearAlgebra.cholesky(covariance, n: width) else { return nil }
        let difference = (0..<width).map { means[1][$0] - means[0][$0] }
        let direction = LinearAlgebra.solve(factor, n: width, rhs: difference)
        let midpoint = (0..<width).reduce(0.0) { $0 + direction[$1] * (means[1][$1] + means[0][$1]) / 2 }
        return (direction, -midpoint)
    }

    private static func apply(_ v: [Double], mean: [Double], scale: [Double]) -> [Double] {
        v.indices.map { (v[$0] - mean[$0]) / scale[$0] }
    }
}
