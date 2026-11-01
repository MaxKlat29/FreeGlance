import AppKit
import AVFoundation
import Combine
import UserNotifications

struct CameraChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class AppState: ObservableObject {
    let settings: Settings
    let focusEngine: FocusEngine

    @Published private(set) var status = "Needs calibration"
    @Published private(set) var isPaused = false
    @Published private(set) var facingDisplay: CGDirectDisplayID?
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var calibratedDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var keyboardCalibrated = false
    /// Median calibration error on the largest display, nil when unknown.
    @Published private(set) var calibrationErrorCm: Double?
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var needsRecalibration = false

    private enum Suspension { case sleep, screensSleep, locked, screensaver, sessionInactive }

    private static let clickBufferSize = 300
    /// Share of the model's total weight a full click buffer carries, so clicks can still correct
    /// a local offset against thousands of pursuit frames.
    private static let clickShare = 0.2
    private static let refitInterval: TimeInterval = 5
    private static let driftWindow = 20
    private static let driftRatio = 0.4
    private static let driftCooldown: TimeInterval = 3600
    private static let featureMaxAge: TimeInterval = 0.4
    private static let launchAtLoginRegisteredKey = "launchAtLoginRegistered"

    private var camera: CameraSource?
    private var cameraRunning = false
    private var activeCameraID: String?
    private var suspensions: Set<Suspension> = []
    private var permissionTimer: Timer?
    private var accessibilityTimer: Timer?
    private var calibrationFailed = false

    private var calibration: Calibration?
    private var model: GazeModel?
    private var awayDetector = AwayDetector(samples: [])
    private var isAway = false
    private var selector = ScreenSelector(displays: [])

    private var paneDelay: TimeInterval
    private var paneDwell: Dwell<PaneKey>
    private var lastPaneKey: PaneKey?
    private var paneKeyCache: (point: CGPoint, time: TimeInterval, key: PaneKey?)?
    /// Screen selection: One Euro filtered global model point.
    private var gazeFilter = OneEuroFilter()
    /// Eye tracker dot and same-screen targeting: median of three points of the facing display's model
    /// (no single-frame spikes), then fixation-smoothed with the calibration's measured noise radius.
    private var spikeFilter = MedianFilter()
    private var fixationFilter = FixationFilter()
    /// Display whose model fed the spike and fixation filters; they restart when it changes.
    private var refinedDisplay: CGDirectDisplayID?
    /// Screens switch this long after the last keystroke; panes wait for the full typing pause.
    private static let screenTypingBeat: TimeInterval = 0.4

    private var latestFeatures: GazeFeatures?
    private var latestFeaturesAt: TimeInterval = 0

    private var clickSamples: [CalibrationSample] = []
    private var lastRefit: TimeInterval = 0
    private var refitTask: Task<Void, Never>?
    private var driftLog: [(display: CGDirectDisplayID, mismatch: Bool)] = []
    private var lastDriftNotice: TimeInterval = -.infinity

