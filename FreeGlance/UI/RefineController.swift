import AppKit

/// Refine mode: a dot appears at a grid point (`RefineSchedule`), the user fixates it and presses Space.
/// The frames of that moment become refine samples labelled with the dot, the model is refit off the
/// main thread, and the overlay shows the prediction before (ring) and after (filled marker, with the
/// residual correction) the update.
/// Esc ends it and hands back the refined calibration.
@MainActor
final class RefineController {
    private static let instruction = "Look at the dot and press Space while looking at it. Esc finishes."
    private static let goodRoundMessage = "Looks good. Esc to finish, Space to continue."
    private static let collectDuration: TimeInterval = 0.8
    private static let discardDuration: TimeInterval = 0.15
    private static let minimumFrames = 8
    private static let feedbackDuration: TimeInterval = 0.9
    private static let recentCount = 5
    /// A round averaging less than this error is good enough to stop.
    private static let goodRoundCm = 1.5
    /// Assumed density when a display does not report its physical size (roughly a 27" 1440p screen).
    private static let fallbackPointsPerMillimetre = 4.0
    private static let dotDiameter: CGFloat = 22
    private static let centreDiameter: CGFloat = 6
    private static let markerDiameter: CGFloat = 10
    private static let edgeInset: CGFloat = 12

    private final class OverlayWindow: NSWindow {
        var onKeyDown: ((UInt16) -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        /// Repeats are ignored: a held Space would start the next point before the eyes reach its dot.
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            onKeyDown?(event.keyCode)
        }
    }

    private struct Overlay {
        let display: DisplayInfo
        let window: OverlayWindow
        let header: NSTextField
        let label: NSTextField
        let dot: CALayer
        let ring: CAShapeLayer
        let line: CAShapeLayer
        let marker: CALayer
        let beforeText: CATextLayer
        let afterText: CATextLayer
    }

    private let displays: [DisplayInfo]
    private let clickSamples: [CalibrationSample]
    private var calibration: Calibration
    private var model: GazeModel
    private var schedule: RefineSchedule
    private var overlays: [Overlay] = []
    private var frames: [GazeFeatures] = []
    private var collectWindow: ClosedRange<TimeInterval>?
    private var pointTask: Task<Void, Never>?
    private var refined = false
    private var completion: ((Calibration?) -> Void)?

    private(set) var isRunning = false

    /// `model` is the current model of `calibration` plus `clickSamples`; refits keep the clicks.
    init(calibration: Calibration, model: GazeModel, clickSamples: [CalibrationSample], displays: [DisplayInfo]) {
        self.calibration = calibration
        self.model = model
        self.clickSamples = clickSamples
        self.displays = displays
        schedule = RefineSchedule(displays: displays, seed: UInt64(Date().timeIntervalSince1970))
    }

    /// Shows the first dot. `completion` gets the refined calibration, nil when no point was added.
    func start(completion: @escaping (Calibration?) -> Void) {
        guard !isRunning, schedule.current != nil else {
            completion(nil)
            return
        }
        isRunning = true
        self.completion = completion
        overlays = displays.map(makeOverlay)
        NSApp.activate()
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        let main = overlays.first { $0.display.frame == NSScreen.main?.frame } ?? overlays[0]
        main.window.makeKey()
        showTarget(message: Self.instruction)
    }

    func feed(_ features: GazeFeatures) {
        guard let collectWindow, collectWindow.contains(features.timestamp) else { return }
        frames.append(features)
    }

    /// Ends Refine mode, keeping every point measured so far.
    func finish() {
        guard isRunning else { return }
        isRunning = false
        pointTask?.cancel()
        pointTask = nil
        collectWindow = nil
        for overlay in overlays { overlay.window.orderOut(nil) }
        overlays = []
        let completion = completion
        self.completion = nil
        completion?(refined ? calibration : nil)
    }

    /// Collects the frames of one fixation, then shows the error before and after the refit.
    private func measure() async {
        guard let target = schedule.current, let overlay = overlays.first(where: { $0.display.id == target.displayID })
        else { return }
        overlay.label.stringValue = ""
        frames = []
        let start = now()
        collectWindow = (start + Self.discardDuration)...(start + Self.collectDuration)
        guard await pause(Self.collectDuration) else { return }
        collectWindow = nil
        let frames = frames
        guard frames.count >= Self.minimumFrames else {
            overlay.label.stringValue = "Face not found, try again"
            return
        }

        let before = ResidualCorrection.median(frames.map { model.refinedPoint($0, on: target.displayID) })
        let errorBefore = centimetres(from: before, to: target.point, on: overlay.display)
        showBefore(before, error: errorBefore, target: target.point, on: overlay)

        calibration.addRefinePoint(target, frames: frames)
        refined = true
        let snapshot = calibration
        let clicks = clickSamples
        let updated = await Task.detached(priority: .userInitiated) { snapshot.model(adding: clicks) }.value
        guard isRunning else { return }
        if let updated {
            model = updated
            let after = ResidualCorrection.median(frames.map { updated.refinedPoint($0, on: target.displayID) })
            showAfter(after, error: centimetres(from: after, to: target.point, on: overlay.display), on: overlay)
        }
        guard await pause(Self.feedbackDuration) else { return }

        let roundMean = schedule.complete(error: errorBefore)
        hideFeedback()
        showTarget(message: roundMean.map { $0 < Self.goodRoundCm } == true ? Self.goodRoundMessage : "")
    }

