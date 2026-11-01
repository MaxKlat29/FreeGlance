import CoreGraphics
import Foundation

/// One smooth-pursuit pass: the ball moves along `path` at constant `speed` from `start` on, and
/// every face frame seen while it moves is kept (after the first `discardDuration`).
struct PursuitTrace: Sendable {
    static let discardDuration: TimeInterval = 0.6

    var displayID: CGDirectDisplayID
    var path: PursuitPath
    /// Points per second.
    var speed: Double
    /// `ProcessInfo.systemUptime` when the ball starts moving, same clock as `GazeFeatures.timestamp`.
    var start: TimeInterval
    var frames: [GazeFeatures] = []

    var duration: TimeInterval { path.length / speed }

    /// Ball position at time `t`; it rests at the path ends before `start` and after the pass.
    func target(at t: TimeInterval) -> CGPoint {
        path.point(atDistance: min(max(t - start, 0), duration) * speed)
    }

    mutating func record(_ features: GazeFeatures) {
        guard features.timestamp >= start + Self.discardDuration, features.timestamp <= start + duration else { return }
        frames.append(features)
    }
}

/// Picks eye latency and ridge strength for the calibration by cross-validation.
///
/// The eyes trail a moving target, so frame features at `t` are paired with the ball at `t - lag`.
/// Every (lag, lambda) pair is scored by 5-fold cross-validation over contiguous one-second blocks
/// (neighbouring frames are nearly identical, so random frame folds would leak); the pair with the
/// lowest median euclidean error wins.
struct CalibrationFit: Sendable {
    static let lags: [TimeInterval] = [0, 0.04, 0.08, 0.12, 0.16, 0.2]
    static let lambdas = [0.003, 0.01, 0.03, 0.1, 0.3]
    static let folds = 5
    static let blockDuration: TimeInterval = 1
    static let noiseRadiusRange = 40.0...160.0

    let lag: TimeInterval
    let lambda: Double
    /// Median cross-validated error in points.
    let medianError: Double
    /// 75th percentile of the cross-validated per-frame error, clamped to `noiseRadiusRange`.
    let noiseRadius: Double
    /// Pursuit frames paired with the ball position at the chosen lag.
    let samples: [CalibrationSample]

    /// Nil when the traces hold too few usable frames for every fold, or when the computing task is cancelled.
    init?(traces: [PursuitTrace]) {
        var frames: [(features: GazeFeatures, trace: Int, fold: Int)] = []
        for (index, trace) in traces.enumerated() {
            for f in trace.frames where f.fullVector.allSatisfy(\.isFinite) {
                let block = Int(max(0, f.timestamp - trace.start) / Self.blockDuration)
                frames.append((f, index, (block + index) % Self.folds))
            }
        }
        let foldSizes = (0..<Self.folds).map { fold in frames.count(where: { $0.fold == fold }) }
        guard foldSizes.allSatisfy({ $0 > 0 }),
              foldSizes.allSatisfy({ frames.count - $0 >= GazeModel.minimumSamples })
        else { return nil }

        let inputs = frames.map(\.features.fullVector)
        let targets = Self.lags.map { lag in
            frames.map { traces[$0.trace].target(at: $0.features.timestamp - lag) }
        }
        // errors[lag][lambda]: held-out error per frame, nil once a fold cannot be solved.
        var errors: [[[Double]?]] = Self.lags.map { _ in Self.lambdas.map { _ in [] } }
        for fold in 0..<Self.folds {
            if Task.isCancelled { return nil }
            let train = frames.indices.filter { frames[$0].fold != fold }
            let test = frames.indices.filter { frames[$0].fold == fold }
            guard let problem = RidgeProblem(inputs: train.map { inputs[$0] }, weights: train.map { _ in 1 }, quadratic: true)
            else { return nil }
            for l in Self.lags.indices {
                if Task.isCancelled { return nil }
                let trainTargets = train.map { targets[l][$0] }
                for k in Self.lambdas.indices where errors[l][k] != nil {
                    guard let model = problem.solve(targets: trainTargets, lambda: Self.lambdas[k]) else {
                        errors[l][k] = nil
                        continue
                    }
                    errors[l][k]! += test.map { i in
                        let p = model.predict(inputs[i]), t = targets[l][i]
                        return hypot(Double(p.x - t.x), Double(p.y - t.y))
                    }
                }
            }
        }

        var best: (lag: Int, lambda: Int, errors: [Double], median: Double)?
        for l in Self.lags.indices {
            for k in Self.lambdas.indices {
                guard let e = errors[l][k] else { continue }
                let median = Self.percentile(e, 0.5)
                if median < best?.median ?? .infinity { best = (l, k, e, median) }
            }
        }
        guard let best else { return nil }
        lag = Self.lags[best.lag]
        lambda = Self.lambdas[best.lambda]
        medianError = best.median
        noiseRadius = min(max(Self.percentile(best.errors, 0.75), Self.noiseRadiusRange.lowerBound),
                          Self.noiseRadiusRange.upperBound)
        samples = zip(frames, targets[best.lag]).map { frame, point in
            CalibrationSample(features: frame.features, point: point, displayID: traces[frame.trace].displayID, weight: 1)
        }
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }
}
