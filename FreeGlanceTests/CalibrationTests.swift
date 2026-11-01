import CoreGraphics
import XCTest
@testable import FreeGlance

final class CalibrationTests: XCTestCase {
    private let a = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600), name: "A")
    private let b = DisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 600), name: "B")

    func testLayoutHashIgnoresOrderAndNames() {
        var renamed = b
        renamed.name = "Other"
        XCTAssertEqual(Calibration.currentLayoutHash(displays: [a, b]),
                       Calibration.currentLayoutHash(displays: [renamed, a]))
    }

    func testLayoutHashChangesWithFrame() {
        var moved = b
        moved.frame.origin.y = 100
        XCTAssertNotEqual(Calibration.currentLayoutHash(displays: [a, b]),
                          Calibration.currentLayoutHash(displays: [a, moved]))
    }

    func testRoundTripThroughDefaults() throws {
        let suite = "FreeGlanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let f = GazeFeatures(yaw: 1, pitch: 2, roll: 3, eyeX: 0.1, eyeY: -0.2, faceX: 0.5, faceY: 0.4,
                             faceSize: 0.2, timestamp: 10)
        let calibration = Calibration(samples: [CalibrationSample(features: f, point: CGPoint(x: 5, y: 6),
                                                                  displayID: 2, weight: 0.3)],
                                      displays: [a, b])
        XCTAssertNil(Calibration.load(from: defaults))
        calibration.save(to: defaults)
        let loaded = try XCTUnwrap(Calibration.load(from: defaults))
        XCTAssertEqual(loaded.samples.first?.features, f)
        XCTAssertEqual(loaded.samples.first?.point, CGPoint(x: 5, y: 6))
        XCTAssertEqual(loaded.displayLayoutHash, calibration.displayLayoutHash)
        XCTAssertTrue(loaded.matches(displays: [b, a]))
    }

    func testRoundTripKeepsFitResults() throws {
        let f = GazeFeatures(yaw: 1, pitch: 2, roll: 3, eyeX: 0.1, eyeY: -0.2, faceX: 0.5, faceY: 0.4,
                             faceSize: 0.2, timestamp: 10)
        let calibration = Calibration(samples: [CalibrationSample(features: f, point: CGPoint(x: 5, y: 6), displayID: 1, weight: 1)],
                                      displays: [a], lambda: 0.1, displayLambdas: [1: 0.003, 2: 0.03],
                                      noiseRadius: 55, typicalErrorCm: 1.4)
        let loaded = try JSONDecoder().decode(Calibration.self, from: JSONEncoder().encode(calibration))
        XCTAssertEqual(loaded.lambda, 0.1)
        XCTAssertEqual(loaded.displayLambdas, [1: 0.003, 2: 0.03])
        XCTAssertEqual(loaded.noiseRadius, 55)
        XCTAssertEqual(loaded.typicalErrorCm, 1.4)
        XCTAssertTrue(loaded.matches(displays: [a]))
    }

    func testDecodesCalibrationWithoutFitResults() throws {
        let json = """
        {"samples":[{"features":{"yaw":1,"pitch":2,"roll":3,"eyeX":0.1,"eyeY":-0.2,"faceX":0.5,"faceY":0.4,
        "faceSize":0.2,"timestamp":10},"point":[5,6],"displayID":1,"weight":1}],"displayLayoutHash":"old"}
        """
        let loaded = try JSONDecoder().decode(Calibration.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.samples.count, 1)
        XCTAssertEqual(loaded.lambda, GazeModel.regularization)
        XCTAssertEqual(loaded.noiseRadius, Calibration.defaultNoiseRadius)
        XCTAssertNil(loaded.typicalErrorCm)
        XCTAssertNil(loaded.displayLambdas)
    }
}
