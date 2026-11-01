import AppKit
import ApplicationServices

enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func values(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &result) == .success,
              let array = result as [AnyObject]?, array.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        return array.map { item in
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        asElement(value(element, attribute))
    }

    static func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func asElements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { asElement($0) }
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        asElements(value(element, kAXChildrenAttribute))
    }

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        asElements(value(application(pid), kAXWindowsAttribute))
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        self.element(element, kAXParentAttribute)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let pair = values(element, [kAXPositionAttribute, kAXSizeAttribute])
        return rect(position: pair[0], size: pair[1])
    }

    static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    @discardableResult
    static func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        element(application(pid), kAXFocusedWindowAttribute)
    }

    static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        element(application(pid), kAXFocusedUIElementAttribute)
    }

    static func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement, maxDepth: Int = 40) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<maxDepth {
            guard let node = current else { return false }
            if CFEqual(node, ancestor) { return true }
            current = parent(node)
        }
        return false
    }
}
