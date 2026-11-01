import AppKit
import ApplicationServices

struct PaneKey: Hashable {
    struct Rect: Hashable {
        let x, y, width, height: Int

        init(_ frame: CGRect) {
            func snap(_ value: CGFloat) -> Int { Int((value / 8).rounded()) * 8 }
            x = snap(frame.minX)
            y = snap(frame.minY)
            width = snap(frame.width)
            height = snap(frame.height)
        }
    }

    let windowID: CGWindowID
    let pane: Rect?

    private static let lookupTimeout: Float = 0.05
    private static let windowListMaxAge: TimeInterval = 0.25
    @MainActor private static var windowCache: (time: TimeInterval, windows: [WindowInfo])?

    @MainActor
    static func at(_ point: CGPoint) -> PaneKey? {
        let cgPoint = WindowLocator.cgPoint(fromAppKit: point)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let window = windows().first(where: { $0.pid != ownPID && $0.bounds.contains(cgPoint) }) else { return nil }
        guard PaneFocuser.isSupported(NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier) else {
            return PaneKey(windowID: window.windowID, pane: nil)
        }
        let pane = PaneFocuser.panes(pid: window.pid, at: cgPoint, timeout: lookupTimeout).first
        return PaneKey(windowID: window.windowID, pane: pane.map { Rect($0.frame) })
    }

    @MainActor
    private static func windows() -> [WindowInfo] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = windowCache, now - cache.time < windowListMaxAge { return cache.windows }
        let windows = WindowLocator.onScreenWindows()
        windowCache = (now, windows)
        return windows
    }
}
