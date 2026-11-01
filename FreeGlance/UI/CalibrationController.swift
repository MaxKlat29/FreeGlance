import AppKit

/// Smooth-pursuit calibration: per display a ball slowly traverses the whole screen, once followed
/// with head and eyes, once with the eyes only. Every face frame is recorded against the ball's
/// trajectory; `CalibrationFit` then picks eye latency and ridge strengths. A keyboard pose ends it.
@MainActor
final class CalibrationController {
    enum Outcome {
        case cancelled
        /// Too little usable face data, or a display without samples.
        case failed
        case calibrated(Calibration)
    }

    enum Pass: CaseIterable {
        case headAndEyes
        /// Head held still, only the eyes follow: decorrelates eye from head features.
        case eyesOnly

        var rows: Int { self == .headAndEyes ? 4 : 3 }

        var prompt: String {
            switch self {
            case .headAndEyes: "Follow the ball with your head and eyes, as you naturally would."
            case .eyesOnly: "Face the centre of this screen, keep your head still and follow the ball with your eyes only."
            }
        }
    }

    private static let readDuration: TimeInterval = 2
    /// Ball speed on screen, millimetres per second; `fallbackSpeed` points per second when the size is unknown.
    private static let ballSpeedMM = 110.0
    private static let fallbackSpeed = 300.0
    private static let resultDuration: TimeInterval = 3
    private static let keyboardPrompt = "Now look at your keyboard the way you do while typing. Hold for 3 seconds."
    private static let keyboardReadDuration: TimeInterval = 1.5
    private static let keyboardHoldSeconds = 3
    private static let keyboardDiscardDuration: TimeInterval = 0.5
    private static let ballDiameter: CGFloat = 26
    private static let centreDiameter: CGFloat = 6

    private final class OverlayWindow: NSWindow {
        var onKeyDown: ((UInt16) -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func keyDown(with event: NSEvent) { onKeyDown?(event.keyCode) }
    }

    /// Display link target: moves the ball once per screen refresh (the link runs on the main run loop).
    @MainActor
    private final class Ticker: NSObject {
        let tick: () -> Void
        init(_ tick: @escaping () -> Void) { self.tick = tick }
        @objc func step(_ link: CADisplayLink) { tick() }
    }

    private struct Overlay {
        let display: DisplayInfo
        let window: OverlayWindow
        let ball: CALayer
        let label: NSTextField
    }

    private var overlays: [Overlay] = []
    private var traces: [PursuitTrace] = []
    private var activeTrace: PursuitTrace?
    private var displayLink: CADisplayLink?
    private var keyboardSamples: [CalibrationSample] = []
    private var collectingKeyboard = false
    private var collectFrom: TimeInterval = 0
    private var runTask: Task<Void, Never>?
    private var fitTask: Task<CalibrationFit?, Never>?
    /// Set while the result shows; Esc then only closes it early instead of discarding the calibration.
    private var pendingOutcome: Outcome?
    private var completion: ((Outcome) -> Void)?

    private(set) var isRunning = false

    /// Shows the overlay and waits for Space.
    func start(completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        let displays = NSScreen.screens.compactMap { screen in
            screenID(screen).map { DisplayInfo(id: $0, frame: screen.frame, name: screen.localizedName) }
        }
        guard !displays.isEmpty else {
            completion(.cancelled)
            return
        }
        isRunning = true
        self.completion = completion
        traces = []
        keyboardSamples = []
        overlays = displays.map(makeOverlay)

        NSApp.activate()
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        let main = overlays.first { $0.display.frame == NSScreen.main?.frame } ?? overlays[0]
        main.window.makeKey()
    }

    func feed(_ features: GazeFeatures) {
        activeTrace?.record(features)
        if collectingKeyboard, now() >= collectFrom {
            keyboardSamples.append(CalibrationSample(features: features, point: .zero,
                                                     displayID: CalibrationSample.awayDisplayID, weight: 1))
        }
    }

    func cancel() {
        guard isRunning else { return }
        finish(with: pendingOutcome ?? .cancelled)
    }

    private func run() async {
        for overlay in overlays {
            for pass in Pass.allCases {
                guard await pursue(on: overlay, pass) else { return }
            }
        }
        guard await holdKeyboard() else { return }
        setLabels("Computing calibration…")
        let traces = traces
        let fitTask = Task.detached(priority: .userInitiated) { CalibrationFit(traces: traces) }
        self.fitTask = fitTask
        let fit = await fitTask.value
        self.fitTask = nil
        guard isRunning else { return }
        let calibration = makeCalibration(fit)
        if let calibration {
            let error = calibration.typicalErrorCm.map { String(format: "%.1f cm", $0) }
                ?? String(format: "%.0f pt", fit?.fixationError ?? 0)
            setLabels("Calibration done — typical error ≈ \(error) while fixating")
        } else {
            setLabels("Calibration failed — the camera saw too little of your face. Try again.")
        }
        pendingOutcome = calibration.map(Outcome.calibrated) ?? .failed
        guard await pause(Self.resultDuration) else { return }
        finish(with: pendingOutcome ?? .cancelled)
    }

