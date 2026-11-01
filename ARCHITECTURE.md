# FreeGlance

Native macOS menu bar app (macOS 14+, Swift 6, SwiftUI + AppKit). Camera estimates which
screen / window / split pane the user faces and moves keyboard focus there. Functional clone
of the GlanceSwitch Mac app, without licensing, updater or branding.

Bundle id `de.klattig.FreeGlance`, `LSUIElement = YES`, starts at login (SMAppService).
Permissions: Camera, Accessibility. Nothing else (no Screen Recording, no Input Monitoring).
Everything on-device, frames never stored, no network.

## Layout

```
project.yml                 xcodegen spec (app target FreeGlance, test target FreeGlanceTests)
FreeGlance/
  App/        FreeGlanceApp.swift, AppDelegate.swift, AppState.swift
  Tracking/   CameraSource.swift, FaceAnalyzer.swift, GazeFeatures.swift
  Model/      Calibration.swift, GazeModel.swift, ScreenSelector.swift, Dwell.swift, Settings.swift
  Focus/      FocusEngine.swift, WindowLocator.swift, AXHelpers.swift, PaneFocuser.swift, InputGuard.swift
  UI/         MenuBarController.swift, SettingsView.swift, CalibrationController.swift,
              WelcomeView.swift, GazeDotOverlay.swift, HotKey.swift
  Resources/  Info.plist, FreeGlance.entitlements
FreeGlanceTests/  pure-logic tests (Model/)
```

## Data flow

CameraSource (AVCapture, 1280x720, max 30 fps, prefers external camera, selectable)
→ FaceAnalyzer (Vision `VNDetectFaceLandmarksRequest`: yaw, pitch, roll, pupils, eye contours,
face bbox) → `GazeFeatures` → GazeModel (fit from calibration) → `GazeEstimate`
→ ScreenSelector (head pose only, dwell + threshold + hysteresis) and
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
struct CalibrationSample: Codable, Sendable { var features: GazeFeatures; var point: CGPoint /* global AppKit coords */; var displayID: CGDirectDisplayID; var weight: Double }
struct Calibration: Codable, Sendable { var samples: [CalibrationSample]; var displayLayoutHash: String; static func load() -> Calibration?; func save() }

// Model/GazeModel.swift  (ridge regression with quadratic terms, solved in-house, no deps)
struct GazeModel: Sendable {
    init?(samples: [CalibrationSample])            // nil if too few samples
    func predictPoint(_ f: GazeFeatures) -> CGPoint     // full vector -> global point
    func headPoint(_ f: GazeFeatures) -> CGPoint        // head vector only -> global point
}

// Model/ScreenSelector.swift   pure, testable, no AppKit side effects
struct DisplayInfo: Sendable, Equatable { var id: CGDirectDisplayID; var frame: CGRect; var name: String }
struct ScreenSelector {
    var displays: [DisplayInfo]
    var dwell: TimeInterval          // default 0.3
    var turnThreshold: Double        // 0...1, default 0.5 ("Head turn needed")
    var hysteresis: Double           // default 0.12, extra fraction needed to leave current screen
    var ignoreMargin: Double         // points beyond union of displays considered "away", default 0.35 * min screen width
    mutating func update(headPoint: CGPoint, at t: TimeInterval) -> CGDirectDisplayID?  // returns id only when a switch fires
    private(set) var current: CGDirectDisplayID?
}
// Threshold semantics: for current screen A and candidate B, project headPoint on the segment
// center(A)->center(B); B wins when fraction > turnThreshold + hysteresis (and stays so for dwell).

// Model/Dwell.swift  generic dwell filter reused for panes/windows
struct Dwell<Key: Hashable> { init(duration: TimeInterval); mutating func update(_ key: Key?, at t: TimeInterval) -> Key? }

// Model/Settings.swift   @MainActor final class Settings: ObservableObject, UserDefaults-backed
//   switchDelayMs = 150, headTurnPercent = 50, sameScreenFocus = true, paneDelayMs = 200,
//   waitWhileTyping = true, typingPauseSec = 2.0, showGazeDot = false, clickFallback = true,
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

## Behaviour rules (from the reference product)

- Screen switch: head pose only (linear model, One Euro filtered), dwell 150 ms, hysteresis so bezel glances don't ping-pong,
  poses far from every screen ignored. Needs >= 2 displays, else only same-screen focus.
- Never move focus or pointer while mouse/trackpad used and 1.5 s after.
- Wait while typing: panes never switch while typing; screens switch 0.4 s after the last key.
- Clicks teach the model (learnFromClicks): sample = current features + click point, weight 0.3,
  ring buffer of 300, refit throttled. Click positions not kept beyond the buffer.
- Drift: if > 40 % of last 20 clicks land on a different display than the one predicted,
  post UserNotification "FreeGlance accuracy dropped" naming the display, suggest recalibration.
- Calibration: fullscreen overlay per display, Space to start, dot through 9 spots (3x3 at 10/50/90 %)
  plus 3 extra spots along each shared edge, ~1.5 s per spot, discard first 0.4 s, Esc cancels.
  Recalibration needed when displayLayoutHash changes.
- Camera stops on lock / sleep / screensaver, resumes on unlock / wake.
- Menu: status "Tracking — facing <display>" / "Paused" / "Needs calibration", Pause Tracking ⇧⌘G,
  Recalibrate…, Settings… ⌘,, Welcome Guide…, Quit FreeGlance ⌘Q. Icon SF Symbol eye / eye.slash.
- Settings window tabs: Screens (live cards per display, highlighted facing one, last window app name),
  Split panes, Calibrate, Settings (all controls + camera picker + launch at login).
- Welcome guide: 1 camera permission, 2 accessibility permission (open System Settings pane,
  poll AXIsProcessTrusted), 3 calibrate, 4 done.
- Gaze dot: click-through borderless overlay, all spaces, shows predicted point.
- Global hotkey ⇧⌘G via Carbon RegisterEventHotKey (no permission needed).
