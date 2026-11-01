# FreeGlance

Native macOS menu bar app (macOS 14+, Swift 6, SwiftUI + AppKit). Camera estimates which
screen / window / split pane the user faces and moves keyboard focus there. No licensing,
no updater, no network.

Bundle id `de.klattig.FreeGlance`, `LSUIElement = YES`, starts at login (SMAppService).
Permissions: Camera, Accessibility. Nothing else (no Screen Recording, no Input Monitoring).
Everything on-device, frames never stored, no network.

## Layout

```
project.yml                 xcodegen spec (app target FreeGlance, test target FreeGlanceTests)
FreeGlance/
  App/        FreeGlanceApp.swift, AppDelegate.swift, AppState.swift
  Tracking/   CameraSource.swift, FaceAnalyzer.swift, IrisLocator.swift, GazeFeatures.swift
  Model/      Calibration.swift, CalibrationFit.swift, PursuitPath.swift, GazeModel.swift, AwayDetector.swift,
              ScreenSelector.swift, Dwell.swift, OneEuroFilter.swift, MedianFilter.swift, FixationFilter.swift,
              Settings.swift
  Focus/      FocusEngine.swift, WindowLocator.swift, AXHelpers.swift, PaneFocuser.swift, InputGuard.swift
  UI/         MenuBarController.swift, SettingsView.swift, CalibrationController.swift,
              WelcomeView.swift, GazeDotOverlay.swift, HotKey.swift
  Resources/  Info.plist, FreeGlance.entitlements
FreeGlanceTests/  pure-logic tests (Model/)
```

## Data flow

CameraSource (AVCapture, 1920x1080 when supported else 1280x720, max 30 fps, prefers external
camera, selectable) → FaceAnalyzer (Vision `VNDetectFaceLandmarksRequest`: yaw, pitch, roll, eye
contours, face bbox; iris centre from luma pixels via IrisLocator) → `GazeFeatures` → GazeModel
(fit from calibration) → One Euro filtered point → AwayDetector + ScreenSelector (dwell + threshold
+ hysteresis); the unfiltered model point → MedianFilter (component-wise median of the last 3 frames, kills
single-frame spikes) → FixationFilter → eye tracker dot and FocusEngine (same-screen window/pane) → AX focus +
pointer warp.

Eye features (IrisLocator): per eye, the Vision eye contour in pixel coordinates spans an eye frame
(origin = midpoint of the two contour points farthest apart, unit = their distance). Inside the
contour polygon, pixels of the Y plane up to the 30th percentile of the masked luma form the iris;
their darkness-weighted centroid (weight = threshold - luma + 1) in the eye frame is `eyeX`/`eyeY`,
averaged over both eyes. Eye opening (contour height / width) < 0.12 is a blink. An eye without a fresh
reading (blink, squint, no measurable iris) keeps its last iris value until the face is lost, so the
average always spans the same eyes; Vision's pupil landmark (same frame) stands in only until a first
iris has been measured. Vision's pupil landmark alone
follows the contour and barely moves with the eyes (residual correlation after head features:
eyeX 0.42, eyeY -0.02 on real data), hence the pixel-based iris.

FixationFilter (eye tracker dot, pane/window targeting): within `Calibration.noiseRadius` (70 pt for
calibrations without one) of the current fixation the output is an exponentially weighted mean (250 ms); two consecutive frames that agree outside the
radius start a new fixation at once (saccade); a single stray frame is ignored.

## Contracts (shared types; implement exactly these names)

