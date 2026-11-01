import CoreGraphics
import XCTest
@testable import FreeGlance

final class PursuitPathTests: XCTestCase {
    private let frame = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    private let speed = 450.0
    private let step = 0.01

    private func positions(_ path: PursuitPath) -> [CGPoint] {
        stride(from: 0, through: path.length / speed, by: step).map { path.point(atDistance: $0 * speed) }
    }

    func testCoversTheInnerBox() {
        for rows in [3, 4] {
            let points = positions(.serpentine(in: frame, rows: rows))
            let box = frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06)
            XCTAssertEqual(points.map(\.x).min()!, box.minX, accuracy: 2)
            XCTAssertEqual(points.map(\.x).max()!, box.maxX, accuracy: 2)
            XCTAssertEqual(points.map(\.y).min()!, box.minY, accuracy: 2)
            XCTAssertEqual(points.map(\.y).max()!, box.maxY, accuracy: 2)
            let rowSizes = Dictionary(grouping: points) { Int($0.y.rounded()) }.values.map(\.count)
            XCTAssertEqual(rowSizes.count(where: { $0 >= 100 }), rows, "one long horizontal run per row")
        }
    }

    func testConstantSpeed() {
        let points = positions(.serpentine(in: frame, rows: 4))
        for (p, q) in zip(points, points.dropFirst()) {
            XCTAssertEqual(hypot(Double(q.x - p.x), Double(q.y - p.y)), speed * step, accuracy: speed * step * 0.01)
        }
    }

    func testDirectionNeverJumps() {
        for rows in [3, 4] {
            let points = positions(.serpentine(in: frame, rows: rows))
            let headings = zip(points, points.dropFirst()).map { atan2(Double($1.y - $0.y), Double($1.x - $0.x)) }
            for (a, b) in zip(headings, headings.dropFirst()) {
                let turn = abs(remainder(b - a, 2 * .pi))
                XCTAssertLessThan(turn * 180 / .pi, 30)
            }
        }
    }

    func testTallDisplayStaysInsideTheBox() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let box = portrait.insetBy(dx: portrait.width * 0.06, dy: portrait.height * 0.06)
        let points = positions(.serpentine(in: portrait, rows: 3))
        XCTAssertTrue(points.allSatisfy { box.insetBy(dx: -0.5, dy: -0.5).contains($0) })
        XCTAssertEqual(points.map(\.x).max()!, box.maxX, accuracy: 2)
    }

    func testTraceKeepsFramesAfterTheDiscardWindowOnly() {
        let path = PursuitPath.serpentine(in: frame, rows: 3)
        var trace = PursuitTrace(displayID: 1, path: path, speed: speed, start: 100)
        for t in stride(from: 99.0, through: 100 + trace.duration + 1, by: 0.1) {
            trace.record(GazeFeatures(yaw: 0, pitch: 0, roll: 0, eyeX: 0, eyeY: 0, faceX: 0.5, faceY: 0.5, faceSize: 0.2, timestamp: t))
        }
        XCTAssertGreaterThanOrEqual(trace.frames.first!.timestamp, 100 + PursuitTrace.discardDuration)
        XCTAssertLessThanOrEqual(trace.frames.last!.timestamp, 100 + trace.duration)
        XCTAssertEqual(trace.target(at: 50), path.start)
        XCTAssertEqual(trace.target(at: 100 + trace.duration + 5), path.point(atDistance: path.length))
    }
}
