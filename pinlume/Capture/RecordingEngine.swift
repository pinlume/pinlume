import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import os.log

private let recordingResourceLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "Pinlume.plus",
    category: "RecordingResource")

// Callback types
typealias RecordingProgressCallback = (_ seconds: Int) -> Void
typealias RecordingCompletionCallback = (_ url: URL?, _ error: Error?) -> Void

@MainActor
final class RecordingEngine: NSObject {

    // MARK: - State

    typealias State = RecordingLifecycleState
    private var lifecycle = RecordingLifecycle()
    var state: State { lifecycle.state }
    private var startupTask: Task<Void, Never>?

    // MARK: - Config (read from UserDefaults at start)

    private var fps: Int = 30
    private var cropRect: CGRect = .zero      // in screen coordinates (top-left origin)
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()

    // MARK: - SCStream

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?

    // MARK: - MP4 writer

    /// Serial queue for all recording I/O (video + audio). The writer session and
    /// the SCStream/mic sample handlers all run here, so writer state never races
    /// with the main actor.
    private let recordingQueue = DispatchQueue(
        label: "Pinlume.recording",
        autoreleaseFrequency: .workItem
    )
    /// All AVAssetWriter state lives in this queue-confined object. The main actor
    /// only holds a reference and forwards lifecycle calls.
    private var writerSession: MP4WriterSession?
    private var outputURL: URL?
    private var writerOutputURL: URL?

    // MARK: - Mic capture

    private var micCaptureSession: AVCaptureSession?
    private var micDataOutput: AVCaptureAudioDataOutput?
    private var micDelegate: MicCaptureDelegate?

    // MARK: - Callbacks

    var onProgress: RecordingProgressCallback?
    var onCompletion: RecordingCompletionCallback?
    var onStarted: (() -> Void)?
    var onStopping: (() -> Void)?

    private var progressTimer: Timer?
    private var elapsedSeconds: Int = 0
    private var pauseStartTime: Date?
    var onPauseChanged: ((Bool) -> Void)?

    // MARK: - Cursor highlight


    // MARK: - Public API

    /// Start recording the given rect (in NSScreen/AppKit coordinates, bottom-left origin).
    /// Optional overrides take precedence over UserDefaults for this session.
    /// Window IDs to exclude from the recording (e.g. selection border, HUD).
    private var excludeWindowNumbers: [CGWindowID] = []

