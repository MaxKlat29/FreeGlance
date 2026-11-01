import CoreGraphics
import CoreVideo
import Foundation
import Vision
import os

/// Turns camera frames into `GazeFeatures` using Vision face landmarks.
/// `analyze` runs synchronously on the caller's queue; results go to `onFeatures`,
/// which receives nil when no usable face is found.
final class FaceAnalyzer: Sendable {
    typealias FeaturesHandler = @Sendable (GazeFeatures?) -> Void

    /// Weight of the previous value in the exponential moving average, 0 disables smoothing.
    let smoothing: Double
    private let onFeatures: FeaturesHandler
    private let previous = OSAllocatedUnfairLock<GazeFeatures?>(initialState: nil)
    private static let smoothingGap: TimeInterval = 0.5

    init(smoothing: Double = 0.3, onFeatures: @escaping FeaturesHandler) {
        self.smoothing = min(max(smoothing, 0), 0.95)
        self.onFeatures = onFeatures
    }

    func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard let raw = Self.measure(pixelBuffer, timestamp: timestamp) else {
            previous.withLock { $0 = nil }
            onFeatures(nil)
            return
        }
        let features = previous.withLock { last -> GazeFeatures in
            let smoothed = last.flatMap { prior in
                timestamp - prior.timestamp <= Self.smoothingGap ? Self.blend(prior, raw, weight: smoothing) : nil
            } ?? raw
            last = smoothed
            return smoothed
        }
        onFeatures(features)
    }

    func reset() {
        previous.withLock { $0 = nil }
    }

    private static func measure(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> GazeFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? handler.perform([rectangles])) != nil,
              let face = rectangles.results?.max(by: { area($0) < area($1) }) else { return nil }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest])
        let landmarks = landmarksRequest.results?.first?.landmarks

        let box = face.boundingBox
        let eye = eyeOffset(landmarks) ?? (x: 0, y: 0)
        return GazeFeatures(
            yaw: -degrees(face.yaw),
            pitch: degrees(face.pitch),
            roll: -degrees(face.roll),
            eyeX: eye.x,
            eyeY: eye.y,
            faceX: 1 - Double(box.midX),
            faceY: Double(box.midY),
            faceSize: Double(box.width),
            timestamp: timestamp
        )
    }

    /// Pupil offset inside each eye contour's bounding box, mirrored to the user's view, averaged.
    private static func eyeOffset(_ landmarks: VNFaceLandmarks2D?) -> (x: Double, y: Double)? {
        guard let landmarks else { return nil }
        let pairs = [(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)]
        let offsets = pairs.compactMap { contour, pupil -> (x: Double, y: Double)? in
            guard let contour, let pupil, contour.pointCount > 2, pupil.pointCount > 0 else { return nil }
            let bounds = boundingBox(contour.normalizedPoints)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let center = pupil.normalizedPoints[0]
            let x = (Double(center.x - bounds.midX)) / Double(bounds.width / 2)
            let y = (Double(center.y - bounds.midY)) / Double(bounds.height / 2)
            return (x: -clamp(x), y: clamp(y))
        }
        guard !offsets.isEmpty else { return nil }
        let count = Double(offsets.count)
        return (
            x: offsets.reduce(0) { $0 + $1.x } / count,
            y: offsets.reduce(0) { $0 + $1.y } / count
        )
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func blend(_ old: GazeFeatures, _ new: GazeFeatures, weight w: Double) -> GazeFeatures {
        func mix(_ a: Double, _ b: Double) -> Double { a * w + b * (1 - w) }
        return GazeFeatures(
            yaw: mix(old.yaw, new.yaw),
            pitch: mix(old.pitch, new.pitch),
            roll: mix(old.roll, new.roll),
            eyeX: mix(old.eyeX, new.eyeX),
            eyeY: mix(old.eyeY, new.eyeY),
            faceX: mix(old.faceX, new.faceX),
            faceY: mix(old.faceY, new.faceY),
            faceSize: mix(old.faceSize, new.faceSize),
            timestamp: new.timestamp
        )
    }

    private static func area(_ face: VNFaceObservation) -> CGFloat {
        face.boundingBox.width * face.boundingBox.height
    }

    private static func degrees(_ radians: NSNumber?) -> Double {
        (radians?.doubleValue ?? 0) * 180 / .pi
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
