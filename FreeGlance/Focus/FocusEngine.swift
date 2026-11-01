import AppKit
import ApplicationServices

@MainActor
final class FocusEngine {
    private struct TrackedWindow {
        let element: AXUIElement
        let pid: pid_t
        let appName: String
    }

    var clickFallback = true

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let paneFocuser = PaneFocuser()
    private var lastWindows: [CGDirectDisplayID: TrackedWindow] = [:]
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0

    init() {
        AX.setGlobalTimeout(0.3)
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(pid) }
        }
        accessibilityGranted()
    }

    /// Re-attaches observers that failed while Accessibility was not yet granted.
    func accessibilityGranted() {
        for app in NSWorkspace.shared.runningApplications {
            paneFocuser.enableManualAccessibility(pid: app.processIdentifier)
        }
        applicationActivated(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        detachAXObserver()
    }

    func lastWindowAppName(for display: CGDirectDisplayID) -> String? {
        lastWindows[display]?.appName
    }

    func focus(display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        guard let target = window(onDisplay: display) else {
            warpPointer(to: CGPoint(x: bounds.midX, y: bounds.midY), unlessWithin: bounds)
            return
        }
        if !isFocused(target.element, pid: target.pid) {
            activate(target.element, pid: target.pid)
        }
        let frame = AX.frame(target.element)?.intersection(bounds) ?? bounds
        warpPointer(to: CGPoint(x: frame.midX, y: frame.midY), unlessWithin: frame)
    }

    func focus(point: CGPoint, onDisplay display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        let raw = WindowLocator.cgPoint(fromAppKit: point)
        let cgPoint = CGPoint(x: min(max(raw.x, bounds.minX), bounds.maxX - 1),
                              y: min(max(raw.y, bounds.minY), bounds.maxY - 1))
        guard let info = WindowLocator.topmostWindow(at: cgPoint, excluding: ownPID),
              let window = WindowLocator.axWindow(for: info) else { return }
        if !isFocused(window, pid: info.pid) {
            activate(window, pid: info.pid)
            let frame = info.bounds.intersection(bounds)
            warpPointer(to: CGPoint(x: frame.midX, y: frame.midY), unlessWithin: frame)
        }
        paneFocuser.focusPane(pid: info.pid, windowID: info.windowID, at: cgPoint, clickFallback: clickFallback)
    }

    fileprivate func recordFocusedWindow(of pid: pid_t) {
        guard pid != ownPID, let window = AX.focusedWindow(pid), AX.bool(window, kAXMinimizedAttribute) != true,
              let frame = AX.frame(window),
              let display = WindowLocator.display(containing: CGPoint(x: frame.midX, y: frame.midY)) else { return }
        lastWindows = lastWindows.filter { !CFEqual($0.value.element, window) }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        lastWindows[display] = TrackedWindow(element: window, pid: pid, appName: name)
    }

    private func applicationActivated(_ pid: pid_t?) {
        guard let pid, pid != ownPID else { return }
        if pid != observedPID { attachAXObserver(to: pid) }
        paneFocuser.enableManualAccessibility(pid: pid)
        recordFocusedWindow(of: pid)
    }

    private func attachAXObserver(to pid: pid_t) {
        detachAXObserver()
        var created: AXObserver?
        guard AXObserverCreate(pid, focusEngineAXCallback, &created) == .success, let observer = created else { return }
        let app = AX.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success else { return }
        for notification in [kAXMainWindowChangedNotification, kAXWindowMovedNotification] {
            AXObserverAddNotification(observer, app, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPID = pid
    }

    private func detachAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedPID = 0
    }

    private func window(onDisplay display: CGDirectDisplayID) -> TrackedWindow? {
        if let tracked = lastWindows[display] {
            let app = NSRunningApplication(processIdentifier: tracked.pid)
            if app?.isTerminated == false, app?.isHidden == false,
               AX.bool(tracked.element, kAXMinimizedAttribute) != true,
               let frame = AX.frame(tracked.element),
               WindowLocator.isOnScreen(frame: frame, pid: tracked.pid),
               WindowLocator.display(containing: CGPoint(x: frame.midX, y: frame.midY)) == display {
                return tracked
            }
            lastWindows[display] = nil
        }
        guard let info = WindowLocator.topmostWindow(onDisplay: display, excluding: ownPID),
              let element = WindowLocator.axWindow(for: info) else { return nil }
        let name = NSRunningApplication(processIdentifier: info.pid)?.localizedName ?? ""
        return TrackedWindow(element: element, pid: info.pid, appName: name)
    }

    private func isFocused(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AX.focusedWindow(pid) else { return false }
        return CFEqual(focused, window)
    }

    private func activate(_ window: AXUIElement, pid: pid_t) {
        AX.raise(window)
        AX.set(window, kAXMainAttribute, kCFBooleanTrue)
        AX.set(AX.application(pid), kAXFrontmostAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private func warpPointer(to cgPoint: CGPoint, unlessWithin area: CGRect) {
        if let current = CGEvent(source: nil)?.location, area.contains(current) { return }
        CGWarpMouseCursorPosition(cgPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

private func focusEngineAXCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    let engine = Unmanaged<FocusEngine>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { engine.recordFocusedWindow(of: pid) }
}