    private static func displayRefreshRate(for screen: NSScreen) -> Double? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let displayMode = CGDisplayCopyDisplayMode(displayID),
              displayMode.refreshRate > 0
        else {
            return nil
        }
        return displayMode.refreshRate
    }

    func startRecording(rect: NSRect, screen: NSScreen, fpsOverride: Int? = nil, excludeWindowNumbers: [CGWindowID] = []) {
        self.excludeWindowNumbers = excludeWindowNumbers
        guard let generation = lifecycle.beginStarting() else { return }

        self.screen = screen
        // Convert AppKit rect (bottom-left origin) → screen coords (top-left origin)
        // SCStream uses top-left origin matching the display's coordinate system.
        let displayBounds = screen.frame
        let flippedY = displayBounds.maxY - rect.maxY
        // Scale to points — SCStream works in points on the display
        self.cropRect = CGRect(x: rect.minX - displayBounds.minX,
                               y: flippedY,
                               width: rect.width,
                               height: rect.height)

        let defaultFPS = UserDefaults.standard.integer(forKey: "recordingFPS") > 0
            ? UserDefaults.standard.integer(forKey: "recordingFPS") : 30
        self.fps = RecordingFrameRate.effectiveFPS(
            requested: fpsOverride ?? defaultFPS,
            displayRefreshRate: Self.displayRefreshRate(for: screen)
        )
        startupTask = Task { [weak self] in
            guard let self else { return }
            // Resolve mic permission before starting capture so the prompt
            // doesn't block the UI while frames are already being recorded.
            if UserDefaults.standard.bool(forKey: "recordMicAudio") {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if micStatus == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    guard self.acceptsStartup(generation) else { return }
                    if !granted {
                        UserDefaults.standard.set(false, forKey: "recordMicAudio")
                    }
                } else if micStatus == .denied || micStatus == .restricted {
                    UserDefaults.standard.set(false, forKey: "recordMicAudio")
                }
            }
            guard self.acceptsStartup(generation) else { return }
            await self.beginCapture(rect: rect, generation: generation)
        }
    }

    func pauseRecording() {
        guard lifecycle.pause(generation: lifecycle.generation) else { return }
        pauseStartTime = Date()
        writerSession?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        onPauseChanged?(true)
    }

    func resumeRecording() {
        guard lifecycle.resume(generation: lifecycle.generation) else { return }
        let pausedFor = pauseStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pauseStartTime = nil
        writerSession?.resume(addingPausedDuration: pausedFor)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsedSeconds += 1
            self.onProgress?(self.elapsedSeconds)
        }
        onPauseChanged?(false)
    }

    func stopRecording() {
        guard let generation = lifecycle.stop() else { return }
        onStopping?()
        startupTask?.cancel()
        startupTask = nil
        // Stop accepting samples ASAP (more may arrive during SCStream teardown).
        writerSession?.requestStop()
        progressTimer?.invalidate()
        progressTimer = nil
        Task { await self.finalizeCapture(generation: generation) }
    }

    // MARK: - Setup

    private func beginCapture(rect: NSRect, generation: UInt) async {
        do {
            // Find the SCDisplay matching our screen by display ID
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard acceptsStartup(generation) else { return }
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let targetDisplayID = RecordingDisplaySelection.target(
                    requested: screenID,
                    available: content.displays.map(\.displayID)),
                  let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
                await fail(RecordingError.noDisplay, generation: generation)
                return
            }

            // Exclude specific Pinlume UI chrome windows (selection border, HUD)
            // but NOT recording overlays (webcam, mouse highlight, keystrokes)
            // which are intentionally part of the recording.
            let excludeIDs = excludeWindowNumbers
            let excludeWindows = excludeIDs.compactMap { wid in
                content.windows.first(where: { CGWindowID($0.windowID) == wid })
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
            let config = SCStreamConfiguration()
            let dimensions = RecordingCaptureDimensions.even(
                width: Int(cropRect.width * screen.backingScaleFactor),
                height: Int(cropRect.height * screen.backingScaleFactor))
            config.width = Int(dimensions.width)
            config.height = Int(dimensions.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.showsCursor = true   // we'll draw our own highlight on top if needed
            config.sourceRect = cropRect
            // H.264 encodes YUV. Asking ScreenCaptureKit for NV12 lets the
            // writer consume the captured IOSurface directly instead of
            // sending every live BGRA frame through VideoToolbox's RGB→YUV
            // transfer path.
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.scalesToFit = false
            // Force sRGB at capture time. Without this ScreenCaptureKit delivers
            // frames in the display's native color space (often Display P3),
            // but AVAssetWriter tags the file as bt709 below — a mismatch that
            // makes AVPlayer render back the video with washed-out colors on
            // P3 displays.
            if #available(macOS 14.0, *) {
                config.colorSpaceName = CGColorSpace.sRGB
            }

            // System audio capture (off by default, macOS 13+)
            if #available(macOS 13.0, *) {
                let recordAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
                config.capturesAudio = recordAudio
                config.excludesCurrentProcessAudio = true  // don't capture Pinlume's own sounds
            }

            let pixelW = config.width
            let pixelH = config.height

            // Prepare output file
            guard let outputReservation = makeOutputURL() else {
                await fail(RecordingError.noOutput, generation: generation)
                return
            }
            outputURL = outputReservation.finalURL
            writerOutputURL = outputReservation.writerURL

            let recordSystemAudio: Bool = {
                if #available(macOS 13.0, *) { return UserDefaults.standard.bool(forKey: "recordSystemAudio") }
                return false
            }()
            let recordMicAudio = UserDefaults.standard.bool(forKey: "recordMicAudio")
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let liveQuality = LiveRecordingQuality.resolve(
                rawValue: UserDefaults.standard.string(forKey: "recordingQuality"),
                width: pixelW,
                height: pixelH,
                fps: fps
            )
            let writer = try MP4WriterSession.make(
                queue: recordingQueue, url: outputReservation.writerURL,
                width: pixelW, height: pixelH, fps: fps,
                quality: VideoQuality(rawValue: liveQuality.rawValue) ?? .medium,
                recordSystemAudio: recordSystemAudio, recordMicAudio: recordMicAudio)
            self.writerSession = writer

            // Sample handlers run ON recordingQueue and call the queue-confined
            // writer session directly — no @MainActor hop, no race.
            let output = RecordingStreamOutput()
            output.onFrame = { pixelBuffer, presentationTime in
                writer.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSample = { sampleBuffer in
                writer.handleSystemAudioSample(sampleBuffer)
            }
            output.onStopped = { [weak self] in
                self?.stopRecording()
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: recordingQueue)
            if #available(macOS 13.0, *) {
                let recordAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
                if recordAudio {
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: recordingQueue)
                }
            }
            self.stream = stream
            try await stream.startCapture()
            guard acceptsStartup(generation) else {
                try? await stream.stopCapture()
                return
            }
            guard lifecycle.markRecording(generation: generation) else { return }
            onStarted?()

            // Start mic capture if enabled and authorized (permission resolved before capture started)
            if UserDefaults.standard.bool(forKey: "recordMicAudio") &&
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                startMicCapture()
            }

            self.elapsedSeconds = 0
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.elapsedSeconds += 1
                self.onProgress?(self.elapsedSeconds)
            }
        } catch {
            await fail(error, generation: generation)
        }
    }

    private func finalizeCapture(generation: UInt) async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        streamOutput = nil
        stopMicCapture()

        guard let writer = writerSession else {
            succeed(generation: generation)
            return
        }
        do {
            try await writer.finish()
            writerSession = nil
            guard let writerOutputURL, let outputURL else {
                throw RecordingError.noOutput
            }
            try TransactionalOutput.transfer(
                writerOutputURL,
                to: outputURL,
                reservedDestination: true)
            self.writerOutputURL = nil
            succeed(generation: generation)
        } catch {
            await fail(error, generation: generation)
        }
    }

    // MARK: - Mic capture

    private func startMicCapture() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let micDevice: AVCaptureDevice
        if let uid = UserDefaults.standard.string(forKey: "selectedMicDeviceUID"),
           let device = AVCaptureDevice(uniqueID: uid) {
            micDevice = device
        } else {
            guard let device = AVCaptureDevice.default(for: .audio) else { return }
            micDevice = device
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let deviceInput = try? AVCaptureDeviceInput(device: micDevice) else { return }
        guard session.canAddInput(deviceInput) else { return }
        session.addInput(deviceInput)

        let dataOutput = AVCaptureAudioDataOutput()
        let delegate = MicCaptureDelegate()
        // Deliver mic samples straight to the queue-confined writer session.
        let writer = writerSession
        delegate.onSample = { sampleBuffer in
            writer?.handleMicSample(sampleBuffer)
        }
        dataOutput.setSampleBufferDelegate(delegate, queue: recordingQueue)
        guard session.canAddOutput(dataOutput) else { return }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        session.startRunning()

        self.micCaptureSession = session
        self.micDataOutput = dataOutput
        self.micDelegate = delegate
    }

    private func stopMicCapture() {
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micDataOutput = nil
        micDelegate = nil
    }


    // MARK: - Output URL

    private func makeOutputURL() -> RecordingOutputReservation? {
        // Save to temp directory — always writable in sandbox.
        // The video editor handles final export to the user's chosen location.
        let dir = FileManager.default.temporaryDirectory
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.recordingUserDefaultsKey) ?? FilenameFormatter.defaultRecordingTemplate
        let base = FilenameFormatter.format(template: template, fallback: FilenameFormatter.defaultRecordingTemplate)
        return RecordingOutputURL.make(in: dir, baseName: base)
    }

    // MARK: - Helpers

    private func acceptsStartup(_ generation: UInt) -> Bool {
        lifecycle.generation == generation && lifecycle.state == .starting && !Task.isCancelled
    }

    private func succeed(generation: UInt) {
        guard lifecycle.complete(generation: generation) else { return }
        startupTask = nil
        onCompletion?(outputURL, nil)
    }

    private func fail(_ error: Error, generation: UInt) async {
        guard lifecycle.abort(generation: generation) else { return }
        startupTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        if let writer = writerSession {
            writer.requestStop()
            try? await writer.finish()
        }
        writerSession = nil
        stopMicCapture()
        if let writerOutputURL { try? FileManager.default.removeItem(at: writerOutputURL) }
        writerOutputURL = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
        onCompletion?(nil, error)
    }

    enum RecordingError: LocalizedError {
        case noDisplay, noOutput
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Could not find the screen to record."
            case .noOutput: return "Could not create output file."
            }
        }
    }
}

