import AppKit
import ApplicationServices

struct WindowInfo: Sendable, Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect
}

enum WindowLocator {
    private static let matchTolerance: CGFloat = 4

    static var primaryHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func appKitRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1 else { return nil }
            return WindowInfo(windowID: number, pid: pid, bounds: bounds)
        }
    }

    static func topmostWindow(at cgPoint: CGPoint, excluding pid: pid_t? = nil) -> WindowInfo? {
        onScreenWindows().first { $0.pid != pid && $0.bounds.contains(cgPoint) }
    }

    /// Front-to-back hit test across all layers, so overlays such as banners, menus or the Dock count.
    /// Non-zero-layer windows of `ownPID` (click-through overlays) are skipped.
    static func topmostWindowAnyLayer(at cgPoint: CGPoint, ownPID: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !(pid == ownPID && layer != 0),
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint) else { continue }
            return number
        }
        return nil
    }

    static func isOnScreen(frame: CGRect, pid: pid_t) -> Bool {
        onScreenWindows().contains { info in
            info.pid == pid
                && abs(info.bounds.minX - frame.minX) <= matchTolerance
                && abs(info.bounds.minY - frame.minY) <= matchTolerance
                && abs(info.bounds.width - frame.width) <= matchTolerance
                && abs(info.bounds.height - frame.height) <= matchTolerance
        }
    }

    static func topmostWindow(onDisplay display: CGDirectDisplayID, excluding pid: pid_t? = nil) -> WindowInfo? {
        let bounds = CGDisplayBounds(display)
        return onScreenWindows().first { info in
            info.pid != pid && bounds.contains(CGPoint(x: info.bounds.midX, y: info.bounds.midY))
        }
    }

    static func axWindow(for info: WindowInfo) -> AXUIElement? {
        var best: (element: AXUIElement, error: CGFloat)?
        for window in AX.windows(info.pid) {
            guard let frame = AX.frame(window) else { continue }
            let error = abs(frame.minX - info.bounds.minX) + abs(frame.minY - info.bounds.minY)
                + abs(frame.width - info.bounds.width) + abs(frame.height - info.bounds.height)
            if error <= matchTolerance * 4, error < (best?.error ?? .infinity) {
                best = (window, error)
            }
        }
        return best?.element
    }

    static func display(containing cgPoint: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(cgPoint, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }
}
