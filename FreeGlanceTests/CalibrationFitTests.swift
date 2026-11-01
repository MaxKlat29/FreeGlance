import CoreGraphics
import XCTest
@testable import FreeGlance

final class CalibrationFitTests: XCTestCase {
    private struct LCG {
        var state: UInt64
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let speed = 300.0

    /// Ground truth: x = 500 + 40 yaw + 1000 eyeX, y = 300 + 30 pitch + 800 eyeY. The eyes look at
    /// where the ball was `lag` seconds ago; head and eyes share the turn in the first pass, the head
    /// stays still in the second.
    private func traces(lag: TimeInterval, noise: Double, seed: UInt64, fps: Double = 30) -> [PursuitTrace] {
        var rng = LCG(state: seed)
        var start = 10.0
        return CalibrationController.Pass.allCases.map { pass in
            var trace = PursuitTrace(displayID: 1, path: .serpentine(in: frame, rows: pass.rows), speed: speed, start: start)
            let headShare = pass == .headAndEyes ? 0.6 : 0
            for t in stride(from: start, through: start + trace.duration, by: 1 / fps) {
                let p = trace.target(at: t - lag)
                let dx = Double(p.x) - 500, dy = Double(p.y) - 300
                let f = GazeFeatures(yaw: headShare * dx / 40 + noise * rng.next(in: -0.1...0.1),
                                     pitch: headShare * dy / 30 + noise * rng.next(in: -0.1...0.1),
                                     roll: rng.next(in: -1...1),
                                     eyeX: (1 - headShare) * dx / 1000 + noise * rng.next(in: -0.003...0.003),
                                     eyeY: (1 - headShare) * dy / 800 + noise * rng.next(in: -0.003...0.003),
                                     faceX: 0.5 + rng.next(in: -0.002...0.002), faceY: 0.5 + rng.next(in: -0.002...0.002),
                                     faceSize: 0.2 + rng.next(in: -0.001...0.001), timestamp: t)
                trace.record(f)
            }
            start += trace.duration + 5
            return trace
        }
    }

    func testRecoversEyeLatency() throws {
        let fit = try XCTUnwrap(CalibrationFit(traces: traces(lag: 0.12, noise: 1, seed: 11)))
        XCTAssertEqual(fit.lag, 0.12, accuracy: 1e-9)
        XCTAssertLessThan(fit.fixationError, 12)
        XCTAssertEqual(Set(fit.displayLambdas.keys), [1])
        XCTAssertTrue(CalibrationFit.displayLambdas.contains(try XCTUnwrap(fit.displayLambdas[1])))
        XCTAssertEqual(fit.noiseRadius, CalibrationFit.noiseRadiusRange.lowerBound)
        XCTAssertEqual(fit.samples.count, traces(lag: 0.12, noise: 1, seed: 11).map(\.frames.count).reduce(0, +))
    }

    /// Dense clean data needs hardly any ridge; sparse noisy data overfits the 35 quadratic terms without it.
    func testPicksLightRidgeForCleanDataAndStrongerForSparseNoisyData() throws {
        let clean = try XCTUnwrap(CalibrationFit(traces: traces(lag: 0.08, noise: 0.5, seed: 5)))
        let noisy = try XCTUnwrap(CalibrationFit(traces: traces(lag: 0.08, noise: 30, seed: 5, fps: 3)))
        XCTAssertLessThanOrEqual(clean.lambda, 0.01)
        XCTAssertGreaterThan(noisy.lambda, clean.lambda)
        XCTAssertGreaterThan(noisy.noiseRadius, clean.noiseRadius)
    }

    /// Window ±0.25 s within a trace. One trace: means 3, 3, 4.5, 7.5, 12 -> median 4.5.
    /// Split after the third frame: means 3, 3, 3, 9, 12 -> median 3.
    func testFixationErrorAveragesCentredWindowWithinTrace() {
        let predictions = [0.0, 3, 6, 9, 12].map { CGPoint(x: $0, y: 0) }
        let targets = [CGPoint](repeating: .zero, count: 5)
        let times: [TimeInterval] = [0, 0.125, 0.25, 0.5, 1]
        XCTAssertEqual(CalibrationFit.fixationError(predictions: predictions, targets: targets, times: times,
                                                    traces: [0, 0, 0, 0, 0]), 4.5, accuracy: 1e-12)
        XCTAssertEqual(CalibrationFit.fixationError(predictions: predictions, targets: targets, times: times,
                                                    traces: [0, 0, 0, 1, 1]), 3, accuracy: 1e-12)
    }

    func testNilWithoutFrames() {
        let empty = PursuitTrace(displayID: 1, path: .serpentine(in: frame, rows: 3), speed: speed, start: 0)
        XCTAssertNil(CalibrationFit(traces: [empty]))
    }
}
