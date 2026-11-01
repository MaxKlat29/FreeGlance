import CoreGraphics
import XCTest
@testable import FreeGlance

final class GazeModelTests: XCTestCase {
    private struct LCG {
        var state: UInt64
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private func features(_ rng: inout LCG) -> GazeFeatures {
        GazeFeatures(yaw: rng.next(in: -30...30), pitch: rng.next(in: -15...15), roll: rng.next(in: -5...5),
                     eyeX: rng.next(in: -1...1), eyeY: rng.next(in: -1...1),
                     faceX: rng.next(in: 0.3...0.7), faceY: rng.next(in: 0.3...0.7),
                     faceSize: rng.next(in: 0.15...0.3), timestamp: 0)
    }

    private func fullTruth(_ f: GazeFeatures) -> CGPoint {
        CGPoint(x: 1200 + 40 * f.yaw + 0.8 * f.yaw * f.yaw + 300 * f.eyeX + 500 * (f.faceX - 0.5) + 2 * f.yaw * f.pitch,
                y: 500 + 30 * f.pitch - 0.5 * f.pitch * f.pitch + 200 * f.eyeY + 1000 * (f.faceSize - 0.2))
    }

    func testRecoversFullMapping() throws {
        var rng = LCG(state: 42)
        let samples = (0..<200).map { _ -> CalibrationSample in
            let f = features(&rng)
            return CalibrationSample(features: f, point: fullTruth(f), displayID: 1, weight: 1)
        }
        let model = try XCTUnwrap(GazeModel(samples: samples))
        let errors = (0..<50).map { _ -> Double in
            let f = features(&rng)
            let p = model.predictPoint(f), e = fullTruth(f)
            return hypot(Double(p.x - e.x), Double(p.y - e.y))
        }.sorted()
        // Ridge regularization trades a little bias at the extremes for noise robustness on real data.
        XCTAssertLessThan(errors[errors.count / 2], 50)
        XCTAssertLessThan(errors.last!, 150)
    }

    func testIgnoresAwaySamples() throws {
        var rng = LCG(state: 7)
        let screen = (0..<120).map { _ -> CalibrationSample in
            let f = features(&rng)
            return CalibrationSample(features: f, point: fullTruth(f), displayID: 1, weight: 1)
        }
        let away = (0..<60).map { _ -> CalibrationSample in
            var f = features(&rng)
            f.pitch = -35
            return CalibrationSample(features: f, point: .zero, displayID: CalibrationSample.awayDisplayID, weight: 1)
        }
        let plain = try XCTUnwrap(GazeModel(samples: screen))
        let mixed = try XCTUnwrap(GazeModel(samples: screen + away))
        for _ in 0..<10 {
            let f = features(&rng)
            XCTAssertEqual(mixed.predictPoint(f).x, plain.predictPoint(f).x, accuracy: 1e-6)
            XCTAssertEqual(mixed.predictPoint(f).y, plain.predictPoint(f).y, accuracy: 1e-6)
        }
        XCTAssertNil(GazeModel(samples: Array(away.prefix(20))))
    }

    func testWeightsFavourHeavySamples() throws {
        var rng = LCG(state: 3)
        var samples: [CalibrationSample] = []
        for i in 0..<120 {
            let f = features(&rng)
            let truth = fullTruth(f)
            let isOutlier = i % 2 == 0
            let point = isOutlier ? CGPoint(x: truth.x + 500, y: truth.y) : truth
            samples.append(CalibrationSample(features: f, point: point, displayID: 1, weight: isOutlier ? 0.001 : 1))
        }
        let model = try XCTUnwrap(GazeModel(samples: samples))
        let f = features(&rng)
        XCTAssertEqual(model.predictPoint(f).x, fullTruth(f).x, accuracy: 100, "must follow the heavy samples, not the +500 outliers")
    }

    func testNilWithTooFewSamples() {
        var rng = LCG(state: 1)
        let samples = (0..<5).map { _ in
            CalibrationSample(features: features(&rng), point: .zero, displayID: 1, weight: 1)
        }
        XCTAssertNil(GazeModel(samples: samples))
    }

    func testSurvivesDegenerateConstantFeatures() throws {
        let f = GazeFeatures(yaw: 0, pitch: 0, roll: 0, eyeX: 0, eyeY: 0, faceX: 0.5, faceY: 0.5,
                             faceSize: 0.2, timestamp: 0)
        let samples = (0..<6).map { i in
            CalibrationSample(features: f, point: CGPoint(x: Double(i) * 100, y: 50), displayID: 1, weight: 1)
        }
        let model = try XCTUnwrap(GazeModel(samples: samples))
        let p = model.predictPoint(f)
        XCTAssertEqual(p.x, 250, accuracy: 1e-6)
        XCTAssertEqual(p.y, 50, accuracy: 1e-6)
    }

    func testFullClickBufferShiftsRefitTowardsClickOffset() throws {
        var rng = LCG(state: 11)
        let pursuit = (0..<2000).map { _ -> CalibrationSample in
            let f = features(&rng)
            return CalibrationSample(features: f, point: fullTruth(f), displayID: 1, weight: 1)
        }
        let calibration = Calibration(samples: pursuit, displays: [])
        let weight = calibration.clickWeight(bufferSize: 300, share: 0.2)
        let offset = 100.0
        let clicks = (0..<300).map { _ -> CalibrationSample in
            let f = features(&rng)
            let truth = fullTruth(f)
            return CalibrationSample(features: f, point: CGPoint(x: truth.x + offset, y: truth.y), displayID: 1, weight: weight)
        }
        let before = try XCTUnwrap(GazeModel(samples: pursuit))
        let after = try XCTUnwrap(GazeModel(samples: pursuit + clicks))
        let shifts = (0..<50).map { _ -> Double in
            let f = features(&rng)
            return Double(after.predictPoint(f).x - before.predictPoint(f).x)
        }
        let mean = shifts.reduce(0, +) / Double(shifts.count)
        XCTAssertEqual(mean, 0.2 * offset, accuracy: 0.05 * offset)
    }
}
