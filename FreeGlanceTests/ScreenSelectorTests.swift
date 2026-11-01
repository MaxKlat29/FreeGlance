import CoreGraphics
import XCTest
@testable import FreeGlance

final class ScreenSelectorTests: XCTestCase {
    private let left = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600), name: "Left")
    private let right = DisplayInfo(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 600), name: "Right")

    private func selector() -> ScreenSelector {
        var s = ScreenSelector(displays: [left, right])
        XCTAssertNil(s.update(headPoint: CGPoint(x: 500, y: 300), at: 0))
        XCTAssertEqual(s.current, 1)
        return s
    }

    func testDefaults() {
        let s = ScreenSelector(displays: [left, right])
        XCTAssertEqual(s.dwell, 0.3)
        XCTAssertEqual(s.turnThreshold, 0.5)
        XCTAssertEqual(s.hysteresis, 0.12)
        XCTAssertEqual(s.ignoreMargin, 350, accuracy: 1e-9)
    }

    func testFiresAfterDwell() {
        var s = selector()
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.2))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.3), 2)
        XCTAssertEqual(s.current, 2)
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.5))
    }

    func testShortGlanceDoesNotFire() {
        var s = selector()
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.2))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 500, y: 300), at: 1.25))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 500, y: 300), at: 2.0))
        XCTAssertEqual(s.current, 1)
    }

    func testHysteresisPreventsPingPongAtMidpoint() {
        var s = selector()
        var t = 1.0
        for x in [990.0, 1010, 1060, 990, 1100, 1050] {
            XCTAssertNil(s.update(headPoint: CGPoint(x: x, y: 300), at: t))
            t += 0.5
        }
        XCTAssertEqual(s.current, 1)

        XCTAssertNil(s.update(headPoint: CGPoint(x: 1200, y: 300), at: t))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 1200, y: 300), at: t + 0.35), 2)
        t += 1
        for x in [1010.0, 990, 940, 1010, 900, 950] {
            XCTAssertNil(s.update(headPoint: CGPoint(x: x, y: 300), at: t))
            t += 0.5
        }
        XCTAssertEqual(s.current, 2)
    }

    func testThresholdControlsRequiredTurn() {
        var s = selector()
        s.turnThreshold = 0.2
        XCTAssertNil(s.update(headPoint: CGPoint(x: 900, y: 300), at: 1))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 900, y: 300), at: 1.3), 2)
    }

    func testFarPosesIgnored() {
        var s = selector()
        XCTAssertNil(s.update(headPoint: CGPoint(x: 2500, y: 300), at: 1.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 2500, y: 300), at: 2.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: -1000), at: 3.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: -1000), at: 4.0))
        XCTAssertEqual(s.current, 1)
    }

    func testFarPoseInterruptsDwell() {
        var s = selector()
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 5000, y: 300), at: 1.1))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.35))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 1500, y: 300), at: 1.7), 2)
    }

    func testSingleDisplayNeverFires() {
        var s = ScreenSelector(displays: [left])
        for i in 0..<20 {
            XCTAssertNil(s.update(headPoint: CGPoint(x: Double(i * 100), y: 300), at: Double(i)))
        }
        XCTAssertNil(s.current)
    }

    func testPicksStrongestOfSeveralCandidates() {
        let top = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 600, width: 1000, height: 600), name: "Top")
        var s = ScreenSelector(displays: [left, right, top])
        XCTAssertNil(s.update(headPoint: CGPoint(x: 500, y: 300), at: 0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 600, y: 900), at: 1))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 600, y: 900), at: 1.3), 3)
    }

    func testPicksFacedDisplayInRowOfThree() {
        let far = DisplayInfo(id: 3, frame: CGRect(x: 2000, y: 0, width: 1000, height: 600), name: "Far")
        var s = ScreenSelector(displays: [left, right, far])
        XCTAssertNil(s.update(headPoint: CGPoint(x: 500, y: 300), at: 0))
        XCTAssertNil(s.update(headPoint: CGPoint(x: 2500, y: 300), at: 1))
        XCTAssertEqual(s.update(headPoint: CGPoint(x: 2500, y: 300), at: 1.3), 3)
        XCTAssertEqual(s.current, 3)
    }

    func testRemovingCurrentDisplayResetsCurrent() {
        var s = selector()
        s.displays = [right]
        XCTAssertNil(s.current)
    }
}