    private var calibrationController: CalibrationController?
    private var gazeDot: GazeDotOverlay?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: Settings = Settings()) {
        self.settings = settings
        focusEngine = FocusEngine()
        paneDelay = settings.paneDelay
        paneDwell = Dwell(duration: paneDelay)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var freshFeatures: GazeFeatures? {
        now - latestFeaturesAt <= Self.featureMaxAge ? latestFeatures : nil
    }

    func start() {
        let analyzer = FaceAnalyzer(smoothing: 0) { [weak self] features in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(features) } }
        }
        camera = CameraSource { buffer, timestamp in analyzer.analyze(buffer, timestamp: timestamp) }
        focusEngine.start()
        calibration = Calibration.load()
        updateCalibratedState()
        reloadDisplays()
        reloadCameras()
        applySettings()
        registerLaunchAtLoginOnce()
        observeSystem()
        startClickMonitor()
        watchAccessibility()
        settings.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.applySettings() } }
            .store(in: &cancellables)
        updateCamera()
        updateStatus()

        if calibration == nil || !CameraSource.isAuthorized || !AXIsProcessTrusted() {
            showWelcome()
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { resetFocusState() }
        updateCamera()
        updateStatus()
        if isPaused, settings.showGazeDot { gazeDot?.showPaused() }
    }

    func toggleEyeTracker() {
        settings.showGazeDot.toggle()
    }

    func startCalibration() {
        guard calibrationController == nil else { return }
        guard CameraSource.isAuthorized else {
            showWelcome()
            return
        }
        if isPaused { togglePause() }
        resetFocusState()
        let controller = CalibrationController()
        calibrationController = controller
        controller.start { [weak self] outcome in self?.finishCalibration(outcome) }
        updateCamera()
    }

    func showSettings() {
        syncLaunchAtLogin()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(appState: self) }
        settingsWindow?.show()
    }

    func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindowController(appState: self) }
        welcomeWindow?.show()
    }

    // MARK: Tracking

    private func handle(_ features: GazeFeatures?) {
        latestFeatures = features
        latestFeaturesAt = now
        guard let features else {
            gazeFilter.reset()
            spikeFilter.reset()
            fixationFilter.reset()
            paneDwell.reset()
            selector.hold()
            syncFacingDisplay()
            return
        }
        if let calibrationController {
            calibrationController.feed(features)
            return
        }
        guard cameraRunning, !needsRecalibration, let model else {
            gazeDot?.hide()
            return
        }

        let mouseIdle = InputGuard.secondsSinceMouse() >= InputGuard.mouseLockout
        let sinceKey = InputGuard.secondsSinceKey()
        let typing = settings.waitWhileTyping && sinceKey < settings.typingPauseSec
        let typingBeat = settings.waitWhileTyping && sinceKey < Self.screenTypingBeat

        let raw = model.predictPoint(features)
        let point = gazeFilter.filter(raw, at: features.timestamp)
        isAway = awayDetector.isAway(features) || selector.isAway(point)
        updateScreen(point: point, at: features.timestamp)

        if facingDisplay != refinedDisplay {
            refinedDisplay = facingDisplay
            spikeFilter.reset()
            fixationFilter.reset()
        }
        let refined = facingDisplay.map { model.refinedPoint(features, on: $0) } ?? raw
        let fixation = fixationFilter.filter(spikeFilter.filter(refined, at: features.timestamp), at: features.timestamp)

        if mouseIdle, !typingBeat, let pending = selector.takePendingSwitch() {
            focusEngine.focus(display: pending)
            lastPaneKey = nil
            paneDwell = Dwell(duration: paneDelay)
        }

        if settings.showGazeDot {
            if gazeDot == nil { gazeDot = GazeDotOverlay() }
            gazeDot?.show(at: fixation, away: isAway)
        } else {
            gazeDot?.hide()
        }

        guard settings.sameScreenFocus, selector.pendingSwitch == nil, mouseIdle, !typing, !isAway,
              let facing = displays.first(where: { $0.id == facingDisplay }),
              facing.frame.contains(fixation) else {
            paneDwell = Dwell(duration: paneDelay)
            return
        }
        if let fired = paneDwell.update(paneKey(at: fixation), at: features.timestamp), fired != lastPaneKey {
            lastPaneKey = fired
            focusEngine.focus(point: fixation, onDisplay: facing.id)
        }
    }

    private func updateScreen(point: CGPoint, at t: TimeInterval) {
        guard displays.count >= 2 else { return }
        selector.update(point: point, away: isAway, at: t)
        syncFacingDisplay()
    }

    private func syncFacingDisplay() {
        guard displays.count >= 2 else { return }
        if facingDisplay != selector.current {
            facingDisplay = selector.current
            updateStatus()
        }
    }

    private func paneKey(at point: CGPoint) -> PaneKey? {
        let t = now
        if let cache = paneKeyCache, hypot(cache.point.x - point.x, cache.point.y - point.y) < 24, t - cache.time < 0.15 {
            return cache.key
        }
        let key = PaneKey.at(point)
        paneKeyCache = (point, t, key)
        return key
    }

    private func resetFocusState() {
        selector.hold()
        syncFacingDisplay()
        isAway = false
        paneDwell = Dwell(duration: paneDelay)
        gazeDot?.hide()
    }

    private func rebuildModel() {
        guard let calibration, !needsRecalibration else {
            model = nil
            updateStatus()
            updateCamera()
            return
        }
        let samples = calibration.samples + clickSamples
        model = GazeModel(samples: samples, lambda: calibration.lambda, displayLambdas: calibration.displayLambdas ?? [:])
        fixationFilter.radius = calibration.noiseRadius
        awayDetector = AwayDetector(samples: samples)
        lastRefit = now
        updateStatus()
        updateCamera()
    }

    private func finishCalibration(_ outcome: CalibrationController.Outcome) {
        calibrationController = nil
        let result: Calibration
        switch outcome {
        case .cancelled:
            updateStatus()
            updateCamera()
            return
        case let .calibrated(calibration) where calibration.matches(displays: displays):
            result = calibration
        case .calibrated, .failed:
            calibrationFailed = true
            updateStatus()
            updateCamera()
            return
        }
        calibrationFailed = false
        result.save()
        calibration = result
        updateCalibratedState()
        clickSamples = []
        driftLog = []
        needsRecalibration = false
        selector = makeSelector()
        rebuildModel()
    }

    // MARK: Clicks

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let cgEvent = event.cgEvent, PaneFocuser.isSynthetic(cgEvent) { return }
            MainActor.assumeIsolated { self?.handleClick(at: NSEvent.mouseLocation) }
        }
    }

    private func handleClick(at point: CGPoint) {
        lastPaneKey = PaneKey.at(point)
        paneDwell = Dwell(duration: paneDelay)
        guard let clicked = displays.first(where: { $0.frame.contains(point) }) else { return }
        let predicted = facingDisplay
        if displays.count >= 2 {
            selector.setCurrent(clicked.id)
            facingDisplay = selector.current
            updateStatus()
        }
        // A click while looking at the keyboard says nothing about where the eyes point.
        guard calibrationController == nil, !isPaused, !needsRecalibration, model != nil, !isAway,
              let calibration, let features = freshFeatures else { return }

        if displays.count >= 2, let predicted {
            trackDrift(clicked: clicked.id, predicted: predicted)
        }
        guard settings.learnFromClicks else { return }
        let weight = calibration.clickWeight(bufferSize: Self.clickBufferSize, share: Self.clickShare)
        clickSamples.append(CalibrationSample(features: features, point: point, displayID: clicked.id, weight: weight))
        if clickSamples.count > Self.clickBufferSize {
            clickSamples.removeFirst(clickSamples.count - Self.clickBufferSize)
        }
        scheduleRefit()
    }

    private func updateCalibratedState() {
        let samples = calibration?.samples ?? []
        calibratedDisplayIDs = Set(samples.filter { !$0.isAway }.map(\.displayID))
        keyboardCalibrated = samples.contains(where: \.isAway)
        calibrationErrorCm = calibration?.typicalErrorCm
    }

    private func scheduleRefit() {
        guard refitTask == nil else { return }
        let delay = max(0, lastRefit + Self.refitInterval - now)
        refitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            refitTask = nil
            rebuildModel()
        }
    }

    private func trackDrift(clicked: CGDirectDisplayID, predicted: CGDirectDisplayID) {
        driftLog.append((clicked, clicked != predicted))
        if driftLog.count > Self.driftWindow { driftLog.removeFirst() }
        guard driftLog.count == Self.driftWindow else { return }
        let mismatches = driftLog.filter(\.mismatch)
        guard Double(mismatches.count) / Double(Self.driftWindow) > Self.driftRatio,
              now - lastDriftNotice > Self.driftCooldown else { return }
        let counts = Dictionary(grouping: mismatches, by: \.display).mapValues(\.count)
        guard let worst = counts.max(by: { $0.value < $1.value })?.key,
              let name = displays.first(where: { $0.id == worst })?.name else { return }
        lastDriftNotice = now
        driftLog = []
        notifyDrift(displayName: name)
    }

    private func notifyDrift(displayName: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "FreeGlance accuracy dropped"
            content.body = "Clicks on \(displayName) often don't match where you are looking. Recalibrate to restore accuracy."
            let request = UNNotificationRequest(identifier: "drift", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: Camera

    private func updateCamera() {
        guard let camera else { return }
        let authorized = CameraSource.isAuthorized
        let tracking = calibrationController != nil || (model != nil && !needsRecalibration)
        let shouldRun = authorized && !isPaused && suspensions.isEmpty && tracking
        if shouldRun {
            if cameraRunning, activeCameraID != settings.cameraUniqueID {
                camera.stop()
                cameraRunning = false
            }
            if !cameraRunning {
                camera.start(uniqueID: settings.cameraUniqueID)
                activeCameraID = settings.cameraUniqueID
                cameraRunning = true
            }
        } else if cameraRunning {
            camera.stop()
            cameraRunning = false
            latestFeatures = nil
            resetFocusState()
        }
        watchCameraPermission(authorized: authorized)
    }

    private func watchCameraPermission(authorized: Bool) {
        if authorized {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard CameraSource.isAuthorized else { return }
                    self?.updateCamera()
                }
            }
        }
    }

    private func watchAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
                self.focusEngine.accessibilityGranted()
            }
        }
    }

    private func reloadCameras() {
        cameras = CameraSource.availableCameras().map { CameraChoice(id: $0.id, name: $0.name) }
    }

    // MARK: Displays

    private func reloadDisplays() {
        calibrationController?.cancel()
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: number.uint32Value, frame: screen.frame, name: screen.localizedName)
        }
        selector = makeSelector()
        facingDisplay = displays.count == 1 ? displays[0].id : nil
        if let calibration {
            needsRecalibration = !calibration.matches(displays: displays)
        }
        rebuildModel()
    }

    private func makeSelector() -> ScreenSelector {
        var selector = ScreenSelector(displays: displays)
        selector.dwell = settings.switchDelay
        selector.turnThreshold = settings.headTurnFraction
        return selector
    }

    // MARK: Settings

    private func applySettings() {
        selector.dwell = settings.switchDelay
        selector.turnThreshold = settings.headTurnFraction
        focusEngine.clickFallback = settings.clickFallback
        let delay = settings.paneDelay
        if delay != paneDelay {
            paneDelay = delay
            paneDwell = Dwell(duration: delay)
        }
        if !settings.showGazeDot {
            gazeDot?.hide()
        } else if isPaused {
            gazeDot?.showPaused()
        }
        if !settings.learnFromClicks, !clickSamples.isEmpty {
            clickSamples = []
            rebuildModel()
        }
        if cameraRunning, activeCameraID != settings.cameraUniqueID {
            updateCamera()
        }
    }

    private func registerLaunchAtLoginOnce() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.launchAtLoginRegisteredKey) {
            guard !settings.launchAtLogin || LaunchAtLogin.apply(true) else { return }
            defaults.set(true, forKey: Self.launchAtLoginRegisteredKey)
        }
        syncLaunchAtLogin()
    }

    private func syncLaunchAtLogin() {
        let enabled = LaunchAtLogin.isEnabled
        if settings.launchAtLogin != enabled { settings.launchAtLogin = enabled }
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let toggles: [(NotificationCenter, Notification.Name, Suspension, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, .sleep, true),
            (workspace, NSWorkspace.didWakeNotification, .sleep, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensSleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensSleep, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            (distributed, Notification.Name("com.apple.screensaver.didstart"), .screensaver, true),
            (distributed, Notification.Name("com.apple.screensaver.didstop"), .screensaver, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (center, name, reason, active) in toggles {
            observe(center, name) { state in
                if active {
                    state.suspensions.insert(reason)
                } else {
                    state.suspensions.remove(reason)
                }
                state.updateCamera()
            }
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.reloadDisplays() }
        observe(.default, AVCaptureDevice.wasConnectedNotification) { $0.camerasChanged() }
        observe(.default, AVCaptureDevice.wasDisconnectedNotification) { $0.camerasChanged() }
    }

    private func camerasChanged() {
        reloadCameras()
        if cameraRunning { camera?.refresh() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (AppState) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }

    // MARK: Status and windows

    private func updateStatus() {
        let text: String
        if isPaused {
            text = "Paused"
        } else if model == nil || needsRecalibration {
            text = calibrationFailed ? "Calibration failed — try again" : "Needs calibration"
        } else if let name = displays.first(where: { $0.id == facingDisplay })?.name {
            text = "Tracking — facing \(name)"
        } else {
            text = "Tracking"
        }
        if status != text { status = text }
    }

}