```swift
// Tracking/GazeFeatures.swift
struct GazeFeatures: Codable, Sendable, Equatable {
    var yaw: Double          // degrees, + = user turns to their right (screen-left mirrored handled here)
    var pitch: Double        // degrees, + = up
    var roll: Double
    var eyeX: Double         // iris centre relative to eye-corner midpoint, in eye widths, averaged both eyes
    var eyeY: Double
    var faceX: Double        // face bbox center in frame, 0...1
    var faceY: Double
    var faceSize: Double     // bbox width in frame, 0...1 (distance proxy)
    var timestamp: TimeInterval
    var headVector: [Double] { get }   // [yaw, pitch, faceX, faceY, faceSize]
    var fullVector: [Double] { get }   // headVector + [eyeX, eyeY]
}

// Model/Calibration.swift
struct CalibrationSample: Codable, Sendable { static let awayDisplayID: CGDirectDisplayID = 0 /* keyboard pose */; var features: GazeFeatures; var point: CGPoint /* global AppKit coords */; var displayID: CGDirectDisplayID; var weight: Double }
struct Calibration: Codable, Sendable {
    var samples: [CalibrationSample]; var displayLayoutHash: String
    var lambda: Double           // cross-validated ridge strength, used for click refits too (missing in old JSON: 0.03)
    var noiseRadius: Double      // FixationFilter radius in pt (missing in old JSON: 70)
    var typicalErrorCm: Double?  // median CV error on the largest display, shown after calibration and in Settings
    static func load() -> Calibration?; func save()
}

// Model/PursuitPath.swift  serpentine through the 6-94 % box, rows joined by semicircles, parametrized by distance
struct PursuitPath: Sendable { static func serpentine(in frame: CGRect, rows: Int) -> PursuitPath; var length: Double; func point(atDistance:) -> CGPoint }
// Model/CalibrationFit.swift
struct PursuitTrace: Sendable { var displayID; var path: PursuitPath; var speed: Double /* pt/s */; var start: TimeInterval
    var frames: [GazeFeatures]; func target(at t: TimeInterval) -> CGPoint; mutating func record(_ f: GazeFeatures) /* drops first 0.6 s */ }
struct CalibrationFit: Sendable { init?(traces: [PursuitTrace]); let lag, lambda, medianError, noiseRadius: Double; let samples: [CalibrationSample] }

// Model/GazeModel.swift  (ridge regression with quadratic terms, solved in-house, no deps;
//   RidgeProblem keeps the standardized design + Gram matrix so CV solves many targets/lambdas per fold)
struct GazeModel: Sendable {
    init?(samples: [CalibrationSample], lambda: Double = 0.03)   // nil if too few samples
    func predictPoint(_ f: GazeFeatures) -> CGPoint     // full vector -> global point; away samples ignored
}

// Model/AwayDetector.swift  two-class LDA (keyboard vs screen) on standardized fullVector,
//   shared covariance + ridge 0.3, weight-aware priors; always false without keyboard samples
struct AwayDetector: Sendable { init(samples: [CalibrationSample]); func isAway(_ f: GazeFeatures) -> Bool }

// Model/ScreenSelector.swift   pure, testable, no AppKit side effects
struct DisplayInfo: Sendable, Equatable { var id: CGDirectDisplayID; var frame: CGRect; var name: String }
struct ScreenSelector {
    var displays: [DisplayInfo]
    var dwell: TimeInterval          // default 0.3
    var turnThreshold: Double        // 0...1, default 0.5 ("Head turn needed")
    var hysteresis: Double           // default 0.12, extra fraction needed to leave current screen
    var ignoreMargin: Double         // points beyond union of displays considered "away", default 0.35 * min screen width
    func isAway(_ p: CGPoint) -> Bool  // outside union + ignoreMargin, or > 10 % of its height below the lowest display
    mutating func update(point: CGPoint, away: Bool, at t: TimeInterval) -> CGDirectDisplayID?  // returns id only when a switch fires
    private(set) var current: CGDirectDisplayID?
}
// Threshold semantics: for current screen A and candidate B, project the point on the segment
// center(A)->center(B); B wins when fraction > turnThreshold + hysteresis (and stays so for dwell).
// Adaptive dwell: fraction >= 1.0 (clearly on B) needs only half the dwell.

// Model/Dwell.swift  generic dwell filter reused for panes/windows
struct Dwell<Key: Hashable> { init(duration: TimeInterval); mutating func update(_ key: Key?, at t: TimeInterval) -> Key? }

// Model/Settings.swift   @MainActor final class Settings: ObservableObject, UserDefaults-backed
//   switchDelayMs = 150, headTurnPercent = 50, sameScreenFocus = true, paneDelayMs = 200,
//   waitWhileTyping = true, typingPauseSec = 2.0, showGazeDot = false /* "Show eye tracker" */, clickFallback = true,
//   learnFromClicks = true, cameraUniqueID: String? (nil = auto), launchAtLogin = true

// Focus/InputGuard.swift  uses CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)
struct InputGuard { static func secondsSinceKey() -> Double; static func secondsSinceMouse() -> Double }
//   mouse lockout 1.5 s; own pointer warps must not count (warp does not create events, keep it that way)

// Focus/FocusEngine.swift  @MainActor final class FocusEngine
//   focus(display:)  raise last-used window on that display (tracked via NSWorkspace activation +
//                    AX focused window observer), warp pointer to its center (or display center)
//   focus(point:)    same-screen: window under point (WindowLocator), then PaneFocuser
// Focus/WindowLocator.swift  CGWindowListCopyWindowInfo (bounds + owner pid only; no titles)
//                            -> match AXUIElement window by frame
// Focus/PaneFocuser.swift   supported bundle ids (iTerm2, Terminal, Ghostty, Warp, kitty, WezTerm,
//   Hyper, VS Code, Cursor, Windsurf, VSCodium, Zed, Sublime Text, Xcode, JetBrains, Android Studio):
//   find focusable AX descendant (AXTextArea / AXScrollArea / AXGroup leaf) containing point,
//   set AXFocused; if refused and clickFallback on: CGEvent click at pane center, only if the
//   window under that point belongs to the target pid.
```