// MARK: - SCStreamOutput

private class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onStopped: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // ScreenCaptureKit delivers one work item per sample. Keep the scope
        // explicit as well as configuring the serial queue so a long recording
        // does not retain temporary AVFoundation wrappers between frames.
        autoreleasepool {
            switch type {
            case .screen:
                guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                onFrame?(pixelBuffer, pts)
            case .audio:
                onAudioSample?(sampleBuffer)
            case .microphone:
                // Microphone audio is captured by the dedicated AVCapture path
                // below, not by this ScreenCaptureKit stream.
                break
            @unknown default:
                break
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopped?()
        }
    }
}

// MARK: - Mic AVCaptureAudioDataOutput delegate

private class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSample: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}

// MARK: - CMSampleBuffer time adjustment

private extension CMSampleBuffer {
    /// Create a copy of this audio sample buffer with timestamps shifted back
    /// by the given pause duration, so the output has no time gaps.
    func adjustingTime(by pauseDuration: TimeInterval) -> CMSampleBuffer? {
        guard pauseDuration > 0 else { return self }
        let offset = CMTimeMakeWithSeconds(pauseDuration, preferredTimescale: 44100)
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(self), offset)
        let dur = CMSampleBufferGetDuration(self)

        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted)
        return adjusted
    }
}

