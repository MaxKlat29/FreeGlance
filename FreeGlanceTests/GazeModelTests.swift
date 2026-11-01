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

    private func headTruth(_ f: GazeFeatures) -> CGPoint {
        CGPoint(x: 1200 + 40 * f.yaw + 0.8 * f.yaw * f.yaw + 500 * (f.faceX - 0.5),
                y: 500 + 30 * f.pitch - 0.5 * f.pitch * f.pitch + 800 * (f.faceY - 0.5))
    }

    func testRecoversFullMapping() throws {
        var rng = LCG(state: 42)
        let samples = (0..<200).map { _ -> CalibrationSample in
            let f = features(&rng)
            return CalibrationSample(features: f, point: fullTruth(f), displayID: 1, weight: 1)
        }
        let model = try XCTUnwrap(GazeModel(samples: samples))
        for _ in 0..<50 {
            let f = features(&rng)
            let predicted = model.predictPoint(f)
            let expected = fullTruth(f)
            XCTAssertEqual(predicted.x, expected.x, accuracy: 10)
            XCTAssertEqual(predicted.y, expected.y, accuracy: 10)
        }
    }

    func testHeadModelIgnoresEyes() throws {
        var rng = LCG(state: 7)
        let samples = (0..<200).map { _ -> CalibrationSample in
            let f = features(&rng)
            return CalibrationSample(features: f, point: headTruth(f), displayID: 1, weight: 1)
        }
        let model = try XCTUnwrap(GazeModel(samples: samples))
        var f = features(&rng)
        let expected = headTruth(f)
        f.eyeX = -f.eyeX
        f.eyeY = -f.eyeY
        let predicted = model.headPoint(f)
        XCTAssertEqual(predicted.x, expected.x, accuracy: 10)
        XCTAssertEqual(predicted.y, expected.y, accuracy: 10)
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
        XCTAssertEqual(model.predictPoint(f).x, fullTruth(f).x, accuracy: 30)
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
}
