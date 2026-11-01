import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor
final class WelcomeWindowController {
    private let window: NSWindow

    init(appState: AppState) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to FreeGlance"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: WelcomeView(appState: appState) { [weak window] in window?.close() }
        )
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @ObservedObject var appState: AppState
    let onDone: () -> Void

    @State private var step = 0
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    private static let titles = ["Camera", "Accessibility", "Calibrate", "Done"]
    private static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(Self.titles.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text("Step \(step + 1) of \(Self.titles.count): \(Self.titles[step])")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                switch step {
                case 0: cameraStep
                case 1: accessibilityStep
                case 2: calibrateStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                if step < Self.titles.count - 1 {
                    Button("Next") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .task {
            while !Task.isCancelled {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                accessibilityTrusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var cameraStep: some View {
        StepPage(
            symbol: "camera",
            title: "Allow camera access",
            text: "FreeGlance estimates which screen, window and pane you face. Frames are analysed in memory on this Mac and never saved or sent anywhere.",
            granted: cameraStatus == .authorized
        ) {
            switch cameraStatus {
            case .notDetermined:
                Button("Allow Camera") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
            case .authorized:
                EmptyView()
            default:
                Button("Open Camera Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        }
    }

    private var accessibilityStep: some View {
        StepPage(
            symbol: "accessibility",
            title: "Allow Accessibility",
            text: "Needed to raise windows and focus split panes. Enable FreeGlance in System Settings > Privacy & Security > Accessibility. This page updates on its own.",
            granted: accessibilityTrusted
        ) {
            if !accessibilityTrusted {
                Button("Open System Settings") {
                    _ = AX.isTrusted(prompt: true)
                    NSWorkspace.shared.open(Self.accessibilityURL)
                }
            }
        }
    }

    private var calibrateStep: some View {
        StepPage(
            symbol: "scope",
            title: "Calibrate",
            text: "A dot moves across all your displays. Look at it the way you normally would, head and eyes. Takes about half a minute per display.",
            granted: !appState.displays.isEmpty && !appState.needsRecalibration
                && appState.displays.allSatisfy { appState.calibratedDisplayIDs.contains($0.id) }
        ) {
            Button("Start Calibration") { appState.startCalibration() }
                .disabled(cameraStatus != .authorized)
        }
    }

    private var doneStep: some View {
        StepPage(
            symbol: "eye",
            title: "You're set",
            text: "Turn your head toward a screen and focus follows. Pause any time with ⇧⌘G or from the eye icon in the menu bar.",
            granted: cameraStatus == .authorized && accessibilityTrusted
        ) {
            EmptyView()
        }
    }
}

private struct StepPage<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    let granted: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title2.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(granted ? "Ready" : "Not yet", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .orange)
            actions()
        }
    }
}