// MARK: - MP4 writer session (queue-confined)

/// Owns ALL AVAssetWriter state and is confined to a single serial queue. The
/// SCStream/mic sample handlers run on that same queue and call into here, so
/// frames/audio and the writer lifecycle (start/pause/finish) never race —
/// previously these were `@MainActor` methods invoked from the background
/// recording queue with no synchronization, which could append after
/// `markAsFinished()` and crash AVAssetWriter. All members are touched only on
/// `queue`; `@unchecked Sendable` is sound because of that confinement.
/// Writer lifecycle mode — Int-backed so its `==` (from RawRepresentable) is
/// nonisolated; it's compared on the recording queue, not the main actor.
private enum MP4WriterMode: Int, Sendable { case recording, paused, finishing, finished }

/// Holds only the short audio lead-in that can legitimately race the first
/// video frame. The time window preserves normal A/V startup ordering; the
/// count ceiling is a fallback for malformed or non-monotonic timestamps.
private struct StartupAudioSampleBuffer {
    static let maximumDurationSeconds: TimeInterval = 2
    static let maximumDuration = CMTime(
        seconds: maximumDurationSeconds, preferredTimescale: 600)
    static let maximumSampleCount = 512

    private var samples: [CMSampleBuffer] = []
    private(set) var droppedCount = 0

    mutating func appendBounded(_ sampleBuffer: CMSampleBuffer) {
        samples.append(sampleBuffer)
        while samples.count > Self.maximumSampleCount {
            samples.removeFirst()
            droppedCount += 1
        }

        let newestTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard newestTime.isValid, newestTime.isNumeric else { return }
        while let first = samples.first {
            let firstTime = CMSampleBufferGetPresentationTimeStamp(first)
            guard firstTime.isValid, firstTime.isNumeric else { break }
            let age = CMTimeSubtract(newestTime, firstTime)
            guard age.isValid, age.isNumeric,
                  CMTimeCompare(age, Self.maximumDuration) > 0
            else { break }
            samples.removeFirst()
            droppedCount += 1
        }
    }

