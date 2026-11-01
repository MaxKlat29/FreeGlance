import AppKit

@MainActor
final class CalibrationController {
    struct Spot: Equatable {
        var point: CGPoint
        var displayID: CGDirectDisplayID
    }

    private static let moveDuration: TimeInterval = 0.45
    private static let holdDuration: TimeInterval = 1.5
    private static let discardDuration: TimeInterval = 0.4
    private static let keyboardPrompt = "Now look at your keyboard the way you do while typing. Hold for 3 seconds."
    private static let keyboardReadDuration: TimeInterval = 1.5
    private static let keyboardHoldSeconds = 3
    private static let keyboardDiscardDuration: TimeInterval = 0.5
    private static let dotDiameter: CGFloat = 28

    private final class OverlayWindow: NSWindow {
        var onKeyDown: ((UInt16) -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func keyDown(with event: NSEvent) { onKeyDown?(event.keyCode) }
    }

    private struct Overlay {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let window: OverlayWindow
        let dot: CALayer
        let label: NSTextField
    }

    private var overlays: [Overlay] = []
    private var spots: [Spot] = []
    private var samples: [CalibrationSample] = []
    private var heldSpot: Spot?
    private var collectFrom: TimeInterval = 0
    private var runTask: Task<Void, Never>?
    private var completion: (([CalibrationSample]?) -> Void)?

    private(set) var isRunning = false

    /// Shows the overlay and waits for Space. Completion receives the samples, or nil when cancelled.
    func start(completion: @escaping ([CalibrationSample]?) -> Void) {
        guard !isRunning else { return }
        let screens = NSScreen.screens.compactMap { screen in screenID(screen).map { (id: $0, frame: screen.frame) } }
        guard !screens.isEmpty else {
            completion(nil)
            return
        }
        isRunning = true
        self.completion = completion
        samples = []
        heldSpot = nil
        spots = Self.makeSpots(for: screens.map { DisplayInfo(id: $0.id, frame: $0.frame, name: "") })
        overlays = screens.map { makeOverlay(displayID: $0.id, frame: $0.frame) }

        NSApp.activate()
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        let main = overlays.first { $0.frame == NSScreen.main?.frame } ?? overlays[0]
        main.window.makeKey()
    }

    func feed(_ features: GazeFeatures) {
        guard let heldSpot, now() >= collectFrom else { return }
        samples.append(CalibrationSample(features: features, point: heldSpot.point, displayID: heldSpot.displayID, weight: 1))
    }

    func cancel() {
        guard isRunning else { return }
        finish(with: nil)
    }

    static func makeSpots(for displays: [DisplayInfo]) -> [Spot] {
        let fractions: [CGFloat] = [0.1, 0.5, 0.9]
        let edgeFractions: [CGFloat] = [0.25, 0.5, 0.75]
        var perDisplay: [CGDirectDisplayID: [Spot]] = [:]

        for display in displays {
            let f = display.frame
            var grid: [Spot] = []
            for (row, fy) in fractions.reversed().enumerated() {
                let columns = row.isMultiple(of: 2) ? fractions : fractions.reversed()
                for fx in columns {
                    grid.append(Spot(point: CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy), displayID: display.id))
                }
            }
            perDisplay[display.id] = grid
        }

        for (i, a) in displays.enumerated() {
            for b in displays[(i + 1)...] {
                for (k, t) in edgeFractions.enumerated() {
                    guard let spot = edgeSpot(a, b, t: t, onA: k != 1) else { break }
                    perDisplay[spot.displayID, default: []].append(spot)
                }
            }
        }

        return displays.flatMap { perDisplay[$0.id] ?? [] }
    }

    private static func edgeSpot(_ a: DisplayInfo, _ b: DisplayInfo, t: CGFloat, onA: Bool) -> Spot? {
        let tolerance: CGFloat = 2
        let inset: CGFloat = 0.04
        let fa = a.frame, fb = b.frame
        let id = onA ? a.id : b.id
        let yLow = max(fa.minY, fb.minY), yHigh = min(fa.maxY, fb.maxY)
        let xLow = max(fa.minX, fb.minX), xHigh = min(fa.maxX, fb.maxX)
        let y = yLow + (yHigh - yLow) * t
        let x = xLow + (xHigh - xLow) * t

        if yHigh > yLow, abs(fa.maxX - fb.minX) <= tolerance {
            return Spot(point: CGPoint(x: onA ? fa.maxX - fa.width * inset : fb.minX + fb.width * inset, y: y), displayID: id)
        }
        if yHigh > yLow, abs(fa.minX - fb.maxX) <= tolerance {
            return Spot(point: CGPoint(x: onA ? fa.minX + fa.width * inset : fb.maxX - fb.width * inset, y: y), displayID: id)
        }
        if xHigh > xLow, abs(fa.maxY - fb.minY) <= tolerance {
            return Spot(point: CGPoint(x: x, y: onA ? fa.maxY - fa.height * inset : fb.minY + fb.height * inset), displayID: id)
        }
        if xHigh > xLow, abs(fa.minY - fb.maxY) <= tolerance {
            return Spot(point: CGPoint(x: x, y: onA ? fa.minY + fa.height * inset : fb.maxY - fb.height * inset), displayID: id)
        }
        return nil
    }

