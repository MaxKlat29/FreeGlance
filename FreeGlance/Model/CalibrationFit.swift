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

/// Picks eye latency and ridge strengths for the calibration by cross-validation.
///
/// The eyes trail a moving target, so frame features at `t` are paired with the ball at `t - lag`.
/// Every (lag, lambda) pair of the global model is scored by 5-fold cross-validation over contiguous
/// one-second blocks (neighbouring frames are nearly identical, so random frame folds would leak); the
/// pair with the lowest median euclidean error wins. At that lag, each display's refinement model picks
/// its lambda by the same folds restricted to the display. The reported errors come from these
/// two-stage held-out predictions.
struct CalibrationFit: Sendable {
    static let lags: [TimeInterval] = [0, 0.04, 0.08, 0.12, 0.16, 0.2]
    static let lambdas = [0.003, 0.01, 0.03, 0.1, 0.3]
    static let displayLambdas = [0.003, 0.01, 0.03]
    static let folds = 5
    static let blockDuration: TimeInterval = 1
    static let noiseRadiusRange = 40.0...160.0
    /// Centred window over which `fixationError` averages predictions, roughly what the fixation filter smooths.
    static let fixationWindow: TimeInterval = 0.5

    let lag: TimeInterval
    let lambda: Double
    /// Ridge strength of each display's refinement model; displays too small for one are missing.
    let displayLambdas: [CGDirectDisplayID: Double]
    /// Median cross-validated error in points of predictions averaged over `fixationWindow`: what a
    /// fixating user sees.
    let fixationError: Double
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
        // predictions[lag][lambda]: held-out prediction per frame, nil once a fold cannot be solved.
        let unset = [CGPoint](repeating: .zero, count: frames.count)
        var predictions: [[[CGPoint]?]] = Self.lags.map { _ in Self.lambdas.map { _ in unset } }
        for fold in 0..<Self.folds {
            if Task.isCancelled { return nil }
            let train = frames.indices.filter { frames[$0].fold != fold }
            let test = frames.indices.filter { frames[$0].fold == fold }
            guard let problem = RidgeProblem(inputs: train.map { inputs[$0] }, weights: train.map { _ in 1 }, quadratic: true)
            else { return nil }
            for l in Self.lags.indices {
                if Task.isCancelled { return nil }
                let trainTargets = train.map { targets[l][$0] }
                for k in Self.lambdas.indices where predictions[l][k] != nil {
                    guard let model = problem.solve(targets: trainTargets, lambda: Self.lambdas[k]) else {
                        predictions[l][k] = nil
                        continue
                    }
                    for i in test { predictions[l][k]?[i] = model.predict(inputs[i]) }
                }
            }
        }

        var best: (lag: Int, lambda: Int, median: Double)?
        for l in Self.lags.indices {
            for k in Self.lambdas.indices {
                guard let p = predictions[l][k] else { continue }
                let median = Self.percentile(Self.errors(p, targets[l]), 0.5)
                if median < best?.median ?? .infinity { best = (l, k, median) }
            }
        }
        guard let best, let global = predictions[best.lag][best.lambda] else { return nil }
        let target = targets[best.lag]

        // Second stage: per display and fold one problem, solved for every display lambda. A display
        // without enough training frames in a fold keeps the global prediction, as GazeModel would.
        let displayOf = frames.map { traces[$0.trace].displayID }
        var refined = Self.displayLambdas.map { _ in global }
        for fold in 0..<Self.folds {
            for display in Set(displayOf) {
                if Task.isCancelled { return nil }
                let train = frames.indices.filter { frames[$0].fold != fold && displayOf[$0] == display }
                let test = frames.indices.filter { frames[$0].fold == fold && displayOf[$0] == display }
                guard train.count >= GazeModel.minimumDisplaySamples, !test.isEmpty,
                      let problem = RidgeProblem(inputs: train.map { inputs[$0] }, weights: train.map { _ in 1 }, quadratic: true)
                else { continue }
                let trainTargets = train.map { target[$0] }
                for k in Self.displayLambdas.indices {
                    guard let model = problem.solve(targets: trainTargets, lambda: Self.displayLambdas[k]) else { continue }
                    for i in test { refined[k][i] = model.predict(inputs[i]) }
                }
            }
        }
        var twoStage = global
        var displayLambdas: [CGDirectDisplayID: Double] = [:]
        for display in Set(displayOf) {
            let members = frames.indices.filter { displayOf[$0] == display }
            guard members.count >= GazeModel.minimumDisplaySamples else { continue }
            let scored = Self.displayLambdas.indices.map { k in
                (k, Self.percentile(members.map { Self.distance(refined[k][$0], target[$0]) }, 0.5))
            }
            guard let k = scored.min(by: { $0.1 < $1.1 })?.0 else { continue }
            displayLambdas[display] = Self.displayLambdas[k]
            for i in members { twoStage[i] = refined[k][i] }
        }

        lag = Self.lags[best.lag]
        lambda = Self.lambdas[best.lambda]
        self.displayLambdas = displayLambdas
        fixationError = Self.fixationError(predictions: twoStage, targets: target,
                                           times: frames.map(\.features.timestamp), traces: frames.map(\.trace))
        noiseRadius = min(max(Self.percentile(Self.errors(twoStage, target), 0.75), Self.noiseRadiusRange.lowerBound),
                          Self.noiseRadiusRange.upperBound)
        samples = zip(frames.indices, frames).map { i, frame in
            CalibrationSample(features: frame.features, point: target[i], displayID: displayOf[i], weight: 1)
        }
    }

    /// Median distance between each frame's target and the mean prediction over the frames of the same
    /// trace within a centred `fixationWindow`. Frames must be in time order within a trace.
    static func fixationError(predictions: [CGPoint], targets: [CGPoint], times: [TimeInterval], traces: [Int]) -> Double {
        let half = fixationWindow / 2
        let errors = predictions.indices.map { i -> Double in
            var lo = i, hi = i
            while lo > 0, traces[lo - 1] == traces[i], times[i] - times[lo - 1] <= half { lo -= 1 }
            while hi < predictions.count - 1, traces[hi + 1] == traces[i], times[hi + 1] - times[i] <= half { hi += 1 }
            let window = predictions[lo...hi]
            let count = CGFloat(window.count)
            let mean = CGPoint(x: window.reduce(0) { $0 + $1.x } / count, y: window.reduce(0) { $0 + $1.y } / count)
            return distance(mean, targets[i])
        }
        return percentile(errors, 0.5)
    }

    private static func errors(_ predictions: [CGPoint], _ targets: [CGPoint]) -> [Double] {
        zip(predictions, targets).map { distance($0, $1) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }
}
