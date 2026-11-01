import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var menuBar: MenuBarController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let state = AppState()
        appState = state
        menuBar = MenuBarController(appState: state)
        hotKey = HotKey { [weak state] in
            state?.togglePause()
        }
        state.start()
    }

    @MainActor
    func showSettings() {
        appState?.showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
