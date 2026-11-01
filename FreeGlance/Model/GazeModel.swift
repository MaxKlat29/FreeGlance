import CoreGraphics
import Foundation

/// Two stages: a global model over all screen samples (screen selection, away logic, fallback) and,
/// per display with at least `minimumDisplaySamples` samples, a refinement model trained only on that
/// display's samples, applied once the facing display is known.
struct GazeModel: Sendable {
    static let minimumSamples = 6
    static let minimumDisplaySamples = 60
    /// Ridge strength for calibrations from before `CalibrationFit` chose it by cross-validation.
    static let regularization = 0.03
    /// Display model ridge strength for calibrations from before it was cross-validated per display.
    static let displayRegularization = 0.01

    private let full: RidgeRegression
    private let displays: [CGDirectDisplayID: RidgeRegression]

    init?(samples: [CalibrationSample], lambda: Double = GazeModel.regularization,
          displayLambdas: [CGDirectDisplayID: Double] = [:]) {
        let usable = samples.filter { s in
            !s.isAway && s.weight > 0 && s.weight.isFinite && s.point.x.isFinite && s.point.y.isFinite
                && s.features.fullVector.allSatisfy(\.isFinite)
        }
        guard usable.count >= Self.minimumSamples, let full = Self.fit(usable, lambda: lambda) else { return nil }
        self.full = full
        displays = Dictionary(grouping: usable, by: \.displayID).compactMapValues { group in
            guard group.count >= Self.minimumDisplaySamples else { return nil }
            return Self.fit(group, lambda: displayLambdas[group[0].displayID] ?? Self.displayRegularization)
        }
    }

    /// Global point, used for screen selection and the away logic.
    func predictPoint(_ f: GazeFeatures) -> CGPoint {
        full.predict(f.fullVector)
    }

    /// Point from `display`'s own model, the global point when that display has none.
    func refinedPoint(_ f: GazeFeatures, on display: CGDirectDisplayID) -> CGPoint {
        (displays[display] ?? full).predict(f.fullVector)
    }

    private static func fit(_ samples: [CalibrationSample], lambda: Double) -> RidgeRegression? {
        RidgeRegression(inputs: samples.map(\.features.fullVector), targets: samples.map(\.point),
                        weights: samples.map(\.weight), lambda: lambda, quadratic: true)
    }
}

/// Standardized (optionally quadratic) design and its weighted Gram matrix, built once and then
/// solved for any targets and ridge strength. Cross-validation reuses one per fold for every
/// latency and lambda candidate.
struct RidgeProblem: Sendable {
    private let inputMean: [Double]
    private let inputScale: [Double]
    private let featureMean: [Double]
    private let featureScale: [Double]
    private let design: [[Double]]
    private let weights: [Double]
    private let totalWeight: Double
    private let gram: [Double]
    private let quadratic: Bool

    init?(inputs: [[Double]], weights: [Double], quadratic: Bool) {
        guard let width = inputs.first?.count, width > 0, inputs.count == weights.count,
              inputs.allSatisfy({ $0.count == width })
        else { return nil }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        let input = LinearAlgebra.standardization(of: inputs, weights: weights, total: totalWeight)
        let expanded = inputs.map { Self.expand(Self.apply($0, mean: input.mean, scale: input.scale), quadratic: quadratic) }
        let feature = LinearAlgebra.standardization(of: expanded, weights: weights, total: totalWeight)
        let design = expanded.map { Self.apply($0, mean: feature.mean, scale: feature.scale) }

        let n = design[0].count
        var gram = [Double](repeating: 0, count: n * n)
        for (row, w) in zip(design, weights) {
            for i in 0..<n {
                let wi = w * row[i]
                for j in i..<n {
                    gram[i * n + j] += wi * row[j]
                }
            }
        }
        for i in 0..<n {
            for j in 0..<i {
                gram[i * n + j] = gram[j * n + i]
            }
        }
        self.inputMean = input.mean
        self.inputScale = input.scale
        self.featureMean = feature.mean
        self.featureScale = feature.scale
        self.design = design
        self.weights = weights
        self.totalWeight = totalWeight
        self.gram = gram
        self.quadratic = quadratic
    }

