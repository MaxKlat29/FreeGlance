import AppKit

/// Click-through eye tracker dot: accent while tracking a screen, grey while looking away
/// (pinned to the nearest screen edge), dimmed at the last position while paused.
@MainActor
final class GazeDotOverlay {
    private static let diameter: CGFloat = 22
    private static let moveDuration: TimeInterval = 0.08

    private enum Style { case tracking, away, paused }

    private struct Entry {
        let frame: CGRect
        let window: NSWindow
        let dot: CALayer
    }

    private var entries: [Entry] = []
    private var lastPoint: CGPoint?
    private var lastAway = false

    func show(at point: CGPoint, away: Bool) {
        lastPoint = point
        lastAway = away
        render(point, style: away ? .away : .tracking)
    }

    func showPaused() {
        guard let lastPoint else { return }
        render(lastPoint, style: .paused)
    }

    func hide() {
        for entry in entries { entry.window.orderOut(nil) }
    }

    private func render(_ point: CGPoint, style: Style) {
        rebuildIfNeeded()
        var target = entries.firstIndex { $0.frame.contains(point) }
        var position = point
        if target == nil, style != .tracking, let nearest = entries.indices.min(by: {
            Self.distance(point, entries[$0].frame) < Self.distance(point, entries[$1].frame)
        }) {
            target = nearest
            position = Self.clamp(point, into: entries[nearest].frame)
        }
        for (index, entry) in entries.enumerated() {
            let inside = index == target
            let glide = inside && !entry.dot.isHidden && entry.window.isVisible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.dot.isHidden = !inside
            if inside {
                Self.apply(style == .paused && lastAway ? .away : style, to: entry.dot)
                entry.dot.opacity = style == .paused ? 0.35 : 1
            }
            CATransaction.commit()
            if inside {
                // A visible dot glides to the next point instead of teleporting.
                CATransaction.begin()
                CATransaction.setDisableActions(!glide)
                CATransaction.setAnimationDuration(Self.moveDuration)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                entry.dot.position = CGPoint(x: position.x - entry.frame.minX, y: position.y - entry.frame.minY)
                CATransaction.commit()
            }
            if inside, !entry.window.isVisible { entry.window.orderFrontRegardless() }
        }
    }

    private static func apply(_ style: Style, to dot: CALayer) {
        let color: NSColor = style == .away ? .systemGray : .controlAccentColor
        dot.backgroundColor = color.withAlphaComponent(0.6).cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
    }

    private static func clamp(_ p: CGPoint, into frame: CGRect) -> CGPoint {
        let inset = frame.insetBy(dx: diameter, dy: diameter)
        return CGPoint(x: min(max(p.x, inset.minX), inset.maxX), y: min(max(p.y, inset.minY), inset.maxY))
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
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
        dot.borderWidth = 1.5
        dot.isHidden = true
        view.layer?.addSublayer(dot)
        window.contentView = view

        return Entry(frame: screen.frame, window: window, dot: dot)
    }
}
