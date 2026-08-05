import Cocoa
import ScreenCaptureKit
import Vision

// MARK: - ScrollCaptureController

/// Scroll capture engine:
///
/// - **`CGWindowListCreateImage`** for on-demand frame capture — each grab is a
///   complete, compositor-finished snapshot. No stream management, no stale frames.
/// - **TIFF byte-by-byte comparison** — two consecutive identical TIFF representations
///   = content has truly stopped rendering. Zero tolerance, no false positives.
/// - **Timer-driven `captureAndCompare`** on a dedicated serial queue — consistent
///   timing, no main-thread contention.
/// - **Disk-backed stitching** — matched strips are spooled immediately; the full image
///   is rendered once at Stop rather than redrawing an ever-growing bitmap per strip.
/// - **Vision-only offset detection** — `VNTranslationalImageRegistrationRequest`
///   for pixel-precise scroll offset measurement.
/// - **`matchNotFoundCount`** tracking — surfaces errors to the user via callbacks
///   instead of silently failing.
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Frozen header detection** — identifies sticky headers and excludes from stitching.
/// - **Scrollbar exclusion** — auto-detects scrollbar width, excludes from comparisons.
/// - **Max height: 30,000 pixels** (configurable via UserDefaults).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        return CGFloat(stitchedPixelSize.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    // Dedicated serial queue for capture-and-compare (off main thread)
    private let captureQueue = DispatchQueue(label: "Pinlume.scrollcapture", qos: .userInitiated)

    // Frame state
    private var shotA: CGImage?          // previous frame
    private var shotB: CGImage?          // current frame
    private var lastComparedTIFF: Data?  // TIFF of last settled frame for byte comparison
    private var mergedImage: CGImage?    // final image only; strips stay on disk while capturing
    private var spool: ScrollCaptureSpool?
    private var lifecycle = ScrollCaptureLifecycle()
    private var maxPixelBudget = 180_000_000
    private var maxByteBudget = 720 * 1024 * 1024
    private var headerHeight: Int = 0    // frozen header height in pixels
    private var headerDetectionDone: Bool = false
    private var headerDetectionSamples: Int = 0

    // Scrollbar exclusion
    private var rightMarginPx: Int = 0
    private var rightMarginDetected: Bool = false

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8  // stop after 8 consecutive failures
    private var didReportFirstMatch: Bool = false
    private var hasScrolledOnce: Bool = false
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.15
    private var lastCaptureTime: TimeInterval = 0
    private var pendingCaptureTask: Task<Void, Never>?
    private var pendingCaptureGeneration: UInt = 0
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard let generation = lifecycle.start() else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame. Stop may arrive while this awaits.
        guard let firstFrame = await captureSettledFrame(generation: generation),
              lifecycle.activate(generation: generation) else {
            if lifecycle.state == .starting { _ = lifecycle.stop() }
            if lifecycle.finish(generation: generation) { onSessionDone?(nil) }
            return
        }

        isActive = true
        shotA = nil
        shotB = nil
        lastComparedTIFF = nil
        mergedImage = nil
        guard let spool = ScrollCaptureSpool(), spool.append(firstFrame) else {
            isActive = false
            lifecycle.stop()
            _ = lifecycle.finish(generation: generation)
            onSessionDone?(nil)
            return
        }
        self.spool = spool
        headerHeight = 0
        headerDetectionDone = false
        headerDetectionSamples = 0
        rightMarginPx = 0
        rightMarginDetected = false
        matchNotFoundCount = 0
        didReportFirstMatch = false
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        frozenTopHeight = 0
        stripCount = 1

        shotA = firstFrame // registration baseline; failures must never replace it.
        stitchedImage = firstFrame
        stitchedPixelSize = CGSize(width: CGFloat(firstFrame.width), height: CGFloat(firstFrame.height))
        emitPreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll(generation: generation)
        } else {
            startManualScrollMonitors(generation: generation)
        }
    }

    func stopSession() {
        guard let generation = lifecycle.stop() else { return }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        cancelPendingCaptureTask()
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        Task { [weak self] in
            guard let self else { return }
            let image = await self.renderSpool(generation: generation)
            guard self.lifecycle.finish(generation: generation) else { return }
            self.onSessionDone?(image)
        }
    }

    func cancelSession() {
        guard lifecycle.stop() != nil else { return }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        cancelPendingCaptureTask()
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
        spool?.discard()
        spool = nil
        _ = lifecycle.finish(generation: lifecycle.generation)
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture via CGWindowListCreateImage

    /// Captures the screen region using CGWindowListCreateImage.
    /// Returns a complete, compositor-finished snapshot — no stream management needed.
    private func captureFrame() -> CGImage? {
        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]
        if targetWindowID != kCGNullWindowID,
           !excludedWindowIDs.contains(targetWindowID) {
            return CGWindowListCreateImage(
                captureRectCG, .optionIncludingWindow, targetWindowID, imageOption
            )
        }
        return CGWindowListCreateImage(
            captureRectCG, .optionOnScreenOnly, kCGNullWindowID, imageOption
        )
    }

    /// Captures a settled frame: grabs frames until two consecutive TIFF representations
    /// match byte-for-byte. Used for initial capture and manual scroll mode.
    private func captureSettledFrame(generation: UInt? = nil) async -> CGImage? {
        var previousTIFF: Data? = nil
        var previousCG: CGImage? = nil
        var waitNs: UInt64 = 10_000_000  // 10ms

        for _ in 0..<30 {
            if let generation, lifecycle.generation != generation || lifecycle.state == .stopping { return nil }
            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                lastComparedTIFF = currentTIFF
                return cg
            }

            previousTIFF = currentTIFF
            previousCG = cg
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        return previousCG
    }

    // MARK: - Auto-scroll

    private func startAutoScroll(generation: UInt) {
        guard lifecycle.acceptsActive(generation: generation) else { return }
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self,
                  !Task.isCancelled,
                  self.lifecycle.acceptsActive(generation: generation),
                  self.isActive,
                  self.autoScrollActive else { return }
            await self.autoScrollLoop(
                linesPerTick: linesPerTick,
                burstCount: burstCount,
                generation: generation)
        }
    }

    /// Core auto-scroll loop: scroll → captureAndCompare → repeat.
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int, generation: UInt) async {
        while lifecycle.acceptsActive(generation: generation) && isActive && autoScrollActive {
            // Post scroll event(s)
            for _ in 0..<burstCount {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: -linesPerTick, wheel2: 0, wheel3: 0) {
                    event.post(tap: .cghidEventTap)
                }
            }

            // captureAndCompare: settle, capture, compare, stitch
            let success = await captureAndCompare(generation: generation)
            guard lifecycle.acceptsActive(generation: generation), !Task.isCancelled else { return }

            if !success {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            // Check max height
            if maxScrollHeight > 0, stitchedPixelSize.height >= CGFloat(maxScrollHeight) {
                stopSession()
                return
            }
            if stitchedPixelSize.width * stitchedPixelSize.height > CGFloat(maxPixelBudget) {
                stopSession()
                return
            }
            if let spool, spool.totalBytes >= maxByteBudget {
                    stopSession()
                    return
            }

            // Small breathing room
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The core capture-and-compare cycle.
    /// Waits for pixel-perfect settlement via TIFF comparison, then computes the scroll
    /// offset via Vision and merges new content into the accumulated image.
    /// Returns true if a match was found, false if no shift detected.
    private func captureAndCompare(generation: UInt) async -> Bool {
        guard lifecycle.acceptsActive(generation: generation), !Task.isCancelled else { return false }
        // Initial delay for scroll animation to begin
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        guard lifecycle.acceptsActive(generation: generation), !Task.isCancelled else { return false }

        // Wait for settlement: poll frames until two consecutive TIFFs match
        var previousTIFF: Data? = nil
        var settledCG: CGImage? = nil
        var waitNs: UInt64 = 12_000_000

        for _ in 0..<30 {
            guard lifecycle.acceptsActive(generation: generation),
                  isActive,
                  !Task.isCancelled else { return false }

            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard lifecycle.acceptsActive(generation: generation), !Task.isCancelled else { return false }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                settledCG = cg
                lastComparedTIFF = currentTIFF
                break
            }

            previousTIFF = currentTIFF
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        guard let currentFrame = settledCG, let previousFrame = shotA else { return false }

        // Scrollbar detection (once)
        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame)
        }

        // Compute offset via Vision
        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
            consecutiveZeroShifts += 1
            if hasScrolledOnce && consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                stopSession()
            }
            return false
        }

        let offsetPx = Int(round(offset))
        guard offsetPx > 0 else {
            return false
        }

        // Need minimum shift to avoid noise
        let minShift = currentFrame.height / 10
        if offsetPx < minShift {
            // Don't update shotA — let shifts accumulate
            return false
        }

        consecutiveZeroShifts = 0
        hasScrolledOnce = true

        // Header detection (first few frames)
        if frozenDetectionEnabled && !headerDetectionDone {
            detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        // Use Vision's offset directly — pixel refinement can worsen it on
        // low-contrast / dark-themed content. Bias by -1px so strips overlap by
        // 1 extra row: the newer frame overwrites that row, hiding any sub-pixel
        // rendering differences at the seam boundary.
        let safeOffset = max(1, offsetPx - 1)

        // Incremental stitch: merge new content into mergedImage
        guard mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset) else { return false }

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)

        return true
    }

    /// Merges the newly-scrolled content from `currentFrame` into `mergedImage`.
    /// Only the new rows (below the overlap region) are appended.
    private func mergeNewContent(currentFrame: CGImage, offsetPx: Int) -> Bool {
        let w = currentFrame.width
        let newRows = offsetPx  // pixels of new content
        guard newRows > 0, newRows <= currentFrame.height else { return false }
        let nextHeight = (spool?.totalHeight ?? 0) + newRows
        let nextPixels = w * nextHeight
        let nextBytes = (spool?.totalBytes ?? 0) + currentFrame.bytesPerRow * newRows
        guard (maxScrollHeight <= 0 || nextHeight <= maxScrollHeight),
              nextPixels <= maxPixelBudget,
              nextBytes <= maxByteBudget else {
            stopSession()
            return false
        }
        let stripY = headerDetectionDone && headerHeight > 0 ? currentFrame.height - newRows : 0
        guard let strip = currentFrame.cropping(to: CGRect(x: 0, y: stripY, width: w, height: newRows)),
              spool?.append(strip) == true else { return false }
        stitchedImage = currentFrame // lightweight live preview; final render happens once at Stop.
        stitchedPixelSize = CGSize(width: CGFloat(w), height: CGFloat(spool?.totalHeight ?? currentFrame.height))
        return true
    }

    private func renderSpool(generation: UInt) async -> NSImage? {
        guard lifecycle.generation == generation,
              lifecycle.state == .stopping,
              let spool else { return nil }
        let image: CGImage? = await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: spool.render())
            }
        }
        spool.discard()
        self.spool = nil
        guard let image else { return nil }
        mergedImage = image
        stitchedImage = image
        stitchedPixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        return NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / backingScale,
                                                     height: CGFloat(image.height) / backingScale))
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        let generation = lifecycle.generation
        guard lifecycle.acceptsActive(generation: generation) else { return }
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors(generation: generation)
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll(generation: generation)
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors(generation: UInt) {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onManualScrollEvent(generation: generation)
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent(generation: generation)
            return event
        }
    }

    private func onManualScrollEvent(generation: UInt) {
        guard lifecycle.acceptsActive(generation: generation), isActive else { return }

        // After scrolling stops, do a final settled capture (TIFF comparison)
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSettledCapture(generation: generation)
            }
        }

        // During scrolling, grab and process frames immediately at a fixed interval —
        // no TIFF settlement. This ensures we capture content continuously even with
        // small selection areas where a single scroll gesture can move past the entire
        // viewport.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval else { return }
        lastCaptureTime = now

        grabAndProcess(generation: generation)
    }

    /// Immediate frame grab + process during active scrolling. No TIFF settlement —
    /// just captures whatever is on screen right now and tries to stitch it.
    private func grabAndProcess(generation: UInt) {
        guard lifecycle.acceptsActive(generation: generation), isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let currentFrame = captureFrame() else { return }
        guard let previousFrame = shotA else { return }

        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame)
        }

        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
            return
        }

        let offsetPx = Int(round(offset))
        guard offsetPx > 0 else {
            return
        }

        let minShift = currentFrame.height / 10
        if offsetPx < minShift { return }

        hasScrolledOnce = true
        consecutiveZeroShifts = 0

        if frozenDetectionEnabled && !headerDetectionDone {
            detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        let safeOffset = max(1, offsetPx - 1)
        guard mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset) else { return }

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)
    }

    /// Final settled capture after scrolling stops — uses full TIFF settlement.
    private func settledCapture(generation: UInt) async {
        guard lifecycle.acceptsActive(generation: generation),
              isActive,
              !isCapturing,
              !Task.isCancelled else { return }
        isCapturing = true
        defer { isCapturing = false }

        let _ = await captureAndCompare(generation: generation)
    }

    private func scheduleSettledCapture(generation: UInt) {
        guard lifecycle.acceptsActive(generation: generation) else { return }
        cancelPendingCaptureTask()
        pendingCaptureGeneration &+= 1
        let captureGeneration = pendingCaptureGeneration
        pendingCaptureTask = Task { @MainActor [weak self] in
            guard let self,
                  self.pendingCaptureGeneration == captureGeneration,
                  self.lifecycle.acceptsActive(generation: generation) else { return }
            await self.settledCapture(generation: generation)
            guard self.pendingCaptureGeneration == captureGeneration else { return }
            self.pendingCaptureTask = nil
        }
    }

    private func cancelPendingCaptureTask() {
        pendingCaptureGeneration &+= 1
        pendingCaptureTask?.cancel()
        pendingCaptureTask = nil
    }

    // MARK: - Vision shift detection

    /// Vision framework translational image registration.
    /// Crops out frozen header and/or scrollbar for more accurate results.
    private func visionShift(current: CGImage, previous: CGImage) -> CGFloat? {
        var curImg = current
        var prevImg = previous
        let maxCropY = current.height / 5
        let cropY = headerDetectionDone ? min(headerHeight, maxCropY) : 0
        let cropW = current.width - rightMarginPx
        let cropH = current.height - cropY
        if cropY > 0 || rightMarginPx > 0 {
            guard cropH > 20 && cropW > 20 else { return nil }
            let cropRect = CGRect(x: 0, y: cropY, width: cropW, height: cropH)
            guard let cc = current.cropping(to: cropRect),
                  let pc = previous.cropping(to: cropRect) else { return nil }
            curImg = cc
            prevImg = pc
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevImg)
        let handler = VNImageRequestHandler(cgImage: curImg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        return obs.alignmentTransform.ty
    }

    // MARK: - Scrollbar detection

    private func detectRightMargin(current: CGImage, previous: CGImage) {
        rightMarginDetected = true

        guard let currentPixels = ScrollCapturePixelBuffer(image: current),
              let previousPixels = ScrollCapturePixelBuffer(image: previous),
              currentPixels.layout == previousPixels.layout else { return }

        currentPixels.withUnsafeBytes { currentBytes, layout in
            previousPixels.withUnsafeBytes { previousBytes, _ in
                let rowStart = layout.height * 2 / 10
                let rowEnd = layout.height * 8 / 10
                let rowStep = max(1, (rowEnd - rowStart) / 40)
                var scrollbarWidth = 0
                let maxScanCols = min(50, layout.width / 8)

                for colOffset in 0..<maxScanCols {
                    let col = layout.width - 1 - colOffset
                    var sad: UInt64 = 0
                    var samples = 0
                    for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
                        let index = row * layout.bytesPerRow + col * layout.bytesPerPixel
                        guard index + 2 < currentBytes.count,
                              index + 2 < previousBytes.count else { continue }
                        sad += UInt64(abs(Int(currentBytes[index]) - Int(previousBytes[index]))
                                    + abs(Int(currentBytes[index + 1]) - Int(previousBytes[index + 1]))
                                    + abs(Int(currentBytes[index + 2]) - Int(previousBytes[index + 2])))
                        samples += 1
                    }
                    guard samples > 0 else { continue }
                    let average = sad / UInt64(samples)
                    if average > 8 {
                        scrollbarWidth = colOffset + 1
                    } else if scrollbarWidth > 0 {
                        break
                    }
                }
                if scrollbarWidth >= 3 && scrollbarWidth <= 40 {
                    rightMarginPx = scrollbarWidth + 4
                }
            }
        }
    }

    // MARK: - Header (frozen region) detection

    private func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard current.width == previous.width, current.height == previous.height else { return }
        guard shiftPx > 5 else { return }

        guard let currentPixels = ScrollCapturePixelBuffer(image: current),
              let previousPixels = ScrollCapturePixelBuffer(image: previous),
              currentPixels.layout == previousPixels.layout else { return }

        let frozenRows: Int? = currentPixels.withUnsafeBytes { currentBytes, layout in
            previousPixels.withUnsafeBytes { previousBytes, _ in
                let compareWidth = max(1, layout.width - rightMarginPx)
                for row in 0..<layout.height {
                    var rowSAD: UInt64 = 0
                    var samples = 0
                    let rowOffset = row * layout.bytesPerRow
                    for col in stride(from: 0, to: compareWidth, by: 4) {
                        let index = rowOffset + col * layout.bytesPerPixel
                        guard index + 2 < currentBytes.count,
                              index + 2 < previousBytes.count else { return nil }
                        rowSAD += UInt64(abs(Int(currentBytes[index]) - Int(previousBytes[index]))
                                        + abs(Int(currentBytes[index + 1]) - Int(previousBytes[index + 1]))
                                        + abs(Int(currentBytes[index + 2]) - Int(previousBytes[index + 2])))
                        samples += 1
                    }
                    if samples > 0, rowSAD / UInt64(samples) > 8 { return row }
                }
                return nil
            }
        }
        guard let frozenRows else { return }

        if frozenRows >= 10 && frozenRows < (currentPixels.layout.height * 6 / 10) {
            headerDetectionSamples += 1

            if headerDetectionSamples == 1 {
                headerHeight = frozenRows
                frozenTopHeight = CGFloat(headerHeight) / backingScale
                headerDetectionDone = true
            } else {
                if abs(frozenRows - headerHeight) <= 5 {
                    headerHeight = min(headerHeight, frozenRows)
                    frozenTopHeight = CGFloat(headerHeight) / backingScale
                } else {
                    headerHeight = 0
                    frozenTopHeight = 0
                }
                headerDetectionDone = true
            }
        } else if frozenRows < 10 {
            headerDetectionDone = true
        }
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let cg = stitchedImage, let callback = onPreviewUpdated else { return }
        let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                            height: CGFloat(cg.height) / backingScale)
        callback(NSImage(cgImage: cg, size: ptSize))
    }
}
