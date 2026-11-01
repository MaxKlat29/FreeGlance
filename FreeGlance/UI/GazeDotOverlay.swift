import AppKit

@MainActor
final class GazeDotOverlay {
    private static let diameter: CGFloat = 18

    private struct Entry {
        let frame: CGRect
        let window: NSWindow
        let dot: CALayer
    }

    private var entries: [Entry] = []

    func show(at point: CGPoint) {
        rebuildIfNeeded()
        for entry in entries {
            let inside = entry.frame.contains(point)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.dot.isHidden = !inside
            if inside {
                entry.dot.position = CGPoint(x: point.x - entry.frame.minX, y: point.y - entry.frame.minY)
            }
            CATransaction.commit()
            if inside, !entry.window.isVisible { entry.window.orderFrontRegardless() }
        }
    }

    func hide() {
        for entry in entries { entry.window.orderOut(nil) }
    }

    private func rebuildIfNeeded() {
        let frames = NSScreen.screens.map(\.frame)
        guard frames != entries.map(\.frame) else { return }
        hide()
        entries = NSScreen.screens.map(makeEntry)
    }

    private func makeEntry(for screen: NSScreen) -> Entry {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        dot.cornerRadius = Self.diameter / 2
        dot.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        dot.borderWidth = 1
        dot.isHidden = true
        view.layer?.addSublayer(dot)
        window.contentView = view

        return Entry(frame: screen.frame, window: window, dot: dot)
    }
}
