import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var menuBar: MenuBarController?
    private var hotKey: HotKey?
    private var eyeTrackerHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let state = AppState()
        appState = state
        menuBar = MenuBarController(appState: state)
        hotKey = HotKey { [weak state] in
            state?.togglePause()
        }
        eyeTrackerHotKey = HotKey(keyCode: UInt32(kVK_ANSI_E)) { [weak state] in
            state?.toggleEyeTracker()
        }
        state.start()
        if CommandLine.arguments.contains("--recalibrate") {
            state.startCalibration()
        } else if CommandLine.arguments.contains("--refine") {
            state.startRefine()
        }
    }

    @MainActor
    func showSettings() {
        appState?.showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
