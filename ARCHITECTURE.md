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
  Tracking/   CameraSource.swift, FaceAnalyzer.swift, GazeFeatures.swift
  Model/      Calibration.swift, GazeModel.swift, AwayDetector.swift, ScreenSelector.swift, Dwell.swift, Settings.swift
  Focus/      FocusEngine.swift, WindowLocator.swift, AXHelpers.swift, PaneFocuser.swift, InputGuard.swift
  UI/         MenuBarController.swift, SettingsView.swift, CalibrationController.swift,
              WelcomeView.swift, GazeDotOverlay.swift, HotKey.swift
  Resources/  Info.plist, FreeGlance.entitlements
FreeGlanceTests/  pure-logic tests (Model/)
```

## Data flow

CameraSource (AVCapture, 1280x720, max 30 fps, prefers external camera, selectable)
→ FaceAnalyzer (Vision `VNDetectFaceLandmarksRequest`: yaw, pitch, roll, pupils, eye contours,
face bbox) → `GazeFeatures` → GazeModel (fit from calibration) → One Euro filtered point
→ AwayDetector + ScreenSelector (full model point, dwell + threshold + hysteresis) and
FocusEngine (same-screen window/pane via predicted point) → AX focus + pointer warp.

## Contracts (shared types; implement exactly these names)

```swift
// Tracking/GazeFeatures.swift
struct GazeFeatures: Codable, Sendable, Equatable {
    var yaw: Double          // degrees, + = user turns to their right (screen-left mirrored handled here)
    var pitch: Double        // degrees, + = up
    var roll: Double
    var eyeX: Double         // pupil offset inside eye contour, -1...1, averaged both eyes
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
struct Calibration: Codable, Sendable { var samples: [CalibrationSample]; var displayLayoutHash: String; static func load() -> Calibration?; func save() }

// Model/GazeModel.swift  (ridge regression with quadratic terms, solved in-house, no deps)
struct GazeModel: Sendable {
    init?(samples: [CalibrationSample])            // nil if too few samples
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
- Clicks teach the model (learnFromClicks): sample = current features + click point, weight 0.3,
  ring buffer of 300, refit throttled. Click positions not kept beyond the buffer.
- Drift: if > 40 % of last 20 clicks land on a different display than the one predicted,
  post UserNotification "FreeGlance accuracy dropped" naming the display, suggest recalibration.
- Calibration: fullscreen overlay per display, Space to start, dot through 9 spots (3x3 at 10/50/90 %)
  plus 3 extra spots along each shared edge, ~1.5 s per spot, discard first 0.4 s, Esc cancels.
  Then keyboard pose on every screen: 1.5 s to read, 3 s countdown, discard first 0.5 s, samples with
  awayDisplayID (excluded from GazeModel, calibrated displays and completeness check).
  Recalibration needed when displayLayoutHash changes. Calibrations without keyboard samples stay valid
  (geometric rule only); the Calibrate tab shows "Keyboard: Not calibrated".
- Camera stops on lock / sleep / screensaver, resumes on unlock / wake.
- Menu: status "Tracking — facing <display>" / "Paused" / "Needs calibration", Pause Tracking ⇧⌘G,
  Show Eye Tracker ⇧⌘E (checkmark, settings.showGazeDot), Recalibrate…, Settings… ⌘,, Welcome Guide…, Quit FreeGlance ⌘Q. Icon SF Symbol eye / eye.slash.
- Settings window tabs: Screens (live cards per display, highlighted facing one, last window app name),
  Split panes, Calibrate, Settings (all controls + camera picker + launch at login).
- Welcome guide: 1 camera permission, 2 accessibility permission (open System Settings pane,
  poll AXIsProcessTrusted), 3 calibrate, 4 done.
- Eye tracker (gaze dot): click-through borderless overlay, all spaces, never key, 22 pt, shows the filtered
  predicted point. Accent while tracking, grey while away (pinned to the nearest screen edge), dimmed when paused.
- Global hotkeys ⇧⌘G (pause) and ⇧⌘E (eye tracker) via Carbon RegisterEventHotKey (no permission needed).
