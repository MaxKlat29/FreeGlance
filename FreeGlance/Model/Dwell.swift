import Foundation

struct Dwell<Key: Hashable> {
    var duration: TimeInterval
    private var candidate: Key?
    private var since: TimeInterval = 0
    private var fired = false

    init(duration: TimeInterval) {
        self.duration = duration
    }

    mutating func update(_ key: Key?, at t: TimeInterval) -> Key? {
        if key != candidate {
            candidate = key
            since = t
            fired = false
        }
        guard let key, !fired, t - since >= duration else { return nil }
        fired = true
        return key
    }

    mutating func reset() {
        candidate = nil
        fired = false
    }
}

extension Dwell: Sendable where Key: Sendable {}
