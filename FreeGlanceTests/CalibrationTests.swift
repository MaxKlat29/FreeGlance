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

    @MainActor
    func testSpotsEndWithEyesOnlyPassPerDisplay() {
        let spots = CalibrationController.makeSpots(for: [a, b])
        let firstEyesOnly = spots.firstIndex(where: \.eyesOnly) ?? spots.count
        XCTAssertFalse(spots[..<firstEyesOnly].isEmpty)
        XCTAssertTrue(spots[firstEyesOnly...].allSatisfy(\.eyesOnly), "eyes-only pass runs after the head-and-eyes spots")

        for display in [a, b] {
            let eyesOnly = spots.filter { $0.eyesOnly && $0.displayID == display.id }
            XCTAssertEqual(eyesOnly.count, 5)
            XCTAssertEqual(eyesOnly.first?.point, CGPoint(x: display.frame.midX, y: display.frame.midY))
            XCTAssertTrue(eyesOnly.allSatisfy { display.frame.contains($0.point) })
            XCTAssertEqual(Set(eyesOnly.map(\.point.x)).count, 3)
        }
    }
}
