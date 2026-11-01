# FreeGlance

**Look at a screen. Start typing.**

FreeGlance is a free, open-source macOS menu bar app that moves keyboard focus to wherever you
are looking. It uses your camera to estimate which display, window or split pane you face, and
focuses it before your first keystroke, so you don't need to click.

Everything runs on your Mac. Camera frames are analysed in memory with Apple's Vision framework
and thrown away. Nothing is saved, and the app makes no network calls.

## Features

- **Switches screens with your gaze.** Head pose and eye position, with a short delay and
  hysteresis, so a glance at the bezel doesn't bounce focus back and forth. Turning clearly
  switches faster.
- **Focuses the window or split pane you look at.** Works in iTerm2, Terminal, Ghostty, Warp,
  kitty, WezTerm, Hyper, VS Code, Cursor, Windsurf, VSCodium, Zed, Sublime Text, Xcode,
  JetBrains IDEs and Android Studio. Other apps switch as whole windows.
- **Ignores your keyboard.** Calibration learns how you look down to type, so glancing at the
  keyboard never moves focus.
- **Waits while you type or use the mouse.**
  - Panes stay put while you type. Screens switch 0.4 s after your last keystroke.
  - Focus never moves while you use the mouse or trackpad, or for 1.5 s afterwards.
- **Learns from your clicks.** Every click on the screen you face refines the model. If the
  model drifts, for example after you move your seat, the app tells you to recalibrate.
- **Refine accuracy by looking at dots.** Look at a dot, press Space, and FreeGlance corrects
  the model at that spot, showing the error before and after.
- **Eye tracker overlay.** A click-through dot that shows where FreeGlance thinks you are
  looking. Toggle it with `⇧⌘E`.
- **Global shortcut.** Pause or resume with `⇧⌘G`.
- **Stops the camera** when the Mac locks or sleeps.

## Requirements

- macOS 14 Sonoma or later
- A camera: the built-in one, an external one, or Continuity Camera
- Two displays for screen switching. With one display, FreeGlance only focuses windows and panes.

## Build

```sh
brew install xcodegen
git clone https://github.com/MaxKlat29/FreeGlance.git
cd FreeGlance
xcodegen generate
xcodebuild -project FreeGlance.xcodeproj -scheme FreeGlance -configuration Release \
  -derivedDataPath build DEVELOPMENT_TEAM=<your team id> build
cp -R build/Build/Products/Release/FreeGlance.app /Applications/
```

Sign with your own Apple Development team, either via `DEVELOPMENT_TEAM` as shown above or in
`project.yml`. A stable signature keeps the Camera and Accessibility permissions across rebuilds.

To run the tests:

```sh
xcodebuild -project FreeGlance.xcodeproj -scheme FreeGlance test
```

## First run

1. Allow camera access.
2. Allow Accessibility. FreeGlance needs it to raise windows and move the pointer.
3. Calibrate. On every screen a ball slowly travels across the whole display. Follow it with your
   head and eyes, then once more with your eyes only while you face the screen and keep your head still.
   Finally look at your keyboard for 3 seconds. FreeGlance then shows the typical error it measured while you fixate a point.
4. Work as usual.

Recalibrate from the menu bar any time, or launch with `--recalibrate`.

## Refine accuracy

Calibration gets you close; Refine closes the gap at the spots you actually look at. Choose
**Refine Accuracy…** in the menu bar, **Refine** in the Calibrate tab of Settings, or launch with
`--refine`. It needs a calibration first and starts a full one otherwise.

1. A dot appears on one of your screens. Look at it and press Space while you keep looking.
2. FreeGlance records your eyes for under a second and shows where it thought you were looking
   (orange ring, with the error in cm), then updates the model and shows the new prediction (green
   marker, `→ 0.9 cm`).
3. The next dot appears. The first round visits 15 points per screen, after that the points with
   the largest error come first. The header shows the average error of the last 5 points. When a
   whole round averages below 1.5 cm, FreeGlance tells you it looks good.
4. Press Esc whenever you are done. The refinements are saved with the calibration.

Each refined spot counts for about 5 % of that screen's calibration data. On top of that, a local
correction moves predictions near a refined spot onto it and fades out within a few hundred points,
so refining fixes the spots you measured without bending the rest of the screen. Looking at the same
spot again replaces the old measurement. The Calibrate tab shows how many points are refined and
can clear them. A recalibration starts without refinements.

## How it works

```
Camera (up to 1080p, 30 fps) → Vision face landmarks → head pose + iris position
  (darkest pixels inside each eye contour, relative to the eye corners)
  → ridge regression (calibrated on smooth pursuit, eye latency and regularization cross-validated,
    plus refine points and clicks) → global gaze point
  → global point, One Euro filter → screen selector (threshold, hysteresis, adaptive dwell) + keyboard/away classifier
  → per-display refinement model of the screen you face + local correction from refine points
  → 3-frame median + fixation filter
    (calm while you look at one spot, jumps on a saccade) → eye tracker + pane focus
  → Accessibility focus (window raise, pane AXFocused, safe click fallback) + pointer warp
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout and the behaviour rules.

## Permissions

| Permission | Why |
|---|---|
| Camera | Estimates which way you are facing. Frames are never stored. |
| Accessibility | Focuses windows and panes and moves the pointer to the target screen. |

FreeGlance does not need Screen Recording or Input Monitoring. Keystroke timing comes from
`CGEventSource`, which never reads key contents.

## License

MIT