    mutating func drain() -> (samples: [CMSampleBuffer], dropped: Int) {
        let result = (samples, droppedCount)
        samples.removeAll()
        droppedCount = 0
        return result
    }
}

private final class MP4WriterSession: @unchecked Sendable {
    let queue: DispatchQueue
    private var mode: MP4WriterMode = .recording
    private var pauseOffset: TimeInterval = 0

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?      // system audio
    private var micAudioInput: AVAssetWriterInput?   // microphone audio
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var sessionStarted = false
    private var startTime: CMTime = .invalid
    private(set) var frameCount: Int64 = 0

    private var pendingAudioSamples = StartupAudioSampleBuffer()
    private var pendingMicSamples = StartupAudioSampleBuffer()

    /// Build on `queue` so the writer/inputs are created where they're used.
    static func make(queue: DispatchQueue, url: URL, width: Int, height: Int, fps: Int,
                     quality: VideoQuality,
                     recordSystemAudio: Bool, recordMicAudio: Bool) throws -> MP4WriterSession {
        var result: Result<MP4WriterSession, Error>!
        queue.sync {
            result = Result {
                try MP4WriterSession(queue: queue, url: url, width: width, height: height,
                                     fps: fps, quality: quality, recordSystemAudio: recordSystemAudio,
                                     recordMicAudio: recordMicAudio)
            }
        }
        return try result.get()
    }

    private init(queue: DispatchQueue, url: URL, width: Int, height: Int, fps: Int,
                 quality: VideoQuality,
                 recordSystemAudio: Bool, recordMicAudio: Bool) throws {
        self.queue = queue
        dispatchPrecondition(condition: .onQueue(queue))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings = VideoEncodingSettings.outputSettings(
            width: width, height: height, fps: fps, codec: .h264, quality: quality)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let sourceAttr: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: sourceAttr)
        writer.add(input)

        // Mic FIRST so it's the primary audio track (most players decode only the
        // first). Mono downmix avoids one-ear playback on stereo mic devices.
        if recordMicAudio {
            let micLayout = AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_Mono,
                mChannelBitmap: [], mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription())
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000,
                AVChannelLayoutKey: Data(bytes: [micLayout], count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micIn.expectsMediaDataInRealTime = true
            writer.add(micIn)
            self.micAudioInput = micIn
        }

        if recordSystemAudio {
            let audioLayout = AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                mChannelBitmap: [], mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription())
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000,
                AVChannelLayoutKey: Data(bytes: [audioLayout], count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioIn.expectsMediaDataInRealTime = true
            writer.add(audioIn)
            self.audioInput = audioIn
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
    }

    // MARK: Lifecycle (called from the main actor; hop onto the queue)

    func pause() {
        queue.async {
            guard self.mode == .recording else { return }
            self.mode = .paused
        }
    }

    func resume(addingPausedDuration duration: TimeInterval) {
        queue.async {
            guard self.mode == .paused else { return }
            self.pauseOffset += max(0, duration)
            self.mode = .recording
        }
    }

    /// Stop accepting samples ASAP (samples may still arrive during SCStream
    /// teardown). The actual finish/drain happens in `finish()`.
    func requestStop() {
        queue.async {
            guard self.mode != .finished else { return }
            self.mode = .finishing
        }
    }

    /// Finish writing. Runs on the queue (after any in-flight append), marks
    /// inputs finished, then awaits finishWriting. Throws if the writer failed —
    /// so a corrupt/empty file is never reported as success.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.mode != .finished else { cont.resume(); return }
                self.mode = .finishing
                let discardedSystemAudio = self.pendingAudioSamples.drain()
                let discardedMicAudio = self.pendingMicSamples.drain()
                if !discardedSystemAudio.samples.isEmpty
                    || !discardedMicAudio.samples.isEmpty
                    || discardedSystemAudio.dropped > 0
                    || discardedMicAudio.dropped > 0
                {
                    os_log(
                        "RECORDING_RESOURCE startupAudioDiscarded systemBuffered=%{public}d systemDropped=%{public}d micBuffered=%{public}d micDropped=%{public}d",
                        log: recordingResourceLog,
                        type: .info,
                        discardedSystemAudio.samples.count,
                        discardedSystemAudio.dropped,
                        discardedMicAudio.samples.count,
                        discardedMicAudio.dropped)
                }

