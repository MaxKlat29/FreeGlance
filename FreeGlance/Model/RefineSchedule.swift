import CoreGraphics
import Foundation

/// One point the user fixates in Refine mode.
struct RefineTarget: Sendable, Equatable {
    var displayID: CGDirectDisplayID
    var point: CGPoint
}

/// Target order of Refine mode: a 5x3 grid per display, shuffled deterministically by `seed`. The
/// first round visits every point once; every later round visits them all again, the largest
/// last-measured error first.
struct RefineSchedule: Sendable {
    static let xFractions = [0.08, 0.29, 0.5, 0.71, 0.92]
    static let yFractions = [0.12, 0.5, 0.88]

    let targets: [RefineTarget]
    /// Last measured error per target, nil until it was measured.
    private(set) var lastErrors: [Double?]
    /// Every measured error in order.
    private(set) var history: [Double] = []
    private var queue: [Int]
    private var roundErrors: [Double] = []

    init(displays: [DisplayInfo], seed: UInt64) {
        let targets = displays.flatMap { display in
            Self.yFractions.flatMap { fy in
                Self.xFractions.map { fx in
                    RefineTarget(displayID: display.id,
                                 point: CGPoint(x: display.frame.minX + display.frame.width * fx,
                                                y: display.frame.minY + display.frame.height * fy))
                }
            }
        }
        var rng = SplitMix64(state: seed)
        self.targets = targets
        lastErrors = targets.map { _ in nil }
        queue = targets.indices.shuffled(using: &rng)
    }

    /// Nil only without displays.
    var current: RefineTarget? { queue.first.map { targets[$0] } }

    /// Records the error measured at `current` and moves on. Returns the round's mean error when this
    /// point completed a round.
    mutating func complete(error: Double) -> Double? {
        guard let index = queue.first else { return nil }
        queue.removeFirst()
        lastErrors[index] = error
        history.append(error)
        roundErrors.append(error)
        guard queue.isEmpty else { return nil }
        let mean = roundErrors.reduce(0, +) / Double(roundErrors.count)
        roundErrors = []
        queue = targets.indices.sorted { (lastErrors[$0] ?? .infinity) > (lastErrors[$1] ?? .infinity) }
        return mean
    }

    /// Mean of the last `count` measured errors, nil before the first.
    func recentMean(_ count: Int) -> Double? {
        let recent = history.suffix(count)
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }
}

/// Small seedable generator so a session's target order is reproducible.
struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