    private func showTarget(message: String) {
        guard let target = schedule.current else { return }
        let name = displays.first { $0.id == target.displayID }?.name ?? ""
        var header = "Point \(schedule.history.count + 1)"
        if let recent = schedule.recentMean(Self.recentCount) {
            header += String(format: " · avg error %.1f cm (last %d)", recent, min(Self.recentCount, schedule.history.count))
        }
        for overlay in overlays {
            let isTarget = overlay.display.id == target.displayID
            overlay.header.stringValue = isTarget ? header : ""
            overlay.label.stringValue = isTarget ? message : "Look at \(name): the dot is there. Esc finishes."
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.dot.isHidden = !isTarget
            overlay.dot.position = local(target.point, in: overlay)
            CATransaction.commit()
        }
    }

    private func showBefore(_ point: CGPoint, error: Double, target: CGPoint, on overlay: Overlay) {
        let p = clamped(local(point, in: overlay), in: overlay)
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: CGRect(x: p.x - Self.dotDiameter / 2, y: p.y - Self.dotDiameter / 2,
                                       width: Self.dotDiameter, height: Self.dotDiameter))
        let linePath = CGMutablePath()
        linePath.move(to: p)
        linePath.addLine(to: local(target, in: overlay))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.ring.path = ringPath
        overlay.line.path = linePath
        overlay.ring.isHidden = false
        overlay.line.isHidden = false
        place(overlay.beforeText, String(format: "%.1f cm", error), at: p, in: overlay)
        CATransaction.commit()
    }

    private func showAfter(_ point: CGPoint, error: Double, on overlay: Overlay) {
        let p = clamped(local(point, in: overlay), in: overlay)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.marker.position = p
        overlay.marker.isHidden = false
        place(overlay.afterText, String(format: "→ %.1f cm", error), at: p, in: overlay)
        CATransaction.commit()
    }

    private func hideFeedback() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for overlay in overlays {
            for layer in [overlay.ring, overlay.line, overlay.marker, overlay.beforeText, overlay.afterText] as [CALayer] {
                layer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// Text beside `p`, on its left when it would run off the screen.
    private func place(_ text: CATextLayer, _ string: String, at p: CGPoint, in overlay: Overlay) {
        let size = CGSize(width: 110, height: 20)
        let x = p.x + 16 + size.width > overlay.display.frame.width ? p.x - 16 - size.width : p.x + 16
        text.string = string
        text.alignmentMode = x < p.x ? .right : .left
        text.frame = CGRect(origin: CGPoint(x: x, y: p.y - size.height / 2), size: size)
        text.isHidden = false
    }

    private func centimetres(from a: CGPoint, to b: CGPoint, on display: DisplayInfo) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y)) / (display.pointsPerMillimetre ?? Self.fallbackPointsPerMillimetre) / 10
    }

    private func local(_ p: CGPoint, in overlay: Overlay) -> CGPoint {
        CGPoint(x: p.x - overlay.display.frame.minX, y: p.y - overlay.display.frame.minY)
    }

    /// A prediction off the target's screen still shows, at its edge.
    private func clamped(_ p: CGPoint, in overlay: Overlay) -> CGPoint {
        let size = overlay.display.frame.size
        return CGPoint(x: min(max(p.x, Self.edgeInset), size.width - Self.edgeInset),
                       y: min(max(p.y, Self.edgeInset), size.height - Self.edgeInset))
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
            finish()
        case 49 where pointTask == nil:
            pointTask = Task {
                await measure()
                pointTask = nil
            }
        default:
            break
        }
    }

    private func makeOverlay(_ display: DisplayInfo) -> Overlay {
        let frame = display.frame
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.onKeyDown = { [weak self] keyCode in self?.handleKey(keyCode) }

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let scale = window.backingScaleFactor

        let header = textField(size: 18)
        let label = textField(size: 22)
        view.addSubview(header)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -frame.height * 0.2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: min(720, frame.width * 0.8)),
        ])

        let line = CAShapeLayer()
        line.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        line.lineWidth = 1
        line.isHidden = true

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dot.cornerRadius = Self.dotDiameter / 2
        dot.backgroundColor = NSColor.white.cgColor
        dot.borderColor = NSColor.systemRed.cgColor
        dot.borderWidth = 3
        dot.isHidden = true
        let centre = CALayer()
        centre.bounds = CGRect(x: 0, y: 0, width: Self.centreDiameter, height: Self.centreDiameter)
        centre.cornerRadius = Self.centreDiameter / 2
        centre.backgroundColor = NSColor.black.cgColor
        centre.position = CGPoint(x: Self.dotDiameter / 2, y: Self.dotDiameter / 2)
        dot.addSublayer(centre)

        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = NSColor.systemOrange.cgColor
        ring.lineWidth = 2.5
        ring.isHidden = true

        let marker = CALayer()
        marker.bounds = CGRect(x: 0, y: 0, width: Self.markerDiameter, height: Self.markerDiameter)
        marker.cornerRadius = Self.markerDiameter / 2
        marker.backgroundColor = NSColor.systemGreen.cgColor
        marker.isHidden = true

        let beforeText = textLayer(color: .systemOrange, scale: scale)
        let afterText = textLayer(color: .systemGreen, scale: scale)
        for layer in [line, dot, ring, marker, beforeText, afterText] as [CALayer] {
            view.layer?.addSublayer(layer)
        }

        window.contentView = view
        return Overlay(display: display, window: window, header: header, label: label, dot: dot, ring: ring,
                       line: line, marker: marker, beforeText: beforeText, afterText: afterText)
    }

    private func textField(size: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.alignment = .center
        field.textColor = .white
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func textLayer(color: NSColor, scale: CGFloat) -> CATextLayer {
        let text = CATextLayer()
        text.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        text.fontSize = 15
        text.foregroundColor = color.cgColor
        text.contentsScale = scale
        text.isHidden = true
        return text
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
