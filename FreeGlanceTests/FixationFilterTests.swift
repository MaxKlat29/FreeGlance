import CoreGraphics
import XCTest
@testable import FreeGlance

final class FixationFilterTests: XCTestCase {
    private let dt = 1.0 / 30

    func testJitterInsideRadiusStaysCalm() {
        var filter = FixationFilter()
        var maxDeviation = 0.0
        for i in 0..<90 {
            let jitter: CGFloat = i.isMultiple(of: 2) ? 30 : -30
            let out = filter.filter(CGPoint(x: 1000 + jitter, y: 500 - jitter / 2), at: Double(i) * dt)
            if i > 30 { maxDeviation = max(maxDeviation, hypot(Double(out.x) - 1000, Double(out.y) - 500)) }
        }
        XCTAssertLessThan(maxDeviation, 6)
    }

    func testSaccadeJumpsAfterTwoFrames() {
        var filter = FixationFilter()
        var t = 0.0
        for _ in 0..<30 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: t); t += dt }
        let first = filter.filter(CGPoint(x: 1600, y: 520), at: t)
        t += dt
        let second = filter.filter(CGPoint(x: 1610, y: 515), at: t)
        XCTAssertEqual(first.x, 1000, accuracy: 0.5)
        XCTAssertEqual(second.x, 1605, accuracy: 0.5)
        XCTAssertEqual(second.y, 517.5, accuracy: 0.5)
    }

    func testSingleOutlierIsIgnored() {
        var filter = FixationFilter()
        var t = 0.0
        for _ in 0..<30 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: t); t += dt }
        var outputs: [CGPoint] = []
        for p in [CGPoint(x: 1800, y: 900), CGPoint(x: 1000, y: 500), CGPoint(x: 1000, y: 500)] {
            outputs.append(filter.filter(p, at: t))
            t += dt
        }
        for out in outputs {
            XCTAssertEqual(out.x, 1000, accuracy: 0.5)
            XCTAssertEqual(out.y, 500, accuracy: 0.5)
        }
    }

    func testScatteredOutliersDoNotStartAFixation() {
        var filter = FixationFilter()
        var t = 0.0
        for _ in 0..<30 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: t); t += dt }
        _ = filter.filter(CGPoint(x: 1400, y: 500), at: t)
        let out = filter.filter(CGPoint(x: 600, y: 500), at: t + dt)
        XCTAssertEqual(out.x, 1000, accuracy: 0.5)
    }

    /// AppState feeds the unfiltered model point to the fixation filter: One Euro would smear a
    /// one-frame spike over two agreeing frames, which the fixation filter takes for a saccade.
    func testRawPointIgnoresSpikeThatOneEuroWouldSmear() {
        let rest = CGPoint(x: 1000, y: 500), spike = CGPoint(x: 1300, y: 500)
        var raw = FixationFilter(), chained = FixationFilter(), oneEuro = OneEuroFilter()
        var t = 0.0
        var rawOut: [CGPoint] = [], chainedOut: [CGPoint] = []
        for p in Array(repeating: rest, count: 30) + [spike] + Array(repeating: rest, count: 5) {
            rawOut.append(raw.filter(p, at: t))
            chainedOut.append(chained.filter(oneEuro.filter(p, at: t), at: t))
            t += dt
        }
        XCTAssertTrue(rawOut.allSatisfy { abs($0.x - rest.x) < 0.5 })
        XCTAssertGreaterThan(chainedOut.map(\.x).max() ?? 0, rest.x + 50)
    }

    func testRawStepLandsWithinTwoFrames() {
        var filter = FixationFilter()
        var t = 0.0
        for _ in 0..<30 { _ = filter.filter(CGPoint(x: 1000, y: 500), at: t); t += dt }
        _ = filter.filter(CGPoint(x: 1600, y: 500), at: t)
        let landed = filter.filter(CGPoint(x: 1600, y: 500), at: t + dt)
        XCTAssertEqual(landed.x, 1600, accuracy: 0.5)
    }
}
