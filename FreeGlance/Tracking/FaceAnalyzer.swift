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
    /// Last measured iris per eye (left, right) in the current face track.
    private let lastIris = OSAllocatedUnfairLock<[CGPoint?]>(initialState: [nil, nil])
    private static let smoothingGap: TimeInterval = 0.5

    init(smoothing: Double = 0.3, onFeatures: @escaping FeaturesHandler) {
        self.smoothing = min(max(smoothing, 0), 0.95)
        self.onFeatures = onFeatures
    }

    func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard let raw = measure(pixelBuffer, timestamp: timestamp) else {
            reset()
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
        lastIris.withLock { $0 = [nil, nil] }
    }

    private func measure(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> GazeFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? handler.perform([rectangles])) != nil,
              let face = rectangles.results?.max(by: { Self.area($0) < Self.area($1) }) else { return nil }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest])
        let landmarks = landmarksRequest.results?.first?.landmarks

        let box = face.boundingBox
        let eye = eyeOffset(landmarks, in: pixelBuffer)
        return GazeFeatures(
            yaw: -Self.degrees(face.yaw),
            pitch: Self.degrees(face.pitch),
            roll: -Self.degrees(face.roll),
            eyeX: Double(eye.x),
            eyeY: Double(eye.y),
            faceX: 1 - Double(box.midX),
            faceY: Double(box.midY),
            faceSize: Double(box.width),
            timestamp: timestamp
        )
    }

    /// Iris centre in each eye's own frame (see `IrisLocator`), averaged over both eyes.
    /// An eye without a fresh reading (blink, squint, low contrast) keeps its last iris value for
    /// the rest of the face track, so the average always spans the same eyes. Vision's pupil
    /// landmark (same frame) stands in only until a first iris has been measured.
    private func eyeOffset(_ landmarks: VNFaceLandmarks2D?, in pixelBuffer: CVPixelBuffer) -> CGPoint {
        guard let landmarks else { return .zero }
        let eyes = Self.readEyes([(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)],
                                 in: pixelBuffer)
        return lastIris.withLock { last -> CGPoint in
            for (index, iris) in eyes.irises.enumerated() where iris != nil {
                last[index] = iris
            }
            return Self.mean(last.compactMap { $0 }) ?? Self.mean(eyes.pupils) ?? .zero
        }
    }

    /// Fresh iris reading per eye in input order (nil when closed or not measurable), plus the pupil landmarks.
    private static func readEyes(
        _ eyes: [(contour: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?)],
        in pixelBuffer: CVPixelBuffer
    ) -> (irises: [CGPoint?], pupils: [CGPoint]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let plane = lumaPlane(of: pixelBuffer)

        var irises = [CGPoint?](repeating: nil, count: eyes.count), pupils: [CGPoint] = []
        for (index, (contour, pupil)) in eyes.enumerated() {
            guard let contour, contour.pointCount > 2 else { continue }
            let points = pixelPoints(contour, imageSize: size)
            guard let frame = IrisLocator.EyeFrame(contour: points) else { continue }
            if let pupil, pupil.pointCount > 0, let center = pixelPoints(pupil, imageSize: size).first {
                pupils.append(clamp(frame.offset(of: center)))
            }
            if case .open(let iris) = plane.flatMap({ IrisLocator.locate(contour: points, in: $0) }) {
                irises[index] = clamp(iris)
            }
        }
        return (irises, pupils)
    }

    /// Y plane of the full-range 4:2:0 camera format; the caller holds the base address lock.
    private static func lumaPlane(of pixelBuffer: CVPixelBuffer) -> LumaPlane? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        return LumaPlane(base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                         width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                         height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                         bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    }

    /// Landmark points in pixel coordinates with rows top to bottom (Vision's origin is bottom-left).
    private static func pixelPoints(_ region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> [CGPoint] {
        region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let count = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
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

    private static func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, -1), 1), y: min(max(p.y, -1), 1))
    }
}
