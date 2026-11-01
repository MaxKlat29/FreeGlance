import CoreGraphics
import XCTest
@testable import FreeGlance

final class RefineTests: XCTestCase {
    private struct LCG {
        var state: UInt64
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private let a = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1500, height: 900), name: "A")
    private let b = DisplayInfo(id: 2, frame: CGRect(x: 1500, y: 100, width: 1000, height: 600), name: "B")

    private func frame(_ seed: UInt64 = 1) -> GazeFeatures {
        GazeFeatures(yaw: Double(seed), pitch: 0, roll: 0, eyeX: 0, eyeY: 0, faceX: 0.5, faceY: 0.5, faceSize: 0.2, timestamp: 0)
    }

    private func sample(display: CGDirectDisplayID, weight: Double = 1) -> CalibrationSample {
        CalibrationSample(features: frame(), point: .zero, displayID: display, weight: weight)
    }

    // MARK: Schedule

    func testGridCoversEveryDisplayAtTheGridFractions() {
        let schedule = RefineSchedule(displays: [a, b], seed: 1)
        XCTAssertEqual(schedule.targets.count, 30)
        let onB = schedule.targets.filter { $0.displayID == 2 }.map(\.point)
        XCTAssertEqual(onB.count, 15)
        XCTAssertEqual(Set(onB.map(\.x)), Set([0.08, 0.29, 0.5, 0.71, 0.92].map { 1500 + 1000 * $0 }))
        XCTAssertEqual(Set(onB.map(\.y)), Set([0.12, 0.5, 0.88].map { 100 + 600 * $0 }))
    }

    func testOrderIsDeterministicPerSeed() {
        func order(_ seed: UInt64) -> [RefineTarget] {
            var schedule = RefineSchedule(displays: [a, b], seed: seed)
            return (0..<30).compactMap { _ in
                defer { _ = schedule.complete(error: 1) }
                return schedule.current
            }
        }
        XCTAssertEqual(order(7), order(7))
        XCTAssertNotEqual(order(7), order(8))
    }

    func testFirstRoundVisitsEveryPointOnceThenWorstFirst() throws {
        var schedule = RefineSchedule(displays: [a, b], seed: 3)
        var visited: [RefineTarget] = []
        var errors: [Double] = []
        var roundMean: Double?
        for _ in 0..<30 {
            XCTAssertNil(roundMean)
            let target = try XCTUnwrap(schedule.current)
            visited.append(target)
            errors.append(Double(try XCTUnwrap(schedule.targets.firstIndex(of: target))))
            roundMean = schedule.complete(error: errors.last!)
        }
        XCTAssertEqual(visited.count, 30)
        XCTAssertTrue(schedule.targets.allSatisfy { visited.contains($0) })
        XCTAssertEqual(try XCTUnwrap(roundMean), 14.5, accuracy: 1e-12)
        // Second round: the largest last-measured error (highest target index) first.
        XCTAssertEqual(schedule.current, schedule.targets[29])
        _ = schedule.complete(error: 0)
        XCTAssertEqual(schedule.current, schedule.targets[28])
        XCTAssertEqual(try XCTUnwrap(schedule.recentMean(5)), (errors.suffix(4).reduce(0, +) + 0) / 5, accuracy: 1e-12)
    }

    func testRecentMeanIsNilBeforeTheFirstPoint() {
        XCTAssertNil(RefineSchedule(displays: [a], seed: 1).recentMean(5))
    }

    // MARK: Weighting, cap and replacement

    func testRefineWeightGivesOnePointFivePercentOfTheDisplaysSamples() {
        let samples = Array(repeating: sample(display: 1), count: 2000) + Array(repeating: sample(display: 2), count: 100)
            + Array(repeating: sample(display: CalibrationSample.awayDisplayID), count: 500)
        let calibration = Calibration(samples: samples, displays: [a, b])
        XCTAssertEqual(calibration.refineWeight(display: 1, frames: 20), 0.05 * 2000 / 20, accuracy: 1e-12)
        XCTAssertEqual(calibration.refineWeight(display: 2, frames: 20), 1, "never lighter than a calibration sample")
        XCTAssertEqual(calibration.refineWeight(display: 3, frames: 20), 1)
    }

    func testAddRefinePointLabelsFramesWithTargetAndWeight() {
        var calibration = Calibration(samples: Array(repeating: sample(display: 1), count: 1000), displays: [a])
        calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: 100, y: 100)), frames: Array(repeating: frame(), count: 10))
        XCTAssertEqual(calibration.refineSamples.count, 10)
        XCTAssertTrue(calibration.refineSamples.allSatisfy { $0.point == CGPoint(x: 100, y: 100) && $0.displayID == 1 && $0.weight == 5 })
        XCTAssertEqual(calibration.refinePoints, [RefineTarget(displayID: 1, point: CGPoint(x: 100, y: 100))])
    }

    func testNearbyRefinePointReplacesOlderOneOnSameDisplayOnly() {
        var calibration = Calibration(samples: [], displays: [a, b])
        let frames = Array(repeating: frame(), count: 8)
        calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: 100, y: 100)), frames: frames)
        calibration.addRefinePoint(RefineTarget(displayID: 2, point: CGPoint(x: 150, y: 100)), frames: frames)
        calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: 400, y: 100)), frames: frames)
        calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: 200, y: 160)), frames: frames)
        XCTAssertEqual(calibration.refinePoints, [
            RefineTarget(displayID: 2, point: CGPoint(x: 150, y: 100)),
            RefineTarget(displayID: 1, point: CGPoint(x: 400, y: 100)),
            RefineTarget(displayID: 1, point: CGPoint(x: 200, y: 160)),
        ])
        XCTAssertEqual(calibration.refineSamples.count, 24)
    }

    func testRefinePointsAreCappedPerDisplayDroppingTheOldest() {
        var calibration = Calibration(samples: [], displays: [a, b])
        let frames = Array(repeating: frame(), count: 8)
        calibration.addRefinePoint(RefineTarget(displayID: 2, point: .zero), frames: frames)
        let cap = Calibration.refinePointsPerDisplay
        for i in 0..<(cap + 5) {
            calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: Double(i) * 200, y: 0)), frames: frames)
        }
        let onA = calibration.refinePoints.filter { $0.displayID == 1 }
        XCTAssertEqual(onA.count, cap)
        XCTAssertEqual(onA.first?.point, CGPoint(x: 5 * 200, y: 0))
        XCTAssertEqual(onA.last?.point, CGPoint(x: Double(cap + 4) * 200, y: 0))
        XCTAssertEqual(calibration.refinePoints.filter { $0.displayID == 2 }.count, 1)
        XCTAssertEqual(calibration.refineSamples.count, (cap + 1) * 8)
    }

    // MARK: Persistence

    func testRefineSamplesSurviveRoundTrip() throws {
        var calibration = Calibration(samples: [sample(display: 1)], displays: [a])
        calibration.addRefinePoint(RefineTarget(displayID: 1, point: CGPoint(x: 10, y: 20)), frames: [frame(3)])
        let loaded = try JSONDecoder().decode(Calibration.self, from: JSONEncoder().encode(calibration))
        XCTAssertEqual(loaded.refineSamples.count, 1)
        XCTAssertEqual(loaded.refineSamples.first?.point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(loaded.refineSamples.first?.features, frame(3))
    }

    func testDecodesCalibrationWithoutRefineSamples() throws {
        let json = """
        {"samples":[{"features":{"yaw":1,"pitch":2,"roll":3,"eyeX":0.1,"eyeY":-0.2,"faceX":0.5,"faceY":0.4,
        "faceSize":0.2,"timestamp":10},"point":[5,6],"displayID":1,"weight":1}],"displayLayoutHash":"old","lambda":0.01}
        """
        let loaded = try JSONDecoder().decode(Calibration.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.samples.count, 1)
        XCTAssertTrue(loaded.refineSamples.isEmpty)
        XCTAssertTrue(loaded.refinePoints.isEmpty)
    }

    // MARK: Model

    /// Truth: x = 750 + 40 yaw + 1000 eyeX, y = 450 + 30 pitch + 800 eyeY on display A. The pursuit
    /// data is off by a constant 200 pt to the right (say the user sat differently), so the calibrated
    /// model is too. Pursuit splits the turn between head and eyes as in the two passes (60/40 or eyes
    /// only), and so do the refine frames, like calibration frames. One refine round of the 15 grid
    /// points, 20 frames each, must put the prediction at those points onto the targets: the regression
    /// alone gets about halfway, the residual correction does the rest.
    func testRefinePointsRemoveAConstantOffset() throws {
        var rng = LCG(state: 17)
        let offset = 200.0
        func features(looking target: CGPoint, headShare: Double, noise: Double) -> GazeFeatures {
            let dx = Double(target.x) - 750, dy = Double(target.y) - 450
            return GazeFeatures(yaw: headShare * dx / 40 + noise * rng.next(in: -0.3...0.3),
                                pitch: headShare * dy / 30 + noise * rng.next(in: -0.3...0.3),
                                roll: rng.next(in: -1...1),
                                eyeX: (1 - headShare) * dx / 1000 + noise * rng.next(in: -0.01...0.01),
                                eyeY: (1 - headShare) * dy / 800 + noise * rng.next(in: -0.01...0.01),
                                faceX: 0.5 + rng.next(in: -0.02...0.02), faceY: 0.5 + rng.next(in: -0.02...0.02),
                                faceSize: 0.2 + rng.next(in: -0.005...0.005), timestamp: 0)
        }
        let pursuit = (0..<2000).map { i -> CalibrationSample in
            let target = CGPoint(x: rng.next(in: 90...1410), y: rng.next(in: 54...846))
            let f = features(looking: target, headShare: i % 2 == 0 ? 0.6 : 0, noise: 1)
            return CalibrationSample(features: f, point: CGPoint(x: target.x + offset, y: target.y), displayID: 1, weight: 1)
        }
        var calibration = Calibration(samples: pursuit, displays: [a], lambda: 0.01, displayLambdas: [1: 0.01])
        let before = try XCTUnwrap(calibration.model())

        let schedule = RefineSchedule(displays: [a], seed: 4)
        let points = schedule.targets.map { target in
            (target, (0..<20).map { features(looking: target.point, headShare: $0 % 2 == 0 ? 0.6 : 0, noise: 1) })
        }
        for (target, frames) in points { calibration.addRefinePoint(target, frames: frames) }
        XCTAssertEqual(calibration.refinePoints.count, 15)
        let after = try XCTUnwrap(calibration.model())

        func medianError(_ model: GazeModel) -> Double {
            let errors = points.map { target, frames -> Double in
                let predictions = frames.map { model.refinedPoint($0, on: 1) }
                let x = predictions.map(\.x).sorted()[frames.count / 2], y = predictions.map(\.y).sorted()[frames.count / 2]
                return hypot(Double(x - target.point.x), Double(y - target.point.y))
            }
            return errors.sorted()[errors.count / 2]
        }
        let errorBefore = medianError(before), errorAfter = medianError(after)
        XCTAssertGreaterThan(errorBefore, 150)
        XCTAssertLessThan(errorAfter, 0.2 * errorBefore, "before \(errorBefore), after \(errorAfter)")
    }
}
