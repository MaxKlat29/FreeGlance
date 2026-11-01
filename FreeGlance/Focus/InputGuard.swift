import Foundation
import CoreGraphics

struct InputGuard {
    static let mouseLockout: TimeInterval = 1.5

    private static let keyTypes: [CGEventType] = [.keyDown, .flagsChanged]
    private static let motionTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]
    private static let buttonTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    static func secondsSinceKey() -> Double {
        seconds(since: keyTypes, state: .combinedSessionState)
    }

    // Button presses come from HID state so the synthetic click fallback does not lock focus out.
    static func secondsSinceMouse() -> Double {
        min(seconds(since: motionTypes, state: .combinedSessionState), seconds(since: buttonTypes, state: .hidSystemState))
    }

    private static func seconds(since types: [CGEventType], state: CGEventSourceStateID) -> Double {
        types.map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }.min() ?? .infinity
    }
}
