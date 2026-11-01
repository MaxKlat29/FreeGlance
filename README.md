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
3. Calibrate. Follow the dot across every screen with your head and eyes, then once more with
   your eyes only while you face each screen and keep your head still, then look at your keyboard for 3 seconds.
4. Work as usual.

Recalibrate from the menu bar any time, or launch with `--recalibrate`.

## How it works

```
Camera (up to 1080p, 30 fps) → Vision face landmarks → head pose + iris position
  (darkest pixels inside each eye contour, relative to the eye corners)
  → ridge regression (calibrated) → gaze point
  → fixation filter (calm while you look at one spot, jumps on a saccade) → eye tracker + pane focus
  → One Euro filter → screen selector (threshold, hysteresis, adaptive dwell) + keyboard/away classifier
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