    /// One pass on one display: instruction with the ball resting at the path start, then the ball
    /// moves at constant physical speed while every face frame is recorded.
    private func pursue(on overlay: Overlay, _ pass: Pass) async -> Bool {
        let path = PursuitPath.serpentine(in: overlay.display.frame, rows: pass.rows)
        var trace = PursuitTrace(displayID: overlay.display.id, path: path, speed: Self.ballSpeed(on: overlay.display),
                                 start: .infinity)
        showBall(at: path.start, on: overlay.display.id)
        for other in overlays {
            other.label.stringValue = other.display.id == overlay.display.id
                ? "\(pass.prompt)\nEsc cancels."
                : "Look at \(overlay.display.name): the ball is there. Esc cancels."
        }
        guard await pause(Self.readDuration) else { return false }

        trace.start = now()
        activeTrace = trace
        overlay.label.stringValue = ""
        let ticker = Ticker { [weak self] in self?.moveBall() }
        let link = overlay.window.contentView?.displayLink(target: ticker, selector: #selector(Ticker.step))
        link?.add(to: .main, forMode: .common)
        displayLink = link
        let completed = await pause(trace.duration)
        stopBall()
        if completed, let activeTrace { traces.append(activeTrace) }
        activeTrace = nil
        return completed
    }

    private func moveBall() {
        guard let activeTrace, let overlay = overlays.first(where: { $0.display.id == activeTrace.displayID }) else { return }
        let p = activeTrace.target(at: now())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.ball.position = CGPoint(x: p.x - overlay.display.frame.minX, y: p.y - overlay.display.frame.minY)
        CATransaction.commit()
    }

    private func stopBall() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func showBall(at point: CGPoint, on displayID: CGDirectDisplayID?) {
        for overlay in overlays {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.ball.isHidden = overlay.display.id != displayID
            overlay.ball.position = CGPoint(x: point.x - overlay.display.frame.minX, y: point.y - overlay.display.frame.minY)
            CATransaction.commit()
        }
    }

    private func setLabels(_ text: String) {
        for overlay in overlays { overlay.label.stringValue = text }
    }

    /// Keyboard pose: samples labelled `awayDisplayID` teach the away classifier what "looking down" is.
    /// The prompt stays readable for a moment before collection, so reading frames are not labelled away.
    private func holdKeyboard() async -> Bool {
        showBall(at: .zero, on: nil)
        setLabels(Self.keyboardPrompt)
        guard await pause(Self.keyboardReadDuration) else { return false }
        collectFrom = now() + Self.keyboardDiscardDuration
        collectingKeyboard = true
        for remaining in stride(from: Self.keyboardHoldSeconds, to: 0, by: -1) {
            setLabels("\(Self.keyboardPrompt)\n\(remaining)")
            guard await pause(1) else { return false }
        }
        collectingKeyboard = false
        return true
    }

    /// Nil unless the fit succeeded and every display has samples.
    private func makeCalibration(_ fit: CalibrationFit?) -> Calibration? {
        let displays = overlays.map(\.display)
        guard let fit, Set(fit.samples.map(\.displayID)) == Set(displays.map(\.id)),
              GazeModel(samples: fit.samples, lambda: fit.lambda, displayLambdas: fit.displayLambdas) != nil
        else { return nil }
        let largest = displays.compactMap { d in d.pointsPerMillimetre.map { (d, $0) } }
            .max { a, b in a.0.longestSide / a.1 < b.0.longestSide / b.1 }
        return Calibration(samples: fit.samples + keyboardSamples, displays: displays, lambda: fit.lambda,
                           displayLambdas: fit.displayLambdas, noiseRadius: fit.noiseRadius,
                           typicalErrorCm: largest.map { fit.fixationError / $0.1 / 10 })
    }

    private static func ballSpeed(on display: DisplayInfo) -> Double {
        display.pointsPerMillimetre.map { ballSpeedMM * $0 } ?? fallbackSpeed
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
            runTask = Task { await run() }
        default:
            break
        }
    }

    private func finish(with outcome: Outcome) {
        isRunning = false
        runTask?.cancel()
        runTask = nil
        fitTask?.cancel()
        fitTask = nil
        pendingOutcome = nil
        stopBall()
        activeTrace = nil
        collectingKeyboard = false
        for overlay in overlays { overlay.window.orderOut(nil) }
        overlays = []
        traces = []
        keyboardSamples = []
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }

    private func makeOverlay(_ display: DisplayInfo) -> Overlay {
        let frame = display.frame
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

        let label = NSTextField(wrappingLabelWithString: "Follow the ball across each screen, first with your head and eyes, then with your eyes only. Press Space to start.")
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

        let ball = CALayer()
        ball.bounds = CGRect(x: 0, y: 0, width: Self.ballDiameter, height: Self.ballDiameter)
        ball.cornerRadius = Self.ballDiameter / 2
        ball.backgroundColor = NSColor.white.cgColor
        ball.borderColor = NSColor.systemRed.cgColor
        ball.borderWidth = 3
        ball.isHidden = true
        let centre = CALayer()
        centre.bounds = CGRect(x: 0, y: 0, width: Self.centreDiameter, height: Self.centreDiameter)
        centre.cornerRadius = Self.centreDiameter / 2
        centre.backgroundColor = NSColor.black.cgColor
        centre.position = CGPoint(x: Self.ballDiameter / 2, y: Self.ballDiameter / 2)
        ball.addSublayer(centre)
        view.layer?.addSublayer(ball)

        window.contentView = view
        return Overlay(display: display, window: window, ball: ball, label: label)
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

extension DisplayInfo {
    /// Pixels are square, so longest side over longest side holds whether or not the reported
    /// physical size follows a rotated display. Nil when the physical size is unknown.
    var pointsPerMillimetre: Double? {
        let size = CGDisplayScreenSize(id)
        let millimetres = max(size.width, size.height)
        guard millimetres > 0, longestSide > 0 else { return nil }
        return longestSide / Double(millimetres)
    }

    var longestSide: Double {
        Double(max(frame.width, frame.height))
    }
}
