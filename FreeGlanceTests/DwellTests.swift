import XCTest
@testable import FreeGlance

final class DwellTests: XCTestCase {
    func testFiresOnceAfterDuration() {
        var dwell = Dwell<String>(duration: 0.3)
        XCTAssertNil(dwell.update("a", at: 0))
        XCTAssertNil(dwell.update("a", at: 0.2))
        XCTAssertEqual(dwell.update("a", at: 0.3), "a")
        XCTAssertNil(dwell.update("a", at: 0.5))
    }

    func testKeyChangeRestartsTimer() {
        var dwell = Dwell<String>(duration: 0.3)
        XCTAssertNil(dwell.update("a", at: 0))
        XCTAssertNil(dwell.update("b", at: 0.2))
        XCTAssertNil(dwell.update("b", at: 0.4))
        XCTAssertEqual(dwell.update("b", at: 0.5), "b")
    }

    func testNilInterruptsAndNeverFires() {
        var dwell = Dwell<Int>(duration: 0.3)
        XCTAssertNil(dwell.update(1, at: 0))
        XCTAssertNil(dwell.update(nil, at: 0.2))
        XCTAssertNil(dwell.update(nil, at: 1))
        XCTAssertNil(dwell.update(1, at: 1.1))
        XCTAssertEqual(dwell.update(1, at: 1.45), 1)
    }

    func testFiresAgainAfterReturning() {
        var dwell = Dwell<Int>(duration: 0.1)
        XCTAssertNil(dwell.update(1, at: 0))
        XCTAssertEqual(dwell.update(1, at: 0.1), 1)
        XCTAssertNil(dwell.update(2, at: 0.2))
        XCTAssertNil(dwell.update(1, at: 0.3))
        XCTAssertEqual(dwell.update(1, at: 0.4), 1)
    }

    func testZeroDurationFiresImmediately() {
        var dwell = Dwell<Int>(duration: 0)
        XCTAssertEqual(dwell.update(7, at: 5), 7)
    }
}
