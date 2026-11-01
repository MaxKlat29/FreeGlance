import AppKit
import ApplicationServices

@MainActor
final class PaneFocuser {
    static let supportedBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.vscodium",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.apple.dt.Xcode",
        "com.google.android.studio",
    ]

    static let electronBundleIDs: Set<String> = [
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.vscodium",
    ]

    static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    struct Pane {
        let element: AXUIElement
        let frame: CGRect
    }

    nonisolated static let syntheticEventMarker: Int64 = 0x4647_4C41

    nonisolated static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    private static let minPaneSize = CGSize(width: 120, height: 80)
    private static let maxDepth = 40
    private static let maxCandidates = 4
    private static let paneRoles: Set<String> = ["AXTextArea", "AXScrollArea", "AXWebArea"]
    private static let containerRoles: Set<String> = ["AXGroup", "AXTextArea", "AXScrollArea", "AXWebArea", "AXSplitGroup"]
    private static let stopRoles: Set<String> = [kAXWindowRole, kAXApplicationRole]
    private static let nodeAttributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute]

    private var manualAccessibilityPIDs: Set<pid_t> = []

    /// Pane-like ancestors of the element under `cgPoint`, smallest first.
    static func panes(pid: pid_t, at cgPoint: CGPoint, timeout: Float? = nil) -> [Pane] {
        let app = AX.application(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(cgPoint.x), Float(cgPoint.y), &hit) == .success else { return [] }
        var result: [Pane] = []
        var element = hit
        var childRole: String?
        for _ in 0..<maxDepth {
            guard let current = element, result.count < maxCandidates else { break }
            if let timeout { AXUIElementSetMessagingTimeout(current, timeout) }
            let values = AX.values(current, nodeAttributes)
            let role = values[0] as? String
            if let role, stopRoles.contains(role) { break }
            if let frame = AX.rect(position: values[1], size: values[2]),
               frame.width >= minPaneSize.width, frame.height >= minPaneSize.height,
               isPaneLike(current, role: role, childRole: childRole) {
                result.append(Pane(element: current, frame: frame))
            }
            childRole = role
            element = AX.asElement(values[3])
        }
        return result
    }

    private static func isPaneLike(_ element: AXUIElement, role: String?, childRole: String?) -> Bool {
        guard let role else { return false }
        if paneRoles.contains(role) { return true }
        guard role == "AXGroup" else { return false }
        if let childRole, containerRoles.contains(childRole) { return false }
        return !AX.children(element).contains { child in AX.role(child).map(containerRoles.contains) ?? false }
    }

    func enableManualAccessibility(pid: pid_t) {
        guard !manualAccessibilityPIDs.contains(pid),
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              Self.electronBundleIDs.contains(bundleID),
              AX.set(AX.application(pid), "AXManualAccessibility", kCFBooleanTrue) else { return }
        manualAccessibilityPIDs.insert(pid)
    }

    @discardableResult
    func focusPane(pid: pid_t, windowID: CGWindowID, at cgPoint: CGPoint, clickFallback: Bool) -> Bool {
        guard Self.isSupported(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else { return false }
        enableManualAccessibility(pid: pid)

        let candidates = Self.panes(pid: pid, at: cgPoint)
        guard let smallest = candidates.first else { return false }
        let target = candidates.first { AX.isSettable($0.element, kAXFocusedAttribute) } ?? smallest

        if let focused = AX.focusedElement(pid), AX.isDescendant(focused, of: target.element) { return true }

        if AX.set(target.element, kAXFocusedAttribute, kCFBooleanTrue), isFocused(target.element, pid: pid) {
            return true
        }
        guard clickFallback else { return false }
        return click(at: CGPoint(x: target.frame.midX, y: target.frame.midY), windowID: windowID)
    }

    private func isFocused(_ element: AXUIElement, pid: pid_t) -> Bool {
        if AX.bool(element, kAXFocusedAttribute) == true { return true }
        guard let focused = AX.focusedElement(pid) else { return false }
        return AX.isDescendant(focused, of: element)
    }

    private func click(at cgPoint: CGPoint, windowID: CGWindowID) -> Bool {
        guard WindowLocator.topmostWindowAnyLayer(at: cgPoint, ownPID: getpid()) == windowID else { return false }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: cgPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: cgPoint, mouseButton: .left)
        else { return false }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
