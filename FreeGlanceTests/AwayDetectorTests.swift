import CoreGraphics
import XCTest
@testable import FreeGlance

final class AwayDetectorTests: XCTestCase {
    private struct LCG {
        var state: UInt64
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    /// Screen poses spread over a wide range; keyboard pose = head and eyes down, face lower in frame.
    private func screenFeatures(_ rng: inout LCG) -> GazeFeatures {
        GazeFeatures(yaw: rng.next(in: -30...30), pitch: rng.next(in: -8...15), roll: rng.next(in: -3...3),
                     eyeX: rng.next(in: -0.8...0.8), eyeY: rng.next(in: -0.3...0.6),
                     faceX: rng.next(in: 0.35...0.65), faceY: rng.next(in: 0.45...0.6),
                     faceSize: rng.next(in: 0.18...0.24), timestamp: 0)
    }

    private func keyboardFeatures(_ rng: inout LCG) -> GazeFeatures {
        GazeFeatures(yaw: rng.next(in: -5...5), pitch: rng.next(in: -30 ... -20), roll: rng.next(in: -3...3),
                     eyeX: rng.next(in: -0.2...0.2), eyeY: rng.next(in: -0.9 ... -0.6),
                     faceX: rng.next(in: 0.45...0.55), faceY: rng.next(in: 0.35...0.42),
                     faceSize: rng.next(in: 0.18...0.24), timestamp: 0)
    }

    private func samples(screen: Int, away: Int, rng: inout LCG) -> [CalibrationSample] {
        let s = (0..<screen).map { i in
            CalibrationSample(features: screenFeatures(&rng), point: CGPoint(x: i, y: 0),
                              displayID: i.isMultiple(of: 2) ? 1 : 2, weight: i.isMultiple(of: 3) ? 0.3 : 1)
        }
        let a = (0..<away).map { _ in
            CalibrationSample(features: keyboardFeatures(&rng), point: .zero,
                              displayID: CalibrationSample.awayDisplayID, weight: 1)
        }
        return s + a
    }

    func testSeparatesKeyboardFromScreens() {
        var rng = LCG(state: 11)
        let detector = AwayDetector(samples: samples(screen: 600, away: 75, rng: &rng))
        let screenHits = (0..<200).filter { _ in detector.isAway(screenFeatures(&rng)) }.count
        let awayHits = (0..<200).filter { _ in detector.isAway(keyboardFeatures(&rng)) }.count
        XCTAssertLessThanOrEqual(screenHits, 2)
        XCTAssertGreaterThanOrEqual(awayHits, 198)
    }

    func testNeverAwayWithoutKeyboardSamples() {
        var rng = LCG(state: 5)
        let detector = AwayDetector(samples: samples(screen: 300, away: 0, rng: &rng))
        for _ in 0..<100 {
            XCTAssertFalse(detector.isAway(keyboardFeatures(&rng)))
            XCTAssertFalse(detector.isAway(screenFeatures(&rng)))
        }
        XCTAssertFalse(AwayDetector(samples: []).isAway(keyboardFeatures(&rng)))
    }
}
