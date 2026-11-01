import CoreGraphics
import XCTest
@testable import FreeGlance

final class ResidualCorrectionTests: XCTestCase {
    private let sigma = ResidualCorrection.sigma

    func testShrinkageOnASinglePointIsExact() throws {
        let correction = try XCTUnwrap(ResidualCorrection(points: [(CGPoint(x: 600, y: 400),
                                                                     [CGPoint(x: 400, y: 380), CGPoint(x: 420, y: 400), CGPoint(x: 380, y: 390)])]))
        XCTAssertEqual(correction.anchors, [.init(prediction: CGPoint(x: 400, y: 390), residual: CGVector(dx: 200, dy: 10))])
        let atAnchor = correction.offset(at: CGPoint(x: 400, y: 390))
        XCTAssertEqual(Double(atAnchor.dx), 200 / 1.15, accuracy: 1e-9)
        XCTAssertEqual(Double(atAnchor.dy), 10 / 1.15, accuracy: 1e-9)

        let w = exp(-1.0 / 2)
        let oneSigma = correction.offset(at: CGPoint(x: 400 + sigma, y: 390))
        XCTAssertEqual(Double(oneSigma.dx), w * 200 / (w + 0.15), accuracy: 1e-9)
        XCTAssertEqual(correction.corrected(CGPoint(x: 400, y: 390)).x, 400 + 200 / 1.15, accuracy: 1e-9)
    }

    func testCorrectionFadesFarFromRefinePoints() throws {
        let correction = try XCTUnwrap(ResidualCorrection(anchors: [
            .init(prediction: CGPoint(x: 500, y: 500), residual: CGVector(dx: 200, dy: -100)),
        ]))
        let far = correction.offset(at: CGPoint(x: 500 + 3 * sigma, y: 500))
        XCTAssertLessThan(hypot(far.dx, far.dy), 0.1 * hypot(200, 100))
        XCTAssertGreaterThan(hypot(far.dx, far.dy), 0)
    }

    func testNoCorrectionWithoutRefinePoints() {
        XCTAssertNil(ResidualCorrection(anchors: []))
        XCTAssertNil(ResidualCorrection(points: [(CGPoint(x: 1, y: 1), [])]))
    }

    /// Refine points on display 2 leave display 1's refined prediction untouched: its own model sees none
    /// of them and it gets no correction.
    func testRefinePointsOnlyCorrectTheirDisplay() throws {
        func features(_ i: Int) -> GazeFeatures {
            GazeFeatures(yaw: Double(i % 17) - 8, pitch: Double(i % 11) - 5, roll: 0, eyeX: Double(i % 7) * 0.01,
                         eyeY: Double(i % 5) * 0.01, faceX: 0.5, faceY: 0.5, faceSize: 0.2, timestamp: 0)
        }
        func samples(display: CGDirectDisplayID, range: Range<Int>) -> [CalibrationSample] {
            range.map { i in
                let f = features(i)
                return CalibrationSample(features: f, point: CGPoint(x: 700 + 40 * f.yaw, y: 400 + 30 * f.pitch),
                                         displayID: display, weight: 1)
            }
        }
        let calibration = samples(display: 1, range: 0..<200) + samples(display: 2, range: 200..<400)
        let refine = (0..<10).map { CalibrationSample(features: features($0), point: CGPoint(x: 900, y: 500), displayID: 2, weight: 5) }
        let plain = try XCTUnwrap(GazeModel(samples: calibration))
        let refined = try XCTUnwrap(GazeModel(samples: calibration, refineSamples: refine))
        for i in 0..<20 {
            let a = plain.refinedPoint(features(i), on: 1), b = refined.refinedPoint(features(i), on: 1)
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
        XCTAssertNotEqual(plain.refinedPoint(features(3), on: 2), refined.refinedPoint(features(3), on: 2))
    }
}
