import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @discardableResult
    static func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled, !isEnabled {
                try service.register()
            } else if !enabled, isEnabled {
                try service.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(appState: AppState) {
        let hosting = NSHostingController(rootView: SettingsView(appState: appState, settings: appState.settings))
        window = NSWindow(contentViewController: hosting)
        window.title = "FreeGlance Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: Settings

    var body: some View {
        TabView {
            ScreensTab(appState: appState)
                .tabItem { Label("Screens", systemImage: "display.2") }
            SplitPanesTab(settings: settings)
                .tabItem { Label("Split panes", systemImage: "rectangle.split.2x1") }
            CalibrateTab(appState: appState)
                .tabItem { Label("Calibrate", systemImage: "scope") }
            GeneralTab(appState: appState, settings: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 580, minHeight: 460)
    }
}

private struct ScreensTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appState.status)
                .font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 12) {
                    ForEach(appState.displays.sorted { $0.frame.minX < $1.frame.minX }, id: \.id) { display in
                        ScreenCard(
                            display: display,
                            isFacing: appState.facingDisplay == display.id,
                            appName: appState.focusEngine.lastWindowAppName(for: display.id)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if appState.displays.count < 2 {
                Text("Only one display connected. FreeGlance switches windows and panes on this screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ScreenCard: View {
    let display: DisplayInfo
    let isFacing: Bool
    let appName: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isFacing ? "eye.fill" : "display")
                .font(.system(size: 28))
                .foregroundStyle(isFacing ? Color.accentColor : .secondary)
            Text(display.name)
                .font(.headline)
                .lineLimit(1)
            Text("\(Int(display.frame.width)) × \(Int(display.frame.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(appName ?? "No window yet")
                .font(.callout)
                .lineLimit(1)
        }
        .padding()
        .frame(maxWidth: 220, minHeight: 140)
        .aspectRatio(display.frame.width / max(display.frame.height, 1), contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFacing ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFacing ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFacing ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isFacing)
    }
}

private struct SplitPanesTab: View {
    @ObservedObject var settings: Settings

    private static let supportedApps = [
        "iTerm2", "Terminal", "Ghostty", "Warp", "kitty", "WezTerm", "Hyper",
        "Visual Studio Code", "Cursor", "Windsurf", "VSCodium", "Zed", "Sublime Text",
        "Xcode", "JetBrains IDEs", "Android Studio",
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Focus the window and split pane you look at on the same screen", isOn: $settings.sameScreenFocus)
                LabeledSlider(
                    title: "Pane switch delay",
                    value: doubleBinding($settings.paneDelayMs),
                    range: 100...1000,
                    step: 50,
                    format: { "\(Int($0)) ms" }
                )
                .disabled(!settings.sameScreenFocus)
                Toggle("Click to focus when an app refuses keyboard focus", isOn: $settings.clickFallback)
                    .disabled(!settings.sameScreenFocus)
            }
            Section("Supported apps") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading) {
                    ForEach(Self.supportedApps, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalibrateTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Displays") {
                ForEach(appState.displays, id: \.id) { display in
                    CalibrationRow(
                        name: display.name,
                        calibrated: appState.calibratedDisplayIDs.contains(display.id) && !appState.needsRecalibration
                    )
                }
                let keyboard = appState.keyboardCalibrated && !appState.needsRecalibration
                CalibrationRow(name: "Keyboard", calibrated: keyboard)
                if !keyboard {
                    Text("Recalibrate so that looking down at your keyboard never moves focus.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if let error = appState.calibrationErrorCm, !appState.needsRecalibration {
                    LabeledContent("Typical error", value: String(format: "≈ %.1f cm while fixating", error))
                }
                Text("Follow a slowly moving ball across each screen, once with head and eyes and once with your eyes only, then look at your keyboard. Takes about half a minute per display.")
                    .foregroundStyle(.secondary)
                Button("Calibrate") { appState.startCalibration() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalibrationRow: View {
    let name: String
    let calibrated: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Label(
                calibrated ? "Calibrated" : "Not calibrated",
                systemImage: calibrated ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(calibrated ? .green : .orange)
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Screen switching") {
                LabeledSlider(
                    title: "Switch delay",
                    value: doubleBinding($settings.switchDelayMs),
                    range: 100...1000,
                    step: 50,
                    format: { "\(Int($0)) ms" }
                )
                LabeledSlider(
                    title: "Head turn needed",
                    value: doubleBinding($settings.headTurnPercent),
                    range: 20...80,
                    step: 5,
                    format: { "\(Int($0)) %" }
                )
            }
            Section("Typing") {
                Toggle("Wait while typing", isOn: $settings.waitWhileTyping)
                LabeledSlider(
                    title: "Typing pause",
                    value: $settings.typingPauseSec,
                    range: 0.5...5,
                    step: 0.5,
                    format: { String(format: "%.1f s", $0) }
                )
                .disabled(!settings.waitWhileTyping)
            }
            Section("Tracking") {
                Toggle("Show eye tracker", isOn: $settings.showGazeDot)
                Toggle("Learn from clicks", isOn: $settings.learnFromClicks)
                Picker("Camera", selection: $settings.cameraUniqueID) {
                    Text("Automatic").tag(String?.none)
                    ForEach(appState.cameras, id: \.id) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                }
            }
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        if !LaunchAtLogin.apply(enabled) {
                            settings.launchAtLogin = !enabled
                        }
                    }
                if settings.launchAtLogin, LaunchAtLogin.needsApproval {
                    Button("Approve in System Settings") { LaunchAtLogin.openApprovalSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}

private func doubleBinding(_ binding: Binding<Int>) -> Binding<Double> {
    Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
}
