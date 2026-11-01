import CoreGraphics
import XCTest
@testable import FreeGlance

final class OneEuroFilterTests: XCTestCase {
    func testDampensJitterAtRestButFollowsATurn() {
        var filter = OneEuroFilter()
        let dt = 1.0 / 30
        var maxJitter = 0.0
        for i in 0..<60 {
            let noisy = CGPoint(x: 1000 + (i.isMultiple(of: 2) ? 60 : -60), y: 500)
            let out = filter.filter(noisy, at: Double(i) * dt)
            if i > 10 { maxJitter = max(maxJitter, abs(Double(out.x) - 1000)) }
        }
        XCTAssertLessThan(maxJitter, 25)

        var out = CGPoint.zero
        for i in 60..<66 { out = filter.filter(CGPoint(x: 3000, y: 500), at: Double(i) * dt) }
        XCTAssertGreaterThan(out.x, 2600, "a 2000 pt turn must land within 200 ms")
    }
}
