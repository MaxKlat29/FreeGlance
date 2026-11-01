import AVFoundation
import CoreVideo
import os

struct CameraDevice: Identifiable, Sendable, Hashable {
    enum Kind: Int, Sendable, Comparable {
        case external, builtIn, continuity

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var name: String
    var kind: Kind
}

/// Delivers camera frames on a private background queue, throttled to `maxFrameRate`.
/// Frames are handed to `onFrame` synchronously and never retained.
final class CameraSource: NSObject, @unchecked Sendable {
    typealias FrameHandler = @Sendable (CVPixelBuffer, TimeInterval) -> Void

    static let maxFrameRate: Double = 15

    private let onFrame: FrameHandler
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "de.klattig.FreeGlance.camera.session")
    private let frameQueue = DispatchQueue(label: "de.klattig.FreeGlance.camera.frames", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var activeDevice: CameraDevice?
        var lastFrameTime: TimeInterval = 0
        var wantsRunning = false
        var requestedID: String?
    }

    private var sessionObservers: [NSObjectProtocol] = []

    init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        sessionObservers = [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Cameras ordered by preference: external, built-in, Continuity Camera.
    static func availableCameras() -> [CameraDevice] {
        captureDevices().map(Self.describe).sorted { $0.kind < $1.kind }
    }

    var activeDevice: CameraDevice? {
        state.withLock { $0.activeDevice }
    }

    var isRunning: Bool {
        session.isRunning
    }

    /// Starts capturing from the camera with `uniqueID`, or the preferred camera when nil or not found.
    func start(uniqueID: String? = nil) {
        state.withLock {
            $0.wantsRunning = true
            $0.requestedID = uniqueID
        }
        sessionQueue.async { [self] in
            run(uniqueID: uniqueID)
        }
    }

    /// Re-resolves the device after devices changed or the session failed, if capture is wanted.
    func refresh() {
        sessionQueue.async { [self] in
            let (wanted, uniqueID) = state.withLock { ($0.wantsRunning, $0.requestedID) }
            guard wanted else { return }
            run(uniqueID: uniqueID)
        }
    }

    func stop() {
        state.withLock { $0.wantsRunning = false }
        sessionQueue.async { [self] in
            stopSession()
        }
    }

    private func run(uniqueID: String?) {
        guard Self.isAuthorized, let device = Self.resolveDevice(uniqueID: uniqueID) else {
            stopSession()
            return
        }
        if state.withLock({ $0.activeDevice?.id }) != device.uniqueID || !session.isRunning {
            configure(with: device)
            limitFrameRate(of: device)
        }
        if !session.isRunning {
            session.startRunning()
        }
    }

    private func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configure(with device: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            state.withLock { $0.activeDevice = nil }
            return
        }
        session.addInput(input)
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let described = Self.describe(device)
        state.withLock {
            $0.activeDevice = described
            $0.lastFrameTime = 0
        }
    }

    private func limitFrameRate(of device: AVCaptureDevice) {
        let rate = Self.maxFrameRate
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
        device.unlockForConfiguration()
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func resolveDevice(uniqueID: String?) -> AVCaptureDevice? {
        let devices = captureDevices()
        if let uniqueID, let match = devices.first(where: { $0.uniqueID == uniqueID }) {
            return match
        }
        return devices.min { describe($0).kind < describe($1).kind }
    }

    private static func describe(_ device: AVCaptureDevice) -> CameraDevice {
        let kind: CameraDevice.Kind = switch device.deviceType {
        case .builtInWideAngleCamera: .builtIn
        case .continuityCamera: .continuity
        default: .external
        }
        return CameraDevice(id: device.uniqueID, name: device.localizedName, kind: kind)
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = state.withLock { state in
            guard now - state.lastFrameTime >= 1 / Self.maxFrameRate * 0.95 else { return false }
            state.lastFrameTime = now
            return true
        }
        guard accepted, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer, now)
    }
}
