import CoreGraphics
import XCTest
@testable import FreeGlance

final class MedianFilterTests: XCTestCase {
    private let dt = 1.0 / 30

    func testSingleSpikeNeverPasses() {
        var filter = MedianFilter()
        let rest = CGPoint(x: 1000, y: 500)
        let input = Array(repeating: rest, count: 5) + [CGPoint(x: 1600, y: 100)] + Array(repeating: rest, count: 5)
        for (i, p) in input.enumerated() {
            let out = filter.filter(p, at: Double(i) * dt)
            XCTAssertEqual(out, rest)
        }
    }

    func testStepPassesOnSecondFrame() {
        var filter = MedianFilter()
        var t = 0.0
        for _ in 0..<5 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: t); t += dt }
        XCTAssertEqual(filter.filter(CGPoint(x: 1600, y: 500), at: t).x, 1000)
        XCTAssertEqual(filter.filter(CGPoint(x: 1600, y: 500), at: t + dt).x, 1600)
    }

    func testGapStartsOver() {
        var filter = MedianFilter()
        for i in 0..<5 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: Double(i) * dt) }
        XCTAssertEqual(filter.filter(CGPoint(x: 200, y: 300), at: 5), CGPoint(x: 200, y: 300))
    }
}