                guard let writer = self.assetWriter else {
                    self.tearDown()
                    cont.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                guard writer.status == .writing else {
                    // Writer already failed/completed before we got here — only an
                    // already-.completed writer is a success; anything else is a
                    // failure (don't report success just because error is nil).
                    let ok = writer.status == .completed && self.frameCount > 0
                    let err = writer.error
                    self.tearDown()
                    if ok { cont.resume() } else { cont.resume(throwing: err ?? CocoaError(.fileWriteUnknown)) }
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micAudioInput?.markAsFinished()
                writer.finishWriting {
                    // Read writer status/error back ON the queue (the only place
                    // that touches the writer) rather than in this callback thread.
                    self.queue.async {
                        let status = writer.status
                        let error = writer.error
                        let frames = self.frameCount
                        self.tearDown()
                        if status == .completed && frames > 0 {
                            cont.resume()
                        } else {
                            cont.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                        }
                    }
                }
            }
        }
    }

    private func tearDown() {
        mode = .finished
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        micAudioInput = nil
        adaptor = nil
    }

    // MARK: Sample handling (called on the queue by SCStream / mic delegate)

    func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording else { return }
        writeFrame(buffer: pixelBuffer, presentationTime: adjustedTime(presentationTime))
    }

    func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording, let input = audioInput else { return }
        if !sessionStarted { pendingAudioSamples.appendBounded(sampleBuffer); return }
        guard input.isReadyForMoreMediaData else { return }
        if let adjusted = sampleBuffer.adjustingTime(by: pauseOffset) { input.append(adjusted) }
    }

    func handleMicSample(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .recording, let input = micAudioInput else { return }
        if !sessionStarted { pendingMicSamples.appendBounded(sampleBuffer); return }
        guard input.isReadyForMoreMediaData else { return }
        if let adjusted = sampleBuffer.adjustingTime(by: pauseOffset) { input.append(adjusted) }
    }

    private func writeFrame(buffer: CVPixelBuffer, presentationTime: CMTime) {
        guard mode == .recording,
              let writer = assetWriter, writer.status == .writing,
              let input = videoInput, let adaptor = adaptor,
              input.isReadyForMoreMediaData
        else { return }

        if !sessionStarted {
            startTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
            // Flush audio that arrived before the first video frame.
            let systemAudio = pendingAudioSamples.drain()
            let micAudio = pendingMicSamples.drain()
            var appendedSystemAudio = 0
            for sample in systemAudio.samples {
                if let ai = audioInput, ai.isReadyForMoreMediaData,
                   let adjusted = sample.adjustingTime(by: pauseOffset),
                   CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(adjusted), startTime) >= 0 {
                    if ai.append(adjusted) { appendedSystemAudio += 1 }
                }
            }
            var appendedMicAudio = 0
            for sample in micAudio.samples {
                if let mi = micAudioInput, mi.isReadyForMoreMediaData,
                   let adjusted = sample.adjustingTime(by: pauseOffset),
                   CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(adjusted), startTime) >= 0 {
                    if mi.append(adjusted) { appendedMicAudio += 1 }
                }
            }
            os_log(
                "RECORDING_RESOURCE startupAudio systemBuffered=%{public}d systemDropped=%{public}d systemAppended=%{public}d micBuffered=%{public}d micDropped=%{public}d micAppended=%{public}d",
                log: recordingResourceLog,
                type: .info,
                systemAudio.samples.count,
                systemAudio.dropped,
                appendedSystemAudio,
                micAudio.samples.count,
                micAudio.dropped,
                appendedMicAudio)
        }
        // Only count frames that were actually written — finish() treats
        // frameCount == 0 as a failed/empty recording.
        if adaptor.append(buffer, withPresentationTime: presentationTime) {
            frameCount += 1
        }
    }

    private func adjustedTime(_ time: CMTime) -> CMTime {
        guard pauseOffset > 0 else { return time }
        return CMTimeSubtract(time, CMTimeMakeWithSeconds(pauseOffset, preferredTimescale: time.timescale))
    }
}