    /// `targets` in the order of the inputs; nil when the system is singular.
    func solve(targets: [CGPoint], lambda: Double) -> RidgeRegression? {
        guard targets.count == design.count else { return nil }
        let meanX = zip(targets, weights).reduce(0) { $0 + Double($1.0.x) * $1.1 } / totalWeight
        let meanY = zip(targets, weights).reduce(0) { $0 + Double($1.0.y) * $1.1 } / totalWeight

        let n = design[0].count
        var rhsX = [Double](repeating: 0, count: n)
        var rhsY = [Double](repeating: 0, count: n)
        for (row, (target, w)) in zip(design, zip(targets, weights)) {
            let dx = w * (Double(target.x) - meanX)
            let dy = w * (Double(target.y) - meanY)
            for i in 0..<n {
                rhsX[i] += row[i] * dx
                rhsY[i] += row[i] * dy
            }
        }
        var regularized = gram
        let ridge = lambda * totalWeight
        for i in 0..<n { regularized[i * n + i] += ridge }
        guard let factor = LinearAlgebra.cholesky(regularized, n: n) else { return nil }
        return RidgeRegression(inputMean: inputMean, inputScale: inputScale, featureMean: featureMean,
                               featureScale: featureScale,
                               coefficientsX: LinearAlgebra.solve(factor, n: n, rhs: rhsX),
                               coefficientsY: LinearAlgebra.solve(factor, n: n, rhs: rhsY),
                               interceptX: meanX, interceptY: meanY, quadratic: quadratic)
    }

    fileprivate static func expand(_ z: [Double], quadratic: Bool) -> [Double] {
        guard quadratic else { return z }
        var out = z
        out.reserveCapacity(z.count + z.count * (z.count + 1) / 2)
        for i in z.indices {
            for j in i..<z.count {
                out.append(z[i] * z[j])
            }
        }
        return out
    }

    fileprivate static func apply(_ v: [Double], mean: [Double], scale: [Double]) -> [Double] {
        v.indices.map { (v[$0] - mean[$0]) / scale[$0] }
    }
}

struct RidgeRegression: Sendable {
    fileprivate let inputMean: [Double]
    fileprivate let inputScale: [Double]
    fileprivate let featureMean: [Double]
    fileprivate let featureScale: [Double]
    fileprivate let coefficientsX: [Double]
    fileprivate let coefficientsY: [Double]
    fileprivate let interceptX: Double
    fileprivate let interceptY: Double
    fileprivate let quadratic: Bool

    init?(inputs: [[Double]], targets: [CGPoint], weights: [Double], lambda: Double, quadratic: Bool) {
        guard inputs.count == targets.count,
              let fit = RidgeProblem(inputs: inputs, weights: weights, quadratic: quadratic)?.solve(targets: targets, lambda: lambda)
        else { return nil }
        self = fit
    }

    fileprivate init(inputMean: [Double], inputScale: [Double], featureMean: [Double], featureScale: [Double],
                     coefficientsX: [Double], coefficientsY: [Double], interceptX: Double, interceptY: Double,
                     quadratic: Bool) {
        self.inputMean = inputMean
        self.inputScale = inputScale
        self.featureMean = featureMean
        self.featureScale = featureScale
        self.coefficientsX = coefficientsX
        self.coefficientsY = coefficientsY
        self.interceptX = interceptX
        self.interceptY = interceptY
        self.quadratic = quadratic
    }

    func predict(_ input: [Double]) -> CGPoint {
        let row = RidgeProblem.apply(RidgeProblem.expand(RidgeProblem.apply(input, mean: inputMean, scale: inputScale),
                                                         quadratic: quadratic),
                                     mean: featureMean, scale: featureScale)
        var x = interceptX
        var y = interceptY
        for i in row.indices {
            x += coefficientsX[i] * row[i]
            y += coefficientsY[i] * row[i]
        }
        return CGPoint(x: x, y: y)
    }
}

/// Weighted standardization and a Cholesky solver shared by the in-house fits.
enum LinearAlgebra {
    static func standardization(of rows: [[Double]], weights: [Double], total: Double)
        -> (mean: [Double], scale: [Double]) {
        let width = rows[0].count
        var mean = [Double](repeating: 0, count: width)
        for (row, w) in zip(rows, weights) {
            for i in 0..<width { mean[i] += w * row[i] }
        }
        mean = mean.map { $0 / total }
        var variance = [Double](repeating: 0, count: width)
        for (row, w) in zip(rows, weights) {
            for i in 0..<width {
                let d = row[i] - mean[i]
                variance[i] += w * d * d
            }
        }
        let scale = variance.map { v -> Double in
            let s = (v / total).squareRoot()
            return s > 1e-9 ? s : 1
        }
        return (mean, scale)
    }

    static func cholesky(_ a: [Double], n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard sum > 0 else { return nil }
                    l[i * n + i] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        return l
    }

    static func solve(_ l: [Double], n: Int, rhs: [Double]) -> [Double] {
        var y = rhs
        for i in 0..<n {
            for k in 0..<i { y[i] -= l[i * n + k] * y[k] }
            y[i] /= l[i * n + i]
        }
        var x = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<n { x[i] -= l[k * n + i] * x[k] }
            x[i] /= l[i * n + i]
        }
        return x
    }
}
