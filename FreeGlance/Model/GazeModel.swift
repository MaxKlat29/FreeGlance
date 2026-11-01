import CoreGraphics
import Foundation

struct GazeModel: Sendable {
    static let minimumSamples = 6
    static let regularization = 1e-3

    private let full: RidgeRegression
    private let head: RidgeRegression

    init?(samples: [CalibrationSample]) {
        let usable = samples.filter { s in
            s.weight > 0 && s.weight.isFinite && s.point.x.isFinite && s.point.y.isFinite
                && s.features.fullVector.allSatisfy(\.isFinite)
        }
        guard usable.count >= Self.minimumSamples else { return nil }
        let targets = usable.map(\.point)
        let weights = usable.map(\.weight)
        guard
            let full = RidgeRegression(inputs: usable.map(\.features.fullVector), targets: targets,
                                       weights: weights, lambda: Self.regularization),
            let head = RidgeRegression(inputs: usable.map(\.features.headVector), targets: targets,
                                       weights: weights, lambda: Self.regularization)
        else { return nil }
        self.full = full
        self.head = head
    }

    func predictPoint(_ f: GazeFeatures) -> CGPoint {
        full.predict(f.fullVector)
    }

    func headPoint(_ f: GazeFeatures) -> CGPoint {
        head.predict(f.headVector)
    }
}

struct RidgeRegression: Sendable {
    private let inputMean: [Double]
    private let inputScale: [Double]
    private let featureMean: [Double]
    private let featureScale: [Double]
    private let coefficientsX: [Double]
    private let coefficientsY: [Double]
    private let interceptX: Double
    private let interceptY: Double

    init?(inputs: [[Double]], targets: [CGPoint], weights: [Double], lambda: Double) {
        guard let width = inputs.first?.count, width > 0,
              inputs.count == targets.count, inputs.count == weights.count,
              inputs.allSatisfy({ $0.count == width })
        else { return nil }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        let input = Self.standardization(of: inputs, weights: weights, total: totalWeight)
        let expanded = inputs.map { Self.expand(Self.apply($0, mean: input.mean, scale: input.scale)) }
        let feature = Self.standardization(of: expanded, weights: weights, total: totalWeight)
        let design = expanded.map { Self.apply($0, mean: feature.mean, scale: feature.scale) }

        let meanX = zip(targets, weights).reduce(0) { $0 + Double($1.0.x) * $1.1 } / totalWeight
        let meanY = zip(targets, weights).reduce(0) { $0 + Double($1.0.y) * $1.1 } / totalWeight

        let n = design[0].count
        var gram = [Double](repeating: 0, count: n * n)
        var rhsX = [Double](repeating: 0, count: n)
        var rhsY = [Double](repeating: 0, count: n)
        for (row, (target, w)) in zip(design, zip(targets, weights)) {
            let dx = Double(target.x) - meanX
            let dy = Double(target.y) - meanY
            for i in 0..<n {
                let wi = w * row[i]
                rhsX[i] += wi * dx
                rhsY[i] += wi * dy
                for j in i..<n {
                    gram[i * n + j] += wi * row[j]
                }
            }
        }
        let ridge = lambda * totalWeight
        for i in 0..<n {
            gram[i * n + i] += ridge
            for j in 0..<i {
                gram[i * n + j] = gram[j * n + i]
            }
        }
        guard let factor = Self.cholesky(gram, n: n) else { return nil }
        coefficientsX = Self.solve(factor, n: n, rhs: rhsX)
        coefficientsY = Self.solve(factor, n: n, rhs: rhsY)
        interceptX = meanX
        interceptY = meanY
        inputMean = input.mean
        inputScale = input.scale
        featureMean = feature.mean
        featureScale = feature.scale
    }

    func predict(_ input: [Double]) -> CGPoint {
        let row = Self.apply(Self.expand(Self.apply(input, mean: inputMean, scale: inputScale)),
                             mean: featureMean, scale: featureScale)
        var x = interceptX
        var y = interceptY
        for i in row.indices {
            x += coefficientsX[i] * row[i]
            y += coefficientsY[i] * row[i]
        }
        return CGPoint(x: x, y: y)
    }

    private static func expand(_ z: [Double]) -> [Double] {
        var out = z
        out.reserveCapacity(z.count + z.count * (z.count + 1) / 2)
        for i in z.indices {
            for j in i..<z.count {
                out.append(z[i] * z[j])
            }
        }
        return out
    }

    private static func apply(_ v: [Double], mean: [Double], scale: [Double]) -> [Double] {
        v.indices.map { (v[$0] - mean[$0]) / scale[$0] }
    }

    private static func standardization(of rows: [[Double]], weights: [Double], total: Double)
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

    private static func cholesky(_ a: [Double], n: Int) -> [Double]? {
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

    private static func solve(_ l: [Double], n: Int, rhs: [Double]) -> [Double] {
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