    private func run() async {
        for (index, spot) in spots.enumerated() {
            heldSpot = nil
            show(spot, index: index)
            guard await pause(Self.moveDuration) else { return }
            collectFrom = now() + Self.discardDuration
            heldSpot = spot
            shrinkDot(on: spot.displayID)
            guard await pause(Self.holdDuration) else { return }
        }
        heldSpot = nil
        guard await holdKeyboard() else { return }
        finish(with: samples)
    }

    /// Keyboard pose: samples labelled `awayDisplayID` teach the away classifier what "looking down" is.
    /// The prompt stays readable for a moment before collection, so reading frames are not labelled away.
    private func holdKeyboard() async -> Bool {
        for overlay in overlays {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.dot.isHidden = true
            CATransaction.commit()
            overlay.label.stringValue = Self.keyboardPrompt
        }
        guard await pause(Self.keyboardReadDuration) else { return false }
        collectFrom = now() + Self.keyboardDiscardDuration
        heldSpot = Spot(point: .zero, displayID: CalibrationSample.awayDisplayID)
        for remaining in stride(from: Self.keyboardHoldSeconds, to: 0, by: -1) {
            for overlay in overlays { overlay.label.stringValue = "\(Self.keyboardPrompt)\n\(remaining)" }
            guard await pause(1) else { return false }
        }
        heldSpot = nil
        return true
    }

    private func pause(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return isRunning
        } catch {
            return false
        }
    }

    private func handleKey(_ keyCode: UInt16) {
        switch keyCode {
        case 53:
            cancel()
        case 49 where runTask == nil:
            for overlay in overlays { overlay.label.stringValue = "Follow the dot. Esc cancels." }
            runTask = Task { await run() }
        default:
            break
        }
    }

    private func show(_ spot: Spot, index: Int) {
        for overlay in overlays {
            let local = CGPoint(x: spot.point.x - overlay.frame.minX, y: spot.point.y - overlay.frame.minY)
            let active = overlay.displayID == spot.displayID
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.moveDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            if active, !overlay.dot.isHidden {
                overlay.dot.position = local
            } else {
                CATransaction.setDisableActions(true)
                overlay.dot.position = local
                overlay.dot.isHidden = !active
            }
            overlay.dot.transform = CATransform3DIdentity
            CATransaction.commit()
            overlay.label.stringValue = "Spot \(index + 1) of \(spots.count). Esc cancels."
        }
    }

    private func shrinkDot(on displayID: CGDirectDisplayID) {
        guard let overlay = overlays.first(where: { $0.displayID == displayID }) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.holdDuration)
        overlay.dot.transform = CATransform3DMakeScale(0.45, 0.45, 1)
        CATransaction.commit()
    }

    private func finish(with result: [CalibrationSample]?) {
        isRunning = false
        runTask?.cancel()
        runTask = nil
        heldSpot = nil
        for overlay in overlays { overlay.window.orderOut(nil) }
        overlays = []
        spots = []
        samples = []
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    private func makeOverlay(displayID: CGDirectDisplayID, frame: CGRect) -> Overlay {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.onKeyDown = { [weak self] keyCode in self?.handleKey(keyCode) }

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true

        let label = NSTextField(wrappingLabelWithString: "Look at the dot the way you normally would — head and eyes. Press Space to start.")
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -frame.height * 0.2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: min(720, frame.width * 0.8)),
        ])

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dot.cornerRadius = Self.dotDiameter / 2
        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.borderColor = NSColor.white.cgColor
        dot.borderWidth = 3
        dot.isHidden = true
        view.layer?.addSublayer(dot)

        window.contentView = view
        return Overlay(displayID: displayID, frame: frame, window: window, dot: dot, label: label)
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
