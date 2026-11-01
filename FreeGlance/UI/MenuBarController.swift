import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Tracking", action: nil, keyEquivalent: "g")
    private let eyeTrackerItem = NSMenuItem(title: "Show Eye Tracker", action: nil, keyEquivalent: "e")
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        buildMenu()
        refresh()
        cancellable = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        eyeTrackerItem.keyEquivalentModifierMask = [.command, .shift]
        eyeTrackerItem.target = self
        eyeTrackerItem.action = #selector(toggleEyeTracker)
        menu.addItem(eyeTrackerItem)

        menu.addItem(item("Recalibrate…", #selector(recalibrate)))
        menu.addItem(item("Refine Accuracy…", #selector(refine)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Welcome Guide…", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(item("Quit FreeGlance", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refresh() {
        statusLine.title = appState.status
        pauseItem.title = appState.isPaused ? "Resume Tracking" : "Pause Tracking"
        eyeTrackerItem.state = appState.settings.showGazeDot ? .on : .off
        let symbol = appState.isPaused ? "eye.slash" : "eye"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FreeGlance")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func togglePause() { appState.togglePause() }
    @objc private func toggleEyeTracker() { appState.toggleEyeTracker() }
    @objc private func recalibrate() { appState.startCalibration() }
    @objc private func refine() { appState.startRefine() }
    @objc private func showSettings() { appState.showSettings() }
    @objc private func showWelcome() { appState.showWelcome() }
    @objc private func quit() { NSApp.terminate(nil) }
}
