import Foundation

/// One frame's worth of head and eye measurements, expressed from the user's point of view.
///
/// Conventions (camera frames are analysed unmirrored, signs are flipped here so that
/// "right" always means the user's right, i.e. towards the right edge of a screen they face):
/// - `yaw`: degrees, + = user turns their head to their right.
/// - `pitch`: degrees, + = user tilts their head up.
/// - `roll`: degrees, + = head tilts towards the user's right shoulder.
/// - `eyeX`/`eyeY`: pupil position inside the eye contour bounding box, -1...1,
///   + = looking to the user's right / up, averaged over both eyes.
/// - `faceX`/`faceY`: face bounding box center in the frame, 0...1,
///   `faceX` grows as the user moves to their right, `faceY` grows upwards.
/// - `faceSize`: face bounding box width relative to frame width, 0...1 (distance proxy).
/// - `timestamp`: `ProcessInfo.systemUptime` at frame delivery.
struct GazeFeatures: Codable, Sendable, Equatable {
    var yaw: Double
    var pitch: Double
    var roll: Double
    var eyeX: Double
    var eyeY: Double
    var faceX: Double
    var faceY: Double
    var faceSize: Double
    var timestamp: TimeInterval

    var headVector: [Double] { [yaw, pitch, faceX, faceY, faceSize] }
    var fullVector: [Double] { headVector + [eyeX, eyeY] }
}