## Behaviour rules

- Screen switch: full model point (head + eyes, One Euro filtered; 96 % vs 87-89 % head-only on real data),
  dwell 150 ms (half when the point is clearly on the other screen), hysteresis so bezel glances don't ping-pong.
  Needs >= 2 displays, else only same-screen focus.
- Away (looking at the keyboard): AwayDetector or the geometric rule. While away (or face lost): hold the current screen,
  reset pending dwell, undo a fired switch focus has not applied yet (typing, mouse), no screen or pane focus, no click learning or drift tracking.
- Never move focus or pointer while mouse/trackpad used and 1.5 s after.
- Wait while typing: panes never switch while typing; screens switch 0.4 s after the last key.
- Clicks teach the model (learnFromClicks): sample = current features + click point, ring buffer of 300,
  weighted so a full buffer carries 20 % of the total weight (scaled to the calibration's pursuit frame count),
  refit throttled with the calibration's lambda. Click positions not kept beyond the buffer.
- Drift: if > 40 % of last 20 clicks land on a different display than the one predicted,
  post UserNotification "FreeGlance accuracy dropped" naming the display, suggest recalibration.
- Calibration (smooth pursuit): borderless overlay per display, Space to start, Esc cancels at any time.
  Per display two passes: (A) "Follow the ball with your head and eyes, as you naturally would.", 4 rows;
  (B) "Face the centre of this screen, keep your head still and follow the ball with your eyes only.", 3 rows
  (decorrelates eye from head features, which co-move in A). Before each pass the instruction shows for 2 s
  with the ball resting at the path start; the other displays show "Look at <display>: the ball is there.". The ball (26 pt, white, red ring, dark centre dot) follows a
  serpentine from 6 % to 94 % of the display in both axes, semicircle turns, constant 11 cm/s
  (CGDisplayScreenSize, longest side over longest side so rotation does not matter; 300 pt/s when unknown), positioned from elapsed time on a display link.
  Every face frame of a pass is recorded with its timestamp; the first 0.6 s are dropped.
  Then keyboard pose on every screen: 1.5 s to read, 3 s countdown, discard first 0.5 s, samples with
  awayDisplayID (excluded from GazeModel, calibrated displays and completeness check).
  CalibrationFit (off the main thread): for lag in 0...200 ms (40 ms steps) frames at t are paired with the
  ball at t - lag; for lambda in 0.003...0.3 a 5-fold CV over contiguous 1 s blocks (round-robin to folds, no
  frame-level leakage) scores the quadratic ridge; the (lag, lambda) with the lowest median euclidean error wins.
  noiseRadius = 75th percentile of the per-frame CV error, clamped 40...160 pt. The overlay then shows
  "Calibration done — typical error ≈ X cm" (median CV error on the physically largest display) for 3 s
  (Esc there only closes it early, the result is kept); the Calibrate tab shows it too. Esc during the fit
  cancels the fit task. Fails (status "Calibration failed — try again") without a fit or with a
  display that has no samples.
  Recalibration needed when displayLayoutHash changes; the hash includes `Calibration.featureVersion`
  (3 = smooth pursuit with latency compensation), so older calibrations also need recalibration. Calibrations without keyboard samples stay valid
  (geometric rule only); the Calibrate tab shows "Keyboard: Not calibrated".
- Camera stops on lock / sleep / screensaver, resumes on unlock / wake.
- Menu: status "Tracking — facing <display>" / "Paused" / "Needs calibration", Pause Tracking ⇧⌘G,
  Show Eye Tracker ⇧⌘E (checkmark, settings.showGazeDot), Recalibrate…, Settings… ⌘,, Welcome Guide…, Quit FreeGlance ⌘Q. Icon SF Symbol eye / eye.slash.
- Settings window tabs: Screens (live cards per display, highlighted facing one, last window app name),
  Split panes, Calibrate, Settings (all controls + camera picker + launch at login).
- Welcome guide: 1 camera permission, 2 accessibility permission (open System Settings pane,
  poll AXIsProcessTrusted), 3 calibrate, 4 done.
- Eye tracker (gaze dot): click-through borderless overlay, all spaces, never key, 22 pt, shows the
  fixation-filtered point and glides to it (80 ms ease-out) instead of jumping. Accent while tracking, grey while away (pinned to the nearest screen edge), dimmed when paused.
- Global hotkeys ⇧⌘G (pause) and ⇧⌘E (eye tracker) via Carbon RegisterEventHotKey (no permission needed).
