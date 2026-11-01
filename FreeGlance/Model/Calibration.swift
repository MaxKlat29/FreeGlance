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
    /// Bumped when `GazeFeatures` semantics change; older calibrations then need recalibration.
    /// 3: dense smooth-pursuit samples with latency compensation and cross-validated ridge strength.
    static let featureVersion = 3
    /// Fixation radius for calibrations that predate the measured one.
    static let defaultNoiseRadius = 70.0
    /// Share of a display's calibration samples one refine point carries.
    static let refineShare = 0.05
    /// Refine points kept per display; the oldest go first.
    static let refinePointsPerDisplay = 60
    /// A new refine point replaces older ones on the same display within this distance, in points.
    static let refineReplaceRadius = 120.0

    var samples: [CalibrationSample]
    var displayLayoutHash: String
    /// Ridge strength chosen by cross-validation; also used when clicks refit the model.
    var lambda: Double
    /// Ridge strength of each display's refinement model, chosen by cross-validation; nil in calibrations
    /// that predate it (`GazeModel.displayRegularization` then).
    var displayLambdas: [CGDirectDisplayID: Double]?
    /// Typical per-frame model error in points, the fixation filter's radius.
    var noiseRadius: Double
    /// Median cross-validated error while fixating (predictions averaged over 0.5 s), in centimetres at the
    /// physically largest display's pixel density; nil when its physical size is unknown.
    var typicalErrorCm: Double?
    /// Frames from Refine mode, labelled with the target the user fixated; all frames of one refine
    /// point share its target. Empty in calibrations that predate Refine mode.
    var refineSamples: [CalibrationSample] = []

    init(samples: [CalibrationSample], displays: [DisplayInfo], lambda: Double = GazeModel.regularization,
         displayLambdas: [CGDirectDisplayID: Double]? = nil, noiseRadius: Double = Calibration.defaultNoiseRadius, typicalErrorCm: Double? = nil) {
        self.samples = samples
        self.displayLayoutHash = Self.currentLayoutHash(displays: displays)
        self.lambda = lambda
        self.displayLambdas = displayLambdas
        self.noiseRadius = noiseRadius
        self.typicalErrorCm = typicalErrorCm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decode([CalibrationSample].self, forKey: .samples)
        displayLayoutHash = try c.decode(String.self, forKey: .displayLayoutHash)
        lambda = try c.decodeIfPresent(Double.self, forKey: .lambda) ?? GazeModel.regularization
        displayLambdas = try c.decodeIfPresent([CGDirectDisplayID: Double].self, forKey: .displayLambdas)
        noiseRadius = try c.decodeIfPresent(Double.self, forKey: .noiseRadius) ?? Self.defaultNoiseRadius
        typicalErrorCm = try c.decodeIfPresent(Double.self, forKey: .typicalErrorCm)
        refineSamples = try c.decodeIfPresent([CalibrationSample].self, forKey: .refineSamples) ?? []
    }

    static func currentLayoutHash(displays: [DisplayInfo]) -> String {
        let layout = "v\(featureVersion)|" + displays
            .sorted { $0.id < $1.id }
            .map { d in
                let f = d.frame.standardized
                return "\(d.id):\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)"
            }
            .joined(separator: "|")
        return SHA256.hash(data: Data(layout.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Weight of one learnt click: a full buffer of `bufferSize` clicks carries `share` of the combined
    /// weight, however many pursuit frames the calibration holds.
    func clickWeight(bufferSize: Int, share: Double) -> Double {
        let screenWeight = samples.filter { !$0.isAway }.reduce(0) { $0 + $1.weight }
        return share / (1 - share) * screenWeight / Double(bufferSize)
    }

    /// Two-stage model from the calibration, its refine points and `extra` samples (learnt clicks).
    func model(adding extra: [CalibrationSample] = []) -> GazeModel? {
        GazeModel(samples: samples + extra, refineSamples: refineSamples, lambda: lambda, displayLambdas: displayLambdas ?? [:])
    }

    /// Weight of each frame of a refine point with `frames` frames: the point carries `refineShare` of
    /// the display's calibration samples, and no frame weighs less than a calibration sample.
    func refineWeight(display: CGDirectDisplayID, frames: Int) -> Double {
        let count = samples.count { !$0.isAway && $0.displayID == display }
        return max(1, Self.refineShare * Double(count) / Double(max(frames, 1)))
    }

    /// Adds one refine point: replaces older points on the display within `refineReplaceRadius`, then
    /// drops the oldest beyond `refinePointsPerDisplay`.
    mutating func addRefinePoint(_ target: RefineTarget, frames: [GazeFeatures]) {
        guard !frames.isEmpty else { return }
        let weight = refineWeight(display: target.displayID, frames: frames.count)
        refineSamples.removeAll { s in
            s.displayID == target.displayID
                && hypot(Double(s.point.x - target.point.x), Double(s.point.y - target.point.y)) <= Self.refineReplaceRadius
        }
        refineSamples += frames.map { CalibrationSample(features: $0, point: target.point, displayID: target.displayID, weight: weight) }
        let points = refinePoints.filter { $0.displayID == target.displayID }
        let dropped = points.prefix(max(0, points.count - Self.refinePointsPerDisplay)).map(\.point)
        refineSamples.removeAll { s in s.displayID == target.displayID && dropped.contains(s.point) }
    }

    /// Distinct refine points, oldest first.
    var refinePoints: [RefineTarget] {
        var points: [RefineTarget] = []
        for s in refineSamples {
            let target = RefineTarget(displayID: s.displayID, point: s.point)
            if !points.contains(target) { points.append(target) }
        }
        return points
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
