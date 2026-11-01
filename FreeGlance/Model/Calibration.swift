import CoreGraphics
import CryptoKit
import Foundation

struct CalibrationSample: Codable, Sendable {
    /// Marks samples taken while the user looks at their keyboard instead of a screen.
    static let awayDisplayID: CGDirectDisplayID = 0

    var features: GazeFeatures
    var point: CGPoint
    var displayID: CGDirectDisplayID
    var weight: Double

    var isAway: Bool { displayID == Self.awayDisplayID }
}

struct Calibration: Codable, Sendable {
    static let defaultsKey = "calibration"

    var samples: [CalibrationSample]
    var displayLayoutHash: String

    init(samples: [CalibrationSample], displays: [DisplayInfo]) {
        self.samples = samples
        self.displayLayoutHash = Self.currentLayoutHash(displays: displays)
    }

    static func currentLayoutHash(displays: [DisplayInfo]) -> String {
        let layout = displays
            .sorted { $0.id < $1.id }
            .map { d in
                let f = d.frame.standardized
                return "\(d.id):\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)"
            }
            .joined(separator: "|")
        return SHA256.hash(data: Data(layout.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(displays: [DisplayInfo]) -> Bool {
        displayLayoutHash == Self.currentLayoutHash(displays: displays)
    }

    static func load(from defaults: UserDefaults = .standard) -> Calibration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
