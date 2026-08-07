import Cocoa
import Carbon
import UniformTypeIdentifiers
import AVFoundation
import Vision
import WebP

import os.log

private let timingLog = OSLog(subsystem: AppIdentity.bundleIdentifier, category: "capture-timing")

/// Metadata-only origin for a screen-capture request. Never contains image,
/// OCR, clipboard, window-title, or user-input data.
private enum CaptureTrigger: String {
    case menu
    case hotkey
    case urlScheme = "url-scheme"
}

private extension CaptureMenuItemID {
    enum Section: Int {
        case capture
        case recording
        case history
        case files
        case pins
    }

    var title: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .transparentAnnotation: return L("Transparent Annotation")
        case .presentationDrawing: return L("Presentation Drawing")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .selectableOCRCapture: return L("Selectable Text Capture")
        case .translationWindow: return L("Translation Window")
        case .screenTranslationCapture: return L("Screen Translation Capture")
        case .quickCapture: return L("Quick Capture")
        case .captureLastArea: return L("Capture Last Area")
        case .scrollCapture: return L("Scroll Capture")
        case .captureDelay: return L("Capture Delay")
        case .recordArea: return L("Record Area")
        case .recordScreen: return L("Record Screen")
        case .recentCaptures: return L("Recent Captures")
        case .historyOverlay: return L("Show History Panel")
        case .openImage: return L("Open Image...")
        case .openVideo: return L("Open Video...")
        case .openFromClipboard: return L("Open from Clipboard")
        case .pinFromClipboard: return L("Pin from Clipboard")
        case .toggleAllPins: return L("Hide/Show All Pins")
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .transparentAnnotation: return "pencil.and.outline"
        case .presentationDrawing: return "pencil.tip.crop.circle"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .selectableOCRCapture: return "text.cursor"
        case .translationWindow: return "translate"
        case .screenTranslationCapture: return "character.book.closed"
        case .quickCapture: return "square.and.arrow.down"
        case .captureLastArea: return "arrow.counterclockwise.circle"
        case .scrollCapture: return "scroll"
        case .captureDelay: return "timer"
        case .recordArea: return "record.circle"
        case .recordScreen: return "menubar.dock.rectangle"
        case .recentCaptures: return "clock.arrow.circlepath"
        case .historyOverlay: return "square.grid.2x2"
        case .openImage: return "photo.on.rectangle.angled"
        case .openVideo: return "film"
        case .openFromClipboard: return "doc.on.clipboard"
        case .pinFromClipboard: return "pin.fill"
        case .toggleAllPins: return "pin.slash"
        }
    }

    var hotkeySlot: HotkeyManager.HotkeySlot? {
        switch self {
        case .captureArea: return .captureArea
        case .transparentAnnotation: return .transparentAnnotation
        case .presentationDrawing: return .presentationDrawing
        case .captureScreen: return .captureFullScreen
        case .captureOCR: return .captureOCR
        case .selectableOCRCapture: return .selectableOCRCapture
        case .translationWindow: return .translationWindow
        case .screenTranslationCapture: return .screenTranslationCapture
        case .quickCapture: return .quickCapture
        case .captureLastArea: return .captureLastArea
        case .scrollCapture: return .scrollCapture
        case .recordArea: return .recordArea
        case .recordScreen: return .recordScreen
        case .historyOverlay: return .historyOverlay
        case .openFromClipboard: return .openFromClipboard
        case .pinFromClipboard: return .pinFromClipboard
        case .toggleAllPins: return .toggleAllPins
        case .captureDelay, .recentCaptures, .openImage, .openVideo:
            return nil
        }
    }

    var section: Section {
        switch self {
        case .captureArea, .transparentAnnotation, .presentationDrawing, .captureScreen, .captureOCR, .selectableOCRCapture, .translationWindow, .screenTranslationCapture, .quickCapture, .captureLastArea, .scrollCapture, .captureDelay:
            return .capture
        case .recordArea, .recordScreen:
            return .recording
        case .recentCaptures, .historyOverlay:
            return .history
        case .openImage, .openVideo, .openFromClipboard:
            return .files
        case .pinFromClipboard, .toggleAllPins:
            return .pins
        }
    }
}

// MARK: - Signal-safe diagnostic logging

/// Async-signal-safe write(2)-only log fd for Jetsam/SIGTERM diagnostics.
/// Opened at launch in `AppDelegate.setupSignalHandlers()` and written to
/// by `sigtermHandler` when the system sends SIGTERM before SIGKILL.
private var pinlumeSignalLogFd: Int32 = -1

/// Async-signal-safe SIGTERM handler. Writes a one-line diagnostic to the
/// pre-opened `pinlumeSignalLogFd`, then resets the handler to default and
/// re-raises so `applicationWillTerminate` runs the normal cleanup path.
private let sigtermHandler: @convention(c) (Int32) -> Void = { _ in
    guard pinlumeSignalLogFd >= 0 else {
        signal(SIGTERM, SIG_DFL)
        return
    }
    // Only async-signal-safe operations below.
    let msg: StaticString = "SIGTERM received — likely Jetsam memory-pressure kill\n"
    _ = write(pinlumeSignalLogFd, msg.utf8Start, msg.utf8CodeUnitCount)
    _ = close(pinlumeSignalLogFd)
    pinlumeSignalLogFd = -1
    // Re-raise with default handler so applicationWillTerminate runs.
    signal(SIGTERM, SIG_DFL)
    kill(getpid(), SIGTERM)
}

private final class CaptureTimingTrace: @unchecked Sendable {
    private struct Entry {
        let label: String
        let elapsed: TimeInterval
        let delta: TimeInterval
        let thread: String
    }

    private let lock = NSLock()
    private let startTime: CFAbsoluteTime
    private var lastTime: CFAbsoluteTime
    private var entries: [Entry] = []

    init(startAbsoluteTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.startTime = startAbsoluteTime
        self.lastTime = startAbsoluteTime
        os_log("=== TRACE START ===", log: timingLog, type: .info)
    }

    func mark(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let entry = Entry(
            label: label,
            elapsed: now - startTime,
            delta: now - lastTime,
            thread: Thread.isMainThread ? "main" : "bg")
        entries.append(entry)
        lastTime = now
        lock.unlock()
        os_log("%{public}.1fms (+%{public}.1f) [%{public}@] %{public}@",
               log: timingLog, type: .info,
               entry.elapsed * 1000, entry.delta * 1000, entry.thread, label)
    }

    func measure<T>(_ label: String, _ work: () -> T) -> T {
        mark("\(label) begin")
        let result = work()
        mark("\(label) end")
        return result
    }

    func report(finalLabel: String) -> String {
        mark(finalLabel)

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let total = snapshot.last?.elapsed ?? 0
        var lines: [String] = []
        lines.append("Pinlume capture timing — total: \(Self.format(total))")
        lines.append("")
        lines.append(" elapsed    delta  thread  event")
        lines.append("-----------------------------------------------")
        for entry in snapshot {
            lines.append(String(
                format: "%8.1f  %7.1f  %-6@  %@",
                entry.elapsed * 1000,
                entry.delta * 1000,
                entry.thread as NSString,
                entry.label as NSString))
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1000)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayControllers: [OverlayWindowController] = []
    private var settingsController: SettingsWindowController?
    private var effectiveAppearanceObservation: NSKeyValueObservation?
    private lazy var settingsProfileRuntimeCoordinator = SettingsProfileRuntimeCoordinator(
        refreshActions: .init(
            reregisterGlobalHotkeys: { [weak self] in self?.registerHotkey() },
            rebuildStatusMenu: { [weak self] in self?.rebuildStatusBarMenu() }
        )
    )
    private var onboardingController: PermissionOnboardingController?
    private var pinControllers: [PinWindowController] = []
    private var pinPersistenceSession: PinPersistenceSession?
    private var transparentAnnotationSession: TransparentAnnotationSessionController?
    private var presentationDrawingSession: TransparentAnnotationSessionController?
    private var transparentAnnotationPins: [TransparentAnnotationPinController] = []
    private var allPinsHidden = false
    private var shouldPersistPinsOnTerminate = true
    private var thumbnailControllers: [FloatingThumbnailController] = []
    private var ocrController: OCRResultController?
    private var translationWindowController: TranslationWindowController?
    private var screenTranslationController: ScreenTranslationWindowController?
    private var screenTranslationState = ScreenTranslationSessionState()
    private var historyMenu: NSMenu?
    private var historyOverlayController: HistoryOverlayController?
    private var isCapturing = false
    private var idleUIWarmupTask: DispatchWorkItem?
    private var didCompleteIdleUIWarmup = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var delayEscMonitor: Any?
    #if !OFFLINE
    private var uploadToastController: UploadToastController?
    private var uploadOverlaySession = UploadOverlaySession()
    private weak var uploadOverlaySource: OverlayWindowController?
    #endif
    private var recordingEngine: RecordingEngine?
    private var recordingLifecycle = RecordingLifecycle()
    private var recordingTerminationPending = false
    private var audioMergeController: AudioMergeController?
    private var recordingOverlayController: OverlayWindowController?
    private var recordingHUDPanel: RecordingHUDPanel?
    private weak var recordingStatusMenuItem: NSMenuItem?
    private var recordingElapsedSeconds = 0
    private var recordingScreenRect: NSRect = .zero  // screen-space capture rect
    private var recordingScreen: NSScreen?
    private var mouseHighlightOverlay: MouseHighlightOverlay?
    private var keystrokeOverlay: KeystrokeOverlay?
    private var webcamOverlay: WebcamOverlay?
    private var selectionBorderOverlay: SelectionBorderOverlay?
    private var menuBarIconWasHidden: Bool = false  // restore after recording if user had it hidden
    private var scrollCaptureController: ScrollCaptureController?
    /// The overlay controller whose selection is being scroll-captured.
    private var scrollCaptureOverlayController: OverlayWindowController?
    private var scrollCapturePreviewPanel: ScrollCapturePreviewPanel?
    private var statusBarMenu: NSMenu?
    private var captureSessionID: UInt = 0
    private var captureTimingTrace: CaptureTimingTrace?
    private var globalHotkeysEnabled = true
    /// App Nap suppression assertion. Held for the app's lifetime so global
    /// hotkeys respond instantly instead of paying a wake-up penalty when
    /// Pinlume has been idle. Use the idle-sleep-safe variant: plain
    /// `.userInitiated` creates a `PreventUserIdleSystemSleep` assertion and
    /// keeps Macs awake indefinitely.
    private var appNapAssertion: NSObjectProtocol?

    /// Shared capture sound — loaded once, reused everywhere.
    static let captureSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Prevent multiple instances — if already running, activate the existing one and quit
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
        let duplicateLaunchNotification = ApplicationInstanceNotification.duplicateLaunchNotificationName(
            bundleIdentifier: bundleID)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            shouldPersistPinsOnTerminate = false
            // Tell the existing instance to show its icon and open Settings
            DistributedNotificationCenter.default().postNotificationName(
                duplicateLaunchNotification,
                object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        bootstrapSettingsProfileIfNeeded()
        ApplicationAppearancePreference.applyCurrent()
        ToolbarColorScheme.bootstrapIfNeeded(appearance: NSApp.effectiveAppearance)
        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            ToolbarColorScheme.applyCurrentAppearance(appearance: NSApp.effectiveAppearance)
        }

        // Disable App Nap. Pinlume is LSUIElement with no visible windows
        // when idle, so macOS can add wake-up latency to global hotkey
        // captures. The "allowing idle system sleep" variant keeps the
        // responsiveness hint without creating a PreventUserIdleSystemSleep
        // assertion that blocks normal sleep.
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Global hotkey responsiveness")

        DiagnosticLogStore.cleanupLegacyLogs()

        // Open a signal-safe log fd and register the SIGTERM handler.
        // When macOS Jetsam kills the process, any SIGTERM sent before
        // SIGKILL is captured here, and the re-raise ensures
        // applicationWillTerminate also fires — giving us two diagnostic
        // traces to distinguish Jetsam kills from normal termination.
        setupSignalHandlers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(diagnosticLoggingDidChange),
            name: DiagnosticLogStore.loggingDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(yieldTransientInteractionsForGlobalHotkey(_:)),
            name: .transientInteractionMustYield,
            object: nil
        )

        // Offer to move to /Applications if running from a DMG or translocated path
        promptToMoveToApplicationsIfNeeded()

        migrateFilenameTemplateIfNeeded()

        // Touch the retained clipboard backing directory before cleanup so it
        // exists for both the sweeper and the first screenshot copy.
        _ = ClipboardBackingStore.directory

        // Reclaim disk from stale tmp leftovers (cancelled recordings,
        // legacy clipboard PNGs, share-sheet scratch). Runs off the main
        // thread so it can't delay launch.
        LaunchCleanup.runAll()

        // Force-init the history singleton so its launch-time orphan
        // prune runs even if the user doesn't take a screenshot this
        // session. Without this, the prune only fires the first time
        // something references ScreenshotHistory.shared.
        _ = ScreenshotHistory.shared

        setupMainMenu()
        setupStatusBar()
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            setMenuBarIconVisible(false)
        }
        registerHotkey()
        // Pre-warm CoreAudio so the first capture sound doesn't stall ~1s.
        if let sound = Self.captureSound {
            sound.volume = 0
            sound.play()
            sound.stop()
            sound.volume = 1
        }

        // Listen for duplicate-launch notification to restore icon
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowAndOpenPrefs),
            name: duplicateLaunchNotification, object: nil
        )

        // Dismiss overlays when the user switches spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Pin from history panel
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinFromHistory(_:)),
            name: .init("Pinlume.pinFromHistory"), object: nil
        )

        restorePersistedPins()
        scheduleIdleUIWarmup()

        // Check screen recording permission. If not yet granted, show the
        // custom onboarding window instead of letting macOS throw its own dialogs.
        PermissionOnboardingController.checkPermissionSync { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.prewarmCapturePath()
            } else {
                self.showOnboarding()
            }
        }
    }

    /// New installs have no saved runtime preferences yet. Create the two
    /// protected profiles and apply Slim before menus or hotkeys read any
    /// defaults, so the visible selected profile and live shortcuts agree.
    private func bootstrapSettingsProfileIfNeeded() {
        do {
            let bridge = SettingsProfilePreferenceBridge()
            let result = try SettingsProfileStore().loadOrCreateResult(
                from: .standard,
                currentPayload: bridge.snapshotCurrentPreferences().payload
            )
            guard result.createdNewDocument || (result.migratedExistingDocument && result.document.activeProfile.kind != .custom) else { return }
            let profile = result.document.activeProfile
            try settingsProfileRuntimeCoordinator.preflightHotkeys(profile.payload)
            try SettingsProfileApplyCoordinator().apply(profile)
        } catch {
            // Leave the app's ordinary defaults intact if a future schema
            // migration cannot be completed; Settings can surface recovery.
        }
    }

    private func showOnboarding() {
        // If already open, just bring it to front
        if let existing = onboardingController {
            existing.show()
            return
        }
        let oc = PermissionOnboardingController()
        oc.onPermissionGranted = { [weak self] in
            self?.onboardingController = nil
            self?.prewarmCapturePath()
            self?.scheduleIdleUIWarmup()
        }
        onboardingController = oc
        oc.show()
    }

    private func prewarmCapturePath() {
        // Warm the SCShareableContent cache (cheap, async).
        ScreenCaptureManager.prewarm()
        // Build (or rebuild) the per-screen overlay controller pool. Each
        // controller owns a permanent NSPanel; on hotkey we reuse it rather
        // than creating fresh. This is what keeps captures fast — WindowServer
        // caches composition state per-window, and reused windows stay hot.
        rebuildOverlayPool()
    }

    /// Create reusable, image-free UI only after the capture path has had a
    /// chance to become ready. A global shortcut cancels this work before a
    /// capture begins, and the next idle period retries it after dismissal.
    private func scheduleIdleUIWarmup() {
        guard !didCompleteIdleUIWarmup, idleUIWarmupTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            self?.performIdleUIWarmup()
        }
        idleUIWarmupTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func cancelIdleUIWarmup() {
        idleUIWarmupTask?.cancel()
        idleUIWarmupTask = nil
    }

    private func performIdleUIWarmup() {
        idleUIWarmupTask = nil
        guard !isCapturing,
              recordingLifecycle.state == .idle,
              overlayControllers.isEmpty,
              onboardingController == nil,
              NSApp.modalWindow == nil
        else { return }

        _ = ensureSettingsController()
        if CaptureMenuItemID.isEnabled(.translationWindow) {
            let controller = translationWindowController ?? TranslationWindowController()
            translationWindowController = controller
            controller.prewarm()
        }
        didCompleteIdleUIWarmup = true
    }

    /// Persistent per-screen overlay controller pool. Held for the app's
    /// lifetime so each panel's CGSWindow stays alive in WindowServer.
    /// Rebuilt on screen-config change.
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]

    private func rebuildOverlayPool() {
        // Tear down stale controllers (screens removed, etc.) before rebuilding.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        for screen in NSScreen.screens {
            let controller = OverlayWindowController(screen: screen)
            overlayControllerPool[ObjectIdentifier(screen)] = controller
            // Warm the panel: brief invisible orderFront so WindowServer
            // allocates the surface + composes one frame. This is what the
            // first real capture would otherwise pay.
            controller.warmPanel()
        }
    }

    private func pooledController(for screen: NSScreen) -> OverlayWindowController {
        if let existing = overlayControllerPool[ObjectIdentifier(screen)] {
            return existing
        }
        // New screen showed up between prewarms — create on demand.
        let controller = OverlayWindowController(screen: screen)
        overlayControllerPool[ObjectIdentifier(screen)] = controller
        controller.warmPanel()
        return controller
    }

    @objc private func systemDidWake() {
        guard !isCapturing, recordingLifecycle.state == .idle else { return }
        prewarmCapturePath()
    }

    @objc private func screenParametersDidChange() {
        guard !isCapturing, recordingLifecycle.state == .idle else { return }
        prewarmCapturePath()
    }

    /// Captured at the very start of every hotkey callback (before main thread
    /// dispatch hop). Lets the trace include runloop wake-up delay that
    /// happens BEFORE startCapture runs.
    var pendingCaptureEntryTime: CFAbsoluteTime?

    private func makeCaptureTimingTrace() -> CaptureTimingTrace? {
        guard DiagnosticLogStore.isEnabled else {
            pendingCaptureEntryTime = nil
            return nil
        }
        let start = pendingCaptureEntryTime ?? CFAbsoluteTimeGetCurrent()
        pendingCaptureEntryTime = nil
        return CaptureTimingTrace(startAbsoluteTime: start)
    }

    private func measureCaptureTiming<T>(_ label: String, _ work: () -> T) -> T {
        if let trace = captureTimingTrace {
            return trace.measure(label, work)
        }
        return work()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-launching Pinlume while it's running: show the menu bar icon
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        // Only open settings if no windows are visible (e.g. pure menu-bar state).
        // If editor/video editor is already open, just bring the app to the front.
        if !flag {
            openSettings()
        }
        return false
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Dock menu shown on right-click of the Dock icon.
    ///
    /// macOS only auto-populates the Dock menu's window list for document-based
    /// apps (apps using `NSDocumentController`). Our editor windows aren't
    /// documents, so we build the list ourselves: each visible titled window
    /// gets an entry that brings that specific window forward when clicked.
    /// Without this users only see "Show All Windows" and can't jump directly
    /// to a particular editor session.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let windows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !windows.isEmpty else { return nil }
        let menu = NSMenu()
        // Sort by title so the menu order is stable across dock-menu openings.
        for window in windows.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(
                title: window.title.isEmpty ? L("Untitled") : window.title,
                action: #selector(activateWindowFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = window
            if window.isMiniaturized {
                // Visual cue so users know clicking will also de-minimize.
                item.state = .mixed
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func activateWindowFromDockMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One-shot migration from the legacy `useWindowTitleInFilename` checkbox
    /// to the new `filenameTemplate` string. Runs once — seeds the template
    /// from the old bool then clears the legacy key.
    private func migrateFilenameTemplateIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: FilenameFormatter.userDefaultsKey) == nil else { return }
        let hadWindowTitle = d.bool(forKey: "useWindowTitleInFilename")
        let template = hadWindowTitle
            ? "Screenshot {date} at {time} — {window}"
            : FilenameFormatter.defaultTemplate
        d.set(template, forKey: FilenameFormatter.userDefaultsKey)
        d.removeObject(forKey: "useWindowTitleInFilename")
    }

    /// If the app is running from a DMG volume or a translocated path,
    /// offer to move it to /Applications for stable permissions, preferences,
    /// and to avoid App Translocation.
    private func promptToMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let isOnDMG = bundlePath.hasPrefix("/Volumes/")
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        guard isOnDMG || isTranslocated else { return }
        guard !UserDefaults.standard.bool(forKey: "suppressMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = L("Move to Applications folder?")
        alert.informativeText = String(
            format: L("%@ is running from a disk image. Move it to your Applications folder for stable permissions and the best experience."),
            BuildVariant.displayName
        )
        alert.addButton(withTitle: L("Move to Applications"))
        alert.addButton(withTitle: L("Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don't ask again")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressMoveToApplications")
        }
        guard response == .alertFirstButtonReturn else { return }

        let dest = URL(fileURLWithPath: "/Applications/\(BuildVariant.displayName).app")
        let src = URL(fileURLWithPath: bundlePath)
        do {
            // Remove old version if present
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", dest.path]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = L("Could not move to Applications")
            errAlert.informativeText = String(
                format: L("Please drag Pinlume to your Applications folder manually.\n\n%@"),
                error.localizedDescription
            )
            errAlert.runModal()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        os_log(.fault, log: timingLog, "Pinlume terminating — thermalState=%d", ProcessInfo.processInfo.thermalState.rawValue)
        NotificationCenter.default.removeObserver(
            self,
            name: .transientInteractionMustYield,
            object: nil
        )
        if shouldPersistPinsOnTerminate {
            savePersistedPins()
        }
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        HotkeyManager.shared.unregister()
        closeSignalLog()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch recordingLifecycle.state {
        case .idle:
            return .terminateNow
        case .countdown:
            cancelRecordingCountdown()
            return .terminateNow
        case .starting, .recording, .paused, .stopping:
            recordingTerminationPending = true
            stopRecording()
            return .terminateLater
        }
    }

    // MARK: - Signal Handlers

    /// Opens a write-only log fd and registers the SIGTERM handler.
    /// The fd is used by the signal handler (which can only call
    /// async-signal-safe functions; os_log is NOT safe in that context).
    private func setupSignalHandlers() {
        closeSignalLog()
        guard DiagnosticLogStore.isEnabled else { return }
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Pinlume", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = DiagnosticLogStore.terminationLogURL
        pinlumeSignalLogFd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        signal(SIGTERM, sigtermHandler)
    }

    private func closeSignalLog() {
        if pinlumeSignalLogFd >= 0 {
            close(pinlumeSignalLogFd)
            pinlumeSignalLogFd = -1
        }
        signal(SIGTERM, SIG_DFL)
    }

    @objc private func diagnosticLoggingDidChange() {
        setupSignalHandlers()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu (required when no storyboard)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Pinlume"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L("Quit Pinlume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()
    }

    // User-customizable menu bar icon (see Settings → General → Appearance).
    // Mode is "default" (bundled StatusBarIcon asset) or "symbol" (a user-chosen SF Symbol).
    static let statusBarIconModeKey = "statusBarIconMode"
    static let statusBarIconSymbolNameKey = "statusBarIconSymbolName"

    private func applyNormalStatusBarIcon() {
        if let button = statusItem.button {
            applyPreferredIconImage(to: button)
            // Use the NATIVE status-item menu (no custom click action). Showing
            // the menu by synthesizing a click from the button's mouse-down
            // action re-enters AppKit's mouse-tracking loop and can hang the main
            // thread (which also kills the global hotkey). The menu's delegate
            // handles modal dismissal + prewarm in menuWillOpen instead.
            button.target = nil
            button.action = nil
            statusItem.menu = statusBarMenu
        }
    }

    /// Sets the button image/title from the user's icon preference. "symbol" mode renders
    /// the chosen SF Symbol as a 22pt template image; anything else — including an empty or
    /// invalid symbol name — falls back to the bundled icon so the item is never blank.
    private func applyPreferredIconImage(to button: NSStatusBarButton) {
        let mode = UserDefaults.standard.string(forKey: Self.statusBarIconModeKey) ?? "default"
        let symbolName = UserDefaults.standard.string(forKey: Self.statusBarIconSymbolNameKey) ?? ""

        if mode == "symbol", !symbolName.isEmpty,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pinlume") {
            symbol.isTemplate = true
            symbol.size = NSSize(width: 22, height: 22)
            button.image = symbol
            button.title = ""
        } else if let img = NSImage(named: "StatusBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 22, height: 22)
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = BuildVariant.displayName
        }
    }

    /// Re-applies the menu bar icon to reflect the user's current preference. Invoked live
    /// from Settings so changes take effect without a relaunch. No-op while recording — the
    /// recording state owns the icon then and restores the preferred one when it ends.
    func refreshStatusBarIcon() {
        guard recordingLifecycle.state == .idle, let button = statusItem.button else { return }
        applyPreferredIconImage(to: button)
    }

    private func rebuildStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        self.historyMenu = nil
        self.recordingStatusMenuItem = nil
        if recordingLifecycle.state != .idle {
            addRecordingStatusMenuItems(to: menu)
        }
        addStatusMenuItems(CaptureMenuItemID.primaryItems(), to: menu)

        let moreItems = CaptureMenuItemID.moreItems().filter { CaptureMenuItemID.isEnabled($0) }
        if !moreItems.isEmpty {
            addSeparatorIfNeeded(to: menu)
            let moreItem = NSMenuItem(title: L("More Tools"), action: nil, keyEquivalent: "")
            moreItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            let moreMenu = NSMenu()
            moreMenu.autoenablesItems = false
            addStatusMenuItems(moreItems, to: moreMenu)
            moreItem.submenu = moreMenu
            menu.addItem(moreItem)
        }

        addSeparatorIfNeeded(to: menu)

        let hotkeyToggleTitle = globalHotkeysEnabled ? L("Disable Hotkeys") : L("Enable Hotkeys")
        let hotkeyToggle = NSMenuItem(title: hotkeyToggleTitle, action: #selector(toggleGlobalHotkeys), keyEquivalent: "")
        hotkeyToggle.target = self
        hotkeyToggle.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(hotkeyToggle)

        addSeparatorIfNeeded(to: menu)

        let prefsItem = NSMenuItem(title: L("Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        prefsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(prefsItem)

        let versionItem = NSMenuItem(title: appVersionMenuTitle(), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitTitle = L("Quit Pinlume").replacingOccurrences(of: "Pinlume", with: BuildVariant.displayName)
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self  // menuWillOpen dismisses any modal + prewarms capture
        statusBarMenu = menu
        statusItem?.button?.target = nil
        statusItem?.button?.action = nil
        statusItem?.menu = menu
    }

    private func addRecordingStatusMenuItems(to menu: NSMenu) {
        let status = NSMenuItem(title: recordingStatusTitle(), action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)
        recordingStatusMenuItem = status

        let stop = NSMenuItem(title: L("Stop Recording"), action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        menu.addItem(stop)
        menu.addItem(NSMenuItem.separator())
    }

    private func recordingStatusTitle() -> String {
        String(
            format: "%@ %02d:%02d",
            L("Recording"),
            recordingElapsedSeconds / 60,
            recordingElapsedSeconds % 60
        )
    }

    private func addStatusMenuItems(_ itemIDs: [CaptureMenuItemID], to menu: NSMenu) {
        var previousSection: CaptureMenuItemID.Section?
        for itemID in itemIDs where CaptureMenuItemID.isEnabled(itemID) {
            if let previousSection, previousSection != itemID.section {
                addSeparatorIfNeeded(to: menu)
            }
            menu.addItem(makeStatusMenuItem(itemID))
            previousSection = itemID.section
        }
    }

    private func addSeparatorIfNeeded(to menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(NSMenuItem.separator())
    }

    private func appVersionMenuTitle() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        if build == version || build == "?" {
            return "\(BuildVariant.displayName) \(version)"
        }
        return "\(BuildVariant.displayName) \(version) (\(build))"
    }

    private func makeStatusMenuItem(_ itemID: CaptureMenuItemID) -> NSMenuItem {
        if itemID == .captureDelay {
            return makeCaptureDelayMenuItem()
        }
        if itemID == .recentCaptures {
            return makeRecentCapturesMenuItem()
        }

        let action: Selector
        switch itemID {
        case .captureArea: action = #selector(captureScreen)
        case .transparentAnnotation: action = #selector(startTransparentAnnotationFromMenu)
        case .presentationDrawing: action = #selector(startPresentationDrawingFromMenu)
        case .captureScreen: action = #selector(captureFullScreen)
        case .captureOCR: action = #selector(captureOCR)
        case .selectableOCRCapture: action = #selector(selectableOCRCapture)
        case .translationWindow: action = #selector(showTranslationWindow)
        case .screenTranslationCapture: action = #selector(screenTranslationCapture)
        case .quickCapture: action = #selector(quickCapture)
        case .captureLastArea: action = #selector(captureLastArea)
        case .scrollCapture: action = #selector(scrollCapture)
        case .recordArea: action = #selector(recordArea)
        case .recordScreen: action = #selector(recordFullScreen)
        case .historyOverlay: action = #selector(showHistoryOverlay)
        case .openImage: action = #selector(openImageFromMenu)
        case .openVideo: action = #selector(openVideoFromMenu)
        case .openFromClipboard: action = #selector(openImageFromClipboard)
        case .pinFromClipboard: action = #selector(pinFromClipboard)
        case .toggleAllPins: action = #selector(toggleAllPinsVisibility)
        case .captureDelay, .recentCaptures:
            action = #selector(captureScreen)
        }

        let title = itemID == .toggleAllPins
            ? (allPinsHidden ? L("Show All Pins") : L("Hide All Pins"))
            : itemID.title
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: itemID.symbolName, accessibilityDescription: nil)
        if recordingLifecycle.state != .idle {
            switch itemID {
            case .recordArea, .recordScreen:
                item.isEnabled = false
            default:
                break
            }
        }
        if globalHotkeysEnabled, let hotkeySlot = itemID.hotkeySlot {
            HotkeyManager.applyMenuShortcut(for: hotkeySlot, to: item)
        }
        return item
    }

    private func makeCaptureDelayMenuItem() -> NSMenuItem {
        let delayItem = NSMenuItem(title: L("Capture Delay"), action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let delaySubmenu = NSMenu()
        delaySubmenu.autoenablesItems = false
        let currentDelay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        for seconds in [0, 3, 5, 10, 30] {
            let title = seconds == 0 ? L("None") : String(format: L("%d seconds"), seconds)
            let item = NSMenuItem(title: title, action: #selector(setDelaySeconds(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == currentDelay ? .on : .off
            delaySubmenu.addItem(item)
        }
        delayItem.submenu = delaySubmenu
        return delayItem
    }

    private func makeRecentCapturesMenuItem() -> NSMenuItem {
        let historyItem = NSMenuItem(title: L("Recent Captures"), action: nil, keyEquivalent: "")
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let historySubmenu = NSMenu()
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        self.historyMenu = historySubmenu
        return historyItem
    }

    // MARK: - Hotkey

    @objc private func yieldTransientInteractionsForGlobalHotkey(_ notification: Notification) {
        let modifierFlags = NSEvent.modifierFlags
        pinControllers.forEach {
            $0.yieldTransientInteraction(modifierFlags: modifierFlags)
        }
        overlayControllers.forEach {
            $0.yieldTransientInteraction(modifierFlags: modifierFlags)
        }
    }

    @objc private func toggleGlobalHotkeys() {
        globalHotkeysEnabled.toggle()
        if globalHotkeysEnabled {
            registerHotkey()
        } else {
            HotkeyManager.shared.unregisterAll()
        }
        rebuildStatusBarMenu()
    }

    private func registerHotkey() {
        guard globalHotkeysEnabled else {
            HotkeyManager.shared.unregisterAll()
            return
        }
        // Stamp entry time at the very FIRST instruction of each callback so
        // any runloop wake-up cost before startCapture is attributed.
        let stamp: () -> Void = { [weak self] in
            let now = CFAbsoluteTimeGetCurrent()
            self?.pendingCaptureEntryTime = now
            os_log("HOTKEY CALLBACK FIRED at abs=%{public}.6f", log: timingLog, type: .info, now)
        }
        HotkeyManager.shared.registerAll(
            captureArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureScreenFromHotkey))
            },
            captureFullScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureFullScreenFromHotkey))
            },
            recordArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordAreaFromHotkey))
            },
            recordScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordFullScreenFromHotkey))
            },
            historyOverlay: { [weak self] in
                DispatchQueue.main.async { self?.showHistoryOverlay() }
            },
            captureOCR: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureOCRFromHotkey))
            },
            selectableOCRCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.selectableOCRCaptureFromHotkey))
            },
            translationWindow: { [weak self] in
                let frontmostApp = NSWorkspace.shared.frontmostApplication
                DispatchQueue.main.async {
                    self?.toggleTranslationWindowFromHotkey(frontmostApp: frontmostApp)
                }
            },
            screenTranslationCapture: { [weak self] in
                DispatchQueue.main.async { self?.beginScreenTranslationCapture() }
            },
            quickCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.quickCaptureFromHotkey))
            },
            scrollCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.scrollCaptureFromHotkey))
            },
            openFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.openImageFromClipboard() }
            },
            captureLastArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureLastAreaFromHotkey))
            },
            pinFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.pinFromClipboard() }
            },
            toggleAllPins: { [weak self] in
                DispatchQueue.main.async { self?.toggleAllPinsVisibility() }
            },
            clearHistory: { [weak self] in
                DispatchQueue.main.async { self?.clearHistorySilently() }
            },
            transparentAnnotation: { [weak self] in
                DispatchQueue.main.async { self?.startTransparentAnnotation() }
            },
            presentationDrawing: { [weak self] in
                DispatchQueue.main.async { self?.startPresentationDrawing() }
            }
        )
    }

    private func toggleTranslationWindowFromHotkey(frontmostApp: NSRunningApplication?) {
        if let controller = translationWindowController, controller.isKeyAndVisible {
            controller.closeForHotkeyToggle()
            return
        }
        showTranslationWindowFromHotkey(frontmostApp: frontmostApp)
    }

    private func showTranslationWindowFromHotkey(frontmostApp: NSRunningApplication?) {
        let permissionAction =
            SelectedTextTranslationPreference.translationWindowPermissionAction()
        settingsController?.refreshSelectedTextTranslationPermissionState()
        if permissionAction == .explainClipboardFallback {
            showSelectedTextTranslationPermissionExplanation()
        }
        let isExternalApp = frontmostApp?.bundleIdentifier != Bundle.main.bundleIdentifier
        if isExternalApp { previousApp = frontmostApp }
        let canReadSelectedText = isExternalApp && SelectedTextTranslationPreference.isEnabled
        let selectedText = (canReadSelectedText ? frontmostApp : nil).flatMap {
            SelectedTextReader.readSelectedText(fromPID: $0.processIdentifier)
        }
        let source = TranslationInputResolver.resolve(TranslationInputSources(
            selectedText: selectedText,
            clipboardText: NSPasteboard.general.string(forType: .string),
            lastSessionText: translationWindowController?.lastInput))
        let controller = translationWindowController ?? TranslationWindowController()
        translationWindowController = controller
        controller.present(sourceText: source, autoTranslate: !source.isEmpty)
    }

    private func showSelectedTextTranslationPermissionExplanation() {
        let alert = NSAlert()
        alert.messageText = L("Translate Selected Text")
        alert.informativeText = L(
            "With Accessibility permission, Pinlume can automatically read text selected in other apps. Without it, clipboard text can still be translated normally."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Continue with Clipboard"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SelectedTextReader.requestAccessibilityPermission()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func beginScreenTranslationCapture() {
        guard canStartCapture() else { pendingCaptureWorkflow.reset(); return }
        screenTranslationState.cancel()
        screenTranslationController?.close()
        screenTranslationController = nil
        pendingCaptureWorkflow.prepare(.screenTranslation)
        startCapture(fromMenu: false)
    }

    func openTranslationWindow(sourceText: String, sourceLanguage: String, targetLanguage: String) {
        let controller = translationWindowController ?? TranslationWindowController()
        translationWindowController = controller
        controller.present(sourceText: sourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private var pendingRecordMode: Bool = false
    private var pendingFullScreen: Bool = false
    private var pendingFullScreenRecord: Bool = false
    private var pendingFullScreenRecordDisplayID: CGDirectDisplayID?
    private var pendingFullScreenRecordAutoStart: Bool = false
    private var pendingOCRMode: Bool = false
    private var pendingQuickCaptureMode: Bool = false
    private var pendingScrollCaptureMode: Bool = false
    private var pendingCaptureWorkflow = PendingCaptureWorkflow()
    private var pendingCaptureTrigger: CaptureTrigger?
    private var activeCaptureWorkflow: CaptureWorkflowMode = .standard
    private var capturedWindowTitle: String?
    /// The app that was active before the overlay appeared — re-activated on dismiss.
    /// The app that was active before Pinlume showed its overlay.
    private var previousApp: NSRunningApplication?

    /// Titled Pinlume windows (editors, preferences, and OCR) that were
    /// visible when capture started. We `orderOut` them so `NSApp.activate`
    /// during capture can't drag them in front of the user's frontmost app,
    /// then `orderFront` them when the overlay dismisses. Kept in the order
    /// they appeared so restoring preserves relative z-order.
    private var stashedBackgroundWindows: [NSWindow] = []

    /// True when floating thumbnails or pin windows are visible.
    var hasVisibleFloatingPanels: Bool {
        !thumbnailControllers.isEmpty || !pinControllers.isEmpty
    }

    /// Call when a Pinlume window closes. If no titled windows remain,
    /// switches to accessory activation policy and returns focus to
    /// the previous app (or the next regular app in line).
    func returnFocusIfNeeded() {
        captureTimingTrace?.mark("returnFocusIfNeeded entered")
        let appToActivate = previousApp
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            // Don't hide the app while a recording is in progress — the HUD
            // and selection border are non-titled panels that would be killed.
            if self?.recordingLifecycle.state != .idle { return }
            let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            // Windows we hid for the screenshot count as "visible" for
            // activation-policy purposes — they're coming back as soon as
            // the previous app regains focus, so we mustn't downgrade.
            let hasStashedWindows = !(self?.stashedBackgroundWindows.isEmpty ?? true)
            guard !hasVisibleWindows else { return }
            if !hasStashedWindows {
                NSApp.setActivationPolicy(.accessory)
            }
            if let prev = appToActivate, !prev.isTerminated,
               prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.captureTimingTrace?.mark("activate previous app")
                Self.activateApp(prev)
            } else {
                // No known previous app — yield focus to whatever is frontmost.
                // Avoid NSApp.hide(nil) which can suspend the Carbon event loop
                // and break global hotkeys until the app is reactivated.
                self?.captureTimingTrace?.mark("activate fallback app")
                Self.activateApp(
                    NSWorkspace.shared.runningApplications.first {
                        $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    } ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
                )
            }
        }
    }

    /// Activate another app using the modern cooperative activation API.
    static func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Capture

    @objc private func captureScreen() {
        beginCaptureArea(fromMenu: true)
    }

    @objc private func captureScreenFromHotkey() {
        beginCaptureArea(fromMenu: false)
    }

    private func beginCaptureArea(fromMenu: Bool) {
        pendingCaptureWorkflow.reset()
        startCapture(fromMenu: fromMenu)
    }

    @objc private func selectableOCRCaptureFromHotkey() {
        beginSelectableOCRCapture(fromMenu: false)
    }

    @objc private func selectableOCRCapture() {
        beginSelectableOCRCapture(fromMenu: true)
    }

    @objc private func showTranslationWindow() {
        showTranslationWindowFromHotkey(frontmostApp: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func screenTranslationCapture() {
        beginScreenTranslationCapture()
    }

    private func beginSelectableOCRCapture(fromMenu: Bool) {
        guard canStartCapture() else {
            pendingCaptureWorkflow.reset()
            return
        }
        pendingCaptureWorkflow.prepare(.selectableOCR)
        startCapture(fromMenu: fromMenu)
    }

    @objc private func captureFullScreen() {
        beginCaptureFullScreen(fromMenu: true)
    }

    @objc private func captureFullScreenFromHotkey() {
        beginCaptureFullScreen(fromMenu: false)
    }

    private func beginCaptureFullScreen(fromMenu: Bool) {
        guard canStartCapture() else { return }
        pendingFullScreen = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func showHistoryOverlay() {
        if let existing = historyOverlayController {
            existing.dismiss()
            historyOverlayController = nil
            return
        }
        let controller = HistoryOverlayController()
        controller.onDismiss = { [weak self] in
            self?.historyOverlayController = nil
        }
        controller.show()
        historyOverlayController = controller
    }

    @objc private func captureOCR() {
        beginCaptureOCR(fromMenu: true)
    }

    @objc private func captureOCRFromHotkey() {
        beginCaptureOCR(fromMenu: false)
    }

    private func beginCaptureOCR(fromMenu: Bool) {
        guard canStartCapture() else { return }
        pendingOCRMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func quickCapture() {
        beginQuickCapture(fromMenu: true)
    }

    @objc private func quickCaptureFromHotkey() {
        beginQuickCapture(fromMenu: false)
    }

    private func beginQuickCapture(fromMenu: Bool) {
        guard canStartCapture() else { return }
        pendingQuickCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func scrollCapture() {
        beginScrollCapture(fromMenu: true)
    }

    @objc private func scrollCaptureFromHotkey() {
        beginScrollCapture(fromMenu: false)
    }

    private func beginScrollCapture(fromMenu: Bool) {
        guard canStartCapture() else { return }
        pendingScrollCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    /// Open the capture overlay with the last selection area pre-applied.
    /// If no previous selection exists, falls back to a normal capture.
    @objc private func captureLastArea() {
        beginCaptureLastArea(fromMenu: true)
    }

    @objc private func captureLastAreaFromHotkey() {
        beginCaptureLastArea(fromMenu: false)
    }

    private func beginCaptureLastArea(fromMenu: Bool) {
        guard canStartCapture() else { return }
        pendingRestoreLastArea = true
        startCapture(fromMenu: fromMenu)
    }
    private var pendingRestoreLastArea: Bool = false

    @objc private func recordArea() {
        beginRecordArea(fromMenu: true)
    }

    @objc private func recordAreaFromHotkey() {
        beginRecordArea(fromMenu: false)
    }

    private func beginRecordArea(fromMenu: Bool) {
        guard canStartCapture(.recording) else { return }
        pendingRecordMode = true
        startCapture(fromMenu: fromMenu, request: .recording)
    }

    @objc private func recordFullScreen() {
        beginRecordFullScreen(fromMenu: true)
    }

    @objc private func recordFullScreenFromHotkey() {
        beginRecordFullScreen(fromMenu: false)
    }

    private func beginRecordFullScreen(fromMenu: Bool) {
        guard canStartCapture(.recording) else { return }
        pendingFullScreenRecord = true
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        pendingFullScreenRecordDisplayID = FullScreenRecordingTarget.displayID(
            isMenuInvocation: fromMenu,
            mainDisplayID: Self.displayID(for: NSScreen.main),
            pointerDisplayID: Self.displayID(for: pointerScreen)
        )
        if UserDefaults.standard.integer(forKey: "captureDelaySeconds") > 0 {
            pendingFullScreenRecordAutoStart = true
        }
        startCapture(fromMenu: fromMenu, request: .recording)
    }

    @objc private func setDelaySeconds(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "captureDelaySeconds")
        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
    }

    private func startCapture(
        fromMenu: Bool = false,
        request: CaptureStartRequest = .screenshot
    ) {
        let effectiveTrigger = pendingCaptureTrigger ?? (fromMenu ? .menu : .hotkey)
        pendingCaptureTrigger = nil
        guard canStartCapture(request) else {
            os_log(
                "CAPTURE_DIAGNOSTIC_REJECTED trigger=%{public}@ request=%{public}@ isCapturing=%{public}d isRecording=%{public}d",
                log: timingLog,
                type: .info,
                effectiveTrigger.rawValue,
                request == .recording ? "recording" : "screenshot",
                isCapturing,
                recordingLifecycle.state != .idle
            )
            pendingCaptureWorkflow.reset()
            return
        }
        cancelIdleUIWarmup()
        let requestedWorkflow = pendingCaptureWorkflow.consume()
        let trace = makeCaptureTimingTrace()
        captureTimingTrace = trace
        trace?.mark("startCapture entered fromMenu=\(fromMenu)")
        isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID
        os_log(
            "CAPTURE_DIAGNOSTIC trigger=%{public}@ request=%{public}@ session=%{public}llu",
            log: timingLog,
            type: .info,
            effectiveTrigger.rawValue,
            request == .recording ? "recording" : "screenshot",
            sessionID
        )
        trace?.mark("capture session created id=\(sessionID)")
        previousApp = NSWorkspace.shared.frontmostApplication
        trace?.mark("frontmost application captured")
        capturedWindowTitle = nil
        let focusedWindowPID = previousApp?.processIdentifier
        resolveFocusedWindowTitleAsync(for: focusedWindowPID, sessionID: sessionID)

        // Clean up stale overlays without consuming previousApp — we just set it.
        measureCaptureTiming("dismiss stale overlays") {
            dismissOverlays(refocusPreviousApp: false)
        }
        activeCaptureWorkflow = requestedWorkflow
        isCapturing = true

        // Hide non-overlay titled windows so they don't end up in the screenshot.
        // Restored in dismissOverlays once capture is over.
        measureCaptureTiming("stash background windows") {
            stashBackgroundWindows()
        }

        // Hide floating thumbnails so they don't appear in the captured image.
        measureCaptureTiming("hide thumbnails before capture") {
            for tc in thumbnailControllers { tc.hideWindow() }
        }

        let delay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        trace?.mark("capture delay read delay=\(delay)")

        if delay > 0 {
            captureTimingTrace?.mark("showPreCaptureCountdown requested")
            showPreCaptureCountdown(seconds: delay)
            return
        }

        performCapture(fromMenu: fromMenu)
    }

    private func canStartCapture(_ request: CaptureStartRequest = .screenshot) -> Bool {
        CaptureStartGate.canBeginCapture(
            isCapturing: isCapturing,
            isRecording: recordingLifecycle.state != .idle,
            request: request
        )
    }

    private func showPreCaptureCountdown(seconds: Int) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Listen for Escape to cancel countdown — use both local and global monitors
        // Local catches keys when Pinlume is active; global catches when another app has focus
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelPreCaptureCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.performCapture(fromMenu: false)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func removeDelayEscMonitors() {
        if let m = delayEscMonitor { NSEvent.removeMonitor(m); delayEscMonitor = nil }
    }

    private func cancelPreCaptureCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        removeDelayEscMonitors()
        isCapturing = false
        pendingRecordMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false
        pendingFullScreenRecordDisplayID = nil
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingRestoreLastArea = false
        pendingCaptureWorkflow.reset()
        activeCaptureWorkflow = .standard
    }

    private func performCapture(fromMenu: Bool) {
        captureTimingTrace?.mark("performCapture entered fromMenu=\(fromMenu)")
        let screens = measureCaptureTiming("NSScreen.screens") {
            NSScreen.screens
        }
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = screens.first { $0.frame.contains(mouseLocation) }
        setPreCaptureSelectionCursor(screen: mouseScreen)

        // Kick off the screenshot capture on a background queue. Window
        // creation runs on main concurrently — both costs are paid in parallel.
        // CGWindowListCreateImage is used because it preserves transient UI
        // (menu extras, app menus, Raycast-style panels) that disappears once
        // anything steals focus. Overlay windows haven't been ordered-front yet
        // so they won't appear in the capture.
        let captureContext = measureCaptureTiming("makeImmediateCaptureContext") {
            ScreenCaptureManager.makeImmediateCaptureContext()
        }
        let trace = captureTimingTrace
        let sessionID = captureSessionID
        let recordingCaptureChromeWindowNumbers = self.recordingCaptureChromeWindowNumbers
        let appKitReferenceTopY = screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? screens.first?.frame.maxY
            ?? 0
        trace?.mark("window snap snapshot begin")
        let windowSnapSnapshotTask = Task.detached(priority: .userInitiated) {
            FrozenWindowSnapSnapshot.capture(appKitReferenceTopY: appKitReferenceTopY)
        }

        // Pull (don't construct) overlay controllers from the persistent pool.
        // Each controller's NSPanel was created and warmed at launch / pool
        // rebuild, so WindowServer's per-window cache is already hot.
        var controllers: [OverlayWindowController] = []
        for screen in screens {
            let controller = measureCaptureTiming("acquire pooled overlay") {
                pooledController(for: screen)
            }
            controller.overlayDelegate = self
            if let trace = captureTimingTrace {
                controller.timingMark = { label in trace.mark(label) }
            }
            controller.capturedWindowTitle = capturedWindowTitle
            controller.setCaptureWorkflowMode(activeCaptureWorkflow)
            if pendingRecordMode { controller.setAutoRecordMode() }
            if pendingOCRMode { controller.setAutoOCRMode() }
            if pendingQuickCaptureMode { controller.setAutoQuickSaveMode() }
            if pendingScrollCaptureMode { controller.setAutoScrollCaptureMode() }
            controllers.append(controller)
        }
        overlayControllers.append(contentsOf: controllers)
        applyWindowSnapSnapshotWhenReady(
            windowSnapSnapshotTask,
            controllers: controllers,
            sessionID: sessionID,
            trace: trace)

        pendingRecordMode = false
        let didApplyFullScreenRecord = pendingFullScreenRecord
        let didApplyFullScreenRecordDisplayID = pendingFullScreenRecordDisplayID
        let didApplyFullScreenRecordAutoStart = pendingFullScreenRecordAutoStart
        let didApplyFullScreen = pendingFullScreen
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false
        pendingFullScreenRecordDisplayID = nil

        // Run the screenshot capture now and dispatch back to main when done.
        // Window creation above already ran in parallel with the prep that the
        // background work still has to do.
        //
        // Prefer SCScreenshotManager: it honors the "Capture mouse cursor"
        // toggle even for the enlarged shake-to-find / accessibility cursor,
        // which CGWindowListCreateImage cannot exclude (the cursor is a
        // WindowServer layer, not a window). On macOS 26+, use the rect-based
        // screenshot API to avoid SCShareableContent enumeration in the hot
        // path. Older SCK fallback still fetches fresh shareable content so
        // transient UI (menus, Spotlight) is preserved. If SCK fails or can't
        // cover every display, fall back to the synchronous CGWindowListCreateImage
        // path (which manually composites the cursor from the prebuilt context).
        Task { [weak self] in
            trace?.mark("background screenshot begin")
            var captures: [ScreenCapture]? = nil
            if #available(macOS 14.0, *) {
                captures = await ScreenCaptureManager.captureAllScreensImmediatelySCK(
                    excludingWindowNumbers: recordingCaptureChromeWindowNumbers,
                    timing: { label in trace?.mark(label) })
            }
            let finalCaptures = captures ?? ScreenCaptureManager.captureAllScreensImmediately(
                context: captureContext,
                timing: { label in trace?.mark(label) })
            trace?.mark("background screenshot end count=\(finalCaptures.count)")
            await MainActor.run {
                guard let self = self, self.isCapturing,
                      self.captureSessionID == sessionID else { return }
                self.installAndShowOverlays(
                    captures: finalCaptures,
                    controllers: controllers,
                    mouseScreen: mouseScreen,
                    applyFullScreen: didApplyFullScreen,
                    applyFullScreenRecord: didApplyFullScreenRecord,
                    fullScreenRecordDisplayID: didApplyFullScreenRecordDisplayID,
                    autoStartRecord: didApplyFullScreenRecordAutoStart)
            }
        }
    }

    private func setPreCaptureSelectionCursor(screen: NSScreen?) {
        guard screen != nil else { return }
        NSCursor.crosshair.set()
    }

    /// Window enumeration is independent from screen pixels. It may finish
    /// before or after the overlay becomes interactive, but must never delay
    /// the first mouseDown. A late snapshot re-runs the initial snap query.
    private func applyWindowSnapSnapshotWhenReady(
        _ task: Task<FrozenWindowSnapSnapshot, Never>,
        controllers: [OverlayWindowController],
        sessionID: UInt,
        trace: CaptureTimingTrace?
    ) {
        Task { [weak self] in
            let snapshot = await task.value
            trace?.mark("window snap snapshot end candidates=\(snapshot.count)")
            guard let self,
                  self.isCapturing,
                  self.captureSessionID == sessionID
            else { return }
            for controller in controllers {
                controller.setWindowSnapSnapshot(snapshot)
            }
        }
    }

    /// Install screenshots into the pre-built overlay controllers and order
    /// them front. This is the single moment the overlay becomes visible.
    private func installAndShowOverlays(
        captures: [ScreenCapture],
        controllers: [OverlayWindowController],
        mouseScreen: NSScreen?,
        applyFullScreen: Bool,
        applyFullScreenRecord: Bool,
        fullScreenRecordDisplayID: CGDirectDisplayID?,
        autoStartRecord: Bool
    ) {
        if captures.isEmpty {
            captureTimingTrace?.mark("no captures returned — bailing out")
            pendingRestoreLastArea = false
            dismissOverlays(refocusPreviousApp: true)
            showOnboarding()
            return
        }

        // Screen pixels are captured before this point. Activate only now so
        // the non-activating overlay becomes the real cursor owner under a
        // stationary pointer; `returnFocusIfNeeded()` restores previousApp on
        // dismissal.
        activateCaptureOverlayApp()

        let capturesByScreen = Dictionary(uniqueKeysWithValues: captures.map { ($0.screen, $0.image) })

        for controller in controllers {
            if let image = capturesByScreen[controller.screen] {
                measureCaptureTiming("set screenshot") {
                    controller.setScreenshot(image)
                }
            }
            measureCaptureTiming("show overlay") {
                controller.showOverlay(makeKey: false)
            }
            let isMouseScreen = (controller.screen == mouseScreen)
                || (mouseScreen == nil && controller.screen == NSScreen.main)
            let isFullScreenRecordTarget = applyFullScreenRecord && (
                Self.displayID(for: controller.screen) == fullScreenRecordDisplayID
                || (fullScreenRecordDisplayID == nil && isMouseScreen)
            )
            if (applyFullScreen && isMouseScreen) || isFullScreenRecordTarget {
                measureCaptureTiming("apply full screen selection") {
                    controller.applyFullScreenSelection()
                }
            }
            if isFullScreenRecordTarget {
                controller.enterRecordingMode()
                if autoStartRecord {
                    controller.autoStartRecording()
                }
            }
        }

        refreshOverlayCursorAfterOrdering(
            controllers,
            mouseScreen: mouseScreen,
            sessionID: captureSessionID)

        captureTimingTrace?.mark("overlays installed and shown — INTERACTIVE")
        // Beacon: schedule periodic main-runloop marks so we can see if the
        // runloop is alive between INTERACTIVE and the first user event.
        // Fires every 50ms for 3 seconds, then auto-cancels.
        if let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "INTERACTIVE-checkpoint")
            os_log("=== TRACE @ INTERACTIVE ===\n%{public}@", log: timingLog, type: .info, report)
            startRunloopBeacon()
        }
        applyPendingRestoredSelectionIfNeeded()
    }

    private func refreshOverlayCursorAfterOrdering(
        _ controllers: [OverlayWindowController],
        mouseScreen: NSScreen?,
        sessionID: UInt
    ) {
        let pointerLocation = NSEvent.mouseLocation
        let pointerController = controllers.first {
            $0.screen.frame.contains(pointerLocation)
        } ?? controllers.first { $0.screen == mouseScreen }
        guard let pointerController else { return }
        pointerController.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCapturing,
                  self.captureSessionID == sessionID
            else { return }
            pointerController.refreshCursorAtPointerIfInside()
        }
    }

    private func activateCaptureOverlayApp() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private var runloopBeaconTimer: Timer?
    private func startRunloopBeacon() {
        stopRunloopBeacon()
        var ticks = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            ticks += 1
            self?.captureTimingTrace?.mark("BEACON tick=\(ticks)")
            if ticks >= 60 {  // 3 seconds
                t.invalidate()
                self?.runloopBeaconTimer = nil
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        runloopBeaconTimer = timer
    }
    private func stopRunloopBeacon() {
        runloopBeaconTimer?.invalidate()
        runloopBeaconTimer = nil
    }

    private func applyPendingRestoredSelectionIfNeeded() {
        guard pendingRestoreLastArea else { return }
        pendingRestoreLastArea = false
        restoreLastSelection(controllers: overlayControllers)
    }

    /// Apply the stored last selection rect to the matching overlay controller.
    private func restoreLastSelection(controllers: [OverlayWindowController]) {
        guard let rectStr = UserDefaults.standard.string(forKey: "lastSelectionRect"),
              let screenStr = UserDefaults.standard.string(forKey: "lastSelectionScreenFrame") else { return }
        let savedRect = NSRectFromString(rectStr)
        let savedScreenFrame = NSRectFromString(screenStr)
        guard savedRect.width > 1, savedRect.height > 1 else { return }
        for controller in controllers where controller.screen.frame == savedScreenFrame {
            controller.applySelection(savedRect)
            controller.showOverlay()
            break
        }
    }

    /// Returns the title of the frontmost window via CGWindowList (requires Screen Recording permission).
    nonisolated private static func focusedWindowTitle(forPID pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    private func resolveFocusedWindowTitleAsync(for pid: pid_t?, sessionID: UInt) {
        guard let pid = pid else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let title = Self.focusedWindowTitle(forPID: pid)
            DispatchQueue.main.async {
                guard let self = self, self.isCapturing, self.captureSessionID == sessionID else { return }
                self.capturedWindowTitle = title
                for controller in self.overlayControllers {
                    controller.capturedWindowTitle = title
                }
            }
        }
    }


    @objc private func handleShowAndOpenPrefs() {
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        openSettings()
    }

    @objc private func spaceDidChange() {
        guard !overlayControllers.isEmpty else { return }
        dismissOverlays()
    }

    private func dismissOverlays(refocusPreviousApp: Bool = true, invalidateScreenTranslation: Bool = true) {
        #if !OFFLINE
        invalidateUploadOverlaySession()
        #endif
        if invalidateScreenTranslation { screenTranslationState.cancel() }
        captureTimingTrace?.mark("dismissOverlays entered refocus=\(refocusPreviousApp)")
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        captureTimingTrace?.mark("overlay controllers dismissed")
        isCapturing = false
        scheduleIdleUIWarmup()
        pendingCaptureWorkflow.reset()
        activeCaptureWorkflow = .standard
        // Restore hidden thumbnails
        measureCaptureTiming("restore thumbnails") {
            for tc in thumbnailControllers { tc.showWindow() }
        }
        if refocusPreviousApp {
            // Restore AFTER another app takes focus so the stashed windows
            // come back behind it instead of on top. See
            // `scheduleBackgroundWindowRestore` for the timing logic.
            captureTimingTrace?.mark("schedule focus restore")
            scheduleBackgroundWindowRestore()
            returnFocusIfNeeded()
        } else {
            // No focus switch coming — just bring them back immediately.
            captureTimingTrace?.mark("restore background windows immediately")
            restoreBackgroundWindowsNow()
        }
        captureTimingTrace?.mark("dismissOverlays completed")
        if refocusPreviousApp, let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "OVERLAY DISMISSED")
            os_log("=== FINAL TRACE ===\n%{public}@", log: timingLog, type: .info, report)
            DiagnosticLogStore.append(report)
            captureTimingTrace = nil
        }
    }


    /// Hide non-overlay titled Pinlume windows so they can't be dragged in
    /// front of the user's frontmost app when the overlay activates.
    ///
    /// We only stash when another app was frontmost — that means the user is
    /// trying to screenshot something *other than* Pinlume, and any Pinlume
    /// windows still on screen are unintended background clutter. When
    /// Pinlume itself is frontmost the user presumably wants to capture one
    /// of its own windows, so we leave everything alone.
    private func stashBackgroundWindows() {
        stashedBackgroundWindows.removeAll()
        let ourBundleID = Bundle.main.bundleIdentifier
        let pinlumeWasFrontmost = previousApp?.bundleIdentifier == ourBundleID
        guard !pinlumeWasFrontmost else { return }
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            stashedBackgroundWindows.append(window)
            window.orderOut(nil)
        }
    }

    /// Wait until another app becomes frontmost, then restore the stashed
    /// windows. If we restore before the user's previous app regains focus,
    /// the windows come back on top and clobber whatever was frontmost.
    ///
    /// Uses NSWorkspace's activation notification as the trigger, with a
    /// short timer fallback in case activation never completes (e.g. the
    /// previous app terminated during capture).
    private func scheduleBackgroundWindowRestore() {
        guard !stashedBackgroundWindows.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        token = ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                if let token = token { ws.removeObserver(token) }
                self.restoreBackgroundWindowsNow()
            }
        }
        // Fallback — if no other app ever activates in the next 1s just
        // restore anyway. Otherwise the windows would stay invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if !self.stashedBackgroundWindows.isEmpty {
                if let token = token { ws.removeObserver(token) }
                self.restoreBackgroundWindowsNow()
            }
        }
    }

    /// Reverse of `stashBackgroundWindows`. Uses `orderBack` instead of
    /// `orderFront` so the restored windows land behind every other
    /// app's windows rather than on top of them. (`orderFront` still
    /// raises windows in the global z-stack even when the owning app
    /// isn't frontmost, which is what was causing the editor to pop
    /// visible right after a screenshot.)
    private func restoreBackgroundWindowsNow() {
        for window in stashedBackgroundWindows {
            window.orderBack(nil)
        }
        stashedBackgroundWindows.removeAll()
    }

    private func finishCaptureTimingReport(_ finalLabel: String) -> String? {
        #if DEBUG
        guard let trace = captureTimingTrace else { return nil }
        let report = trace.report(finalLabel: finalLabel)
        captureTimingTrace = nil
        return report
        #else
        captureTimingTrace = nil
        return nil
        #endif
    }

    private func showCaptureTimingDialog(_ report: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Capture Timing"
        alert.informativeText = "Timing for the last screenshot capture."
        alert.addButton(withTitle: "OK")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = report
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.runModal()
    }

    func showFloatingThumbnail(
        image: NSImage,
        annotationData: CaptureAnnotationData? = nil,
        historyEntryID: String? = nil,
        preferredScreen: NSScreen? = nil
    ) {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        if !stacking {
            // Replace mode: dismiss all existing thumbnails
            thumbnailControllers.forEach { $0.dismiss() }
            thumbnailControllers.removeAll()
        }

        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let corner = thumbnailCorner()
        let thumbSize = FloatingThumbnailController.currentThumbnailSize()
        let xOrigin = thumbnailX(for: thumbSize.width, in: screenFrame, corner: corner, padding: padding)

        // Compute Y: bottom corners stack upward, top corners stack downward.
        var yOrigin = corner.isTop ? screenFrame.maxY - thumbSize.height - padding : screenFrame.minY + padding
        if let topController = thumbnailControllers.last {
            let topFrame = topController.windowFrame
            yOrigin = corner.isTop ? topFrame.minY - thumbSize.height - gap : topFrame.maxY + gap
        }

        let controller = FloatingThumbnailController(image: image)
        controller.historyEntryID = historyEntryID
        controller.annotationData = annotationData
        controller.onDismiss = { [weak self] in
            self?.thumbnailControllers.removeAll { $0 === controller }
            self?.reflowThumbnails()
        }
        controller.onCopy = { [weak controller] in
            guard let image = controller?.image else { return }
            ImageEncoder.copyToClipboard(image)
        }
        controller.onSave = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImage(image)
        }
        controller.onSaveAs = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImageAs(image)
        }
        controller.onPin = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            let image = controller.image
            let data = controller.annotationData
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: data?.rawImage,
                annotations: data?.annotations,
                editState: data?.editState
            )
            self.showPin(image: image)
        }
        #if !OFFLINE
        controller.onUpload = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            let image = controller.image
            let data = controller.annotationData
            _ = self.showUploadProgress(
                image: image,
                onAccepted: {
                    ScreenshotHistory.shared.add(
                        image: image,
                        rawImage: data?.rawImage,
                        annotations: data?.annotations,
                        editState: data?.editState
                    )
                }
            )
        }
        #endif
        controller.onTransform = { transformed in
            if let id = historyEntryID {
                ScreenshotHistory.shared.updateEntry(id: id, compositedImage: transformed, rawImage: nil, annotations: nil)
            }
        }
        controller.onOCR = { [weak self, weak controller] in
            guard let image = controller?.image else { return }
            self?.runOCR(on: image)
        }
        controller.onDelete = {
            if let id = historyEntryID {
                ScreenshotHistory.shared.removeEntry(id: id)
            }
        }
        controller.onCloseAll = { [weak self] in
            guard let self = self else { return }
            let all = self.thumbnailControllers
            self.thumbnailControllers.removeAll()
            for c in all { c.dismiss() }
        }
        controller.onSaveAll = { [weak self] in
            self?.saveAllThumbnailsToFolder()
        }
        thumbnailControllers.append(controller)
        controller.show(at: NSPoint(x: xOrigin, y: yOrigin), corner: corner, on: screen)
    }

    private func saveAllThumbnailsToFolder() {
        let images = thumbnailControllers.map { $0.image }
        guard !images.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder to save \(images.count) screenshot\(images.count == 1 ? "" : "s")"
        panel.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            panel.begin { [weak self] response in
                guard response == .OK, let dirURL = panel.url else { return }
                let rawTemplate = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
                // Ensure batch writes don't collide when the template lacks {index}.
                let template = rawTemplate.contains("{index}") ? rawTemplate : "\(rawTemplate)-{index}"
                let batchDate = Date()

                DispatchQueue.global(qos: .userInitiated).async {
                    var outputs: [(filename: String, data: Data)] = []
                    var outputError: Error?
                    for (i, image) in images.enumerated() {
                        guard let data = ImageEncoder.encode(image) else {
                            outputError = CocoaError(.fileWriteInapplicableStringEncoding)
                            break
                        }
                        let base = FilenameFormatter.format(template: template, index: i + 1, date: batchDate)
                        let filename = "\(base).\(ImageEncoder.fileExtension)"
                        outputs.append((filename: filename, data: data))
                    }
                    if outputError == nil {
                        do {
                            _ = try TransactionalOutput.writeBatch(outputs, to: dirURL)
                        } catch {
                            outputError = error
                        }
                    }
                    DispatchQueue.main.async {
                        if let outputError {
                            self?.showOutputSaveFailure(outputError)
                            return
                        }
                        self?.playCopySound()
                        let all = self?.thumbnailControllers ?? []
                        self?.thumbnailControllers.removeAll()
                        for c in all { c.dismiss() }
                    }
                }
            }
        }
    }

    private func showOutputSaveFailure(_ error: Error) {
        let underlying = (error as? TransactionalOutput.Failure)?.underlyingError ?? error
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Save failed")
        alert.informativeText = underlying.localizedDescription
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    private func reflowThumbnails() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let frame = screen.visibleFrame
        let corner = thumbnailCorner()
        var y = corner.isTop ? frame.maxY - padding : frame.minY + padding
        for c in thumbnailControllers {
            let size = c.windowFrame.size
            let x = thumbnailX(for: size.width, in: frame, corner: corner, padding: padding)
            let yOrigin: CGFloat
            if corner.isTop {
                y -= size.height
                yOrigin = y
                y -= gap
            } else {
                yOrigin = y
                y += size.height + gap
            }
            c.moveTo(origin: NSPoint(x: x, y: yOrigin))
        }
    }

    private func thumbnailCorner() -> FloatingThumbnailCorner {
        let rawValue = UserDefaults.standard.string(forKey: "thumbnailCorner") ?? FloatingThumbnailCorner.bottomRight.rawValue
        return FloatingThumbnailCorner(rawValue: rawValue) ?? .bottomRight
    }

    private func thumbnailX(
        for width: CGFloat,
        in frame: NSRect,
        corner: FloatingThumbnailCorner,
        padding: CGFloat
    ) -> CGFloat {
        corner.isLeft ? frame.minX + padding : frame.maxX - width - padding
    }

    /// Update a floating thumbnail's image if it matches the given history entry.
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData? = nil) {
        for tc in thumbnailControllers where tc.historyEntryID == entryID {
            tc.updateImage(image, annotationData: annotationData)
        }
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        Self.captureSound?.stop()
        Self.captureSound?.play()
    }

    private func showClipboardToast(_ message: String) {
        uploadToastController?.dismiss()
        let toast = UploadToastController()
        uploadToastController = toast
        toast.onDismiss = { [weak self] in
            self?.uploadToastController = nil
        }
        toast.showMessage(status: message, symbolName: "doc.on.clipboard")
    }

    private func showOverlayStyleClipboardMessage(_ message: String) {
        uploadToastController?.dismiss()
        let toast = UploadToastController()
        uploadToastController = toast
        toast.onDismiss = { [weak self] in
            self?.uploadToastController = nil
        }
        toast.showOverlayStyleMessage(status: message)
    }

    func runOCR(on image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                    let shouldCopy = ocrAction == 0 || ocrAction == 2
                    let shouldShowWindow = ocrAction == 0 || ocrAction == 1

                    if shouldCopy && !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }

                    if shouldShowWindow {
                        self.ocrController?.close()
                        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                        ocr.onClose = { [weak self, weak ocr] in
                            if self?.ocrController === ocr { self?.ocrController = nil }
                        }
                        self.ocrController = ocr
                        ocr.show()
                    }
                }
            }
        }
    }

    private func saveThumbnailImage(_ image: NSImage) {
        ImageSaveService.save(image, panelLevel: .floating, activateApp: true) { [weak self] success in
            if success {
                self?.playCopySound()
            }
        }
    }

    private func saveThumbnailImageAs(_ image: NSImage) {
        ImageSaveService.showSavePanel(for: image, panelLevel: .floating, activateApp: true) { [weak self] success in
            if success {
                self?.playCopySound()
            }
        }
    }

    private func saveImageToConfiguredFolder(_ image: NSImage) {
        ImageSaveService.saveToConfiguredFolder(image, panelLevel: .floating, activateApp: true)
    }

    #if !OFFLINE
    // MARK: - Upload

    @discardableResult
    func uploadImage(
        _ image: NSImage,
        presentingWindow: NSWindow? = nil,
        onAccepted: (() -> Void)? = nil
    ) -> Bool {
        showUploadProgress(
            image: image,
            presentingWindow: presentingWindow,
            onAccepted: onAccepted
        )
    }
    #endif

    @objc private func pinFromHistory(_ notification: Notification) {
        guard let image = notification.object as? NSImage else { return }
        showPin(image: image)
    }

    func showPin(image: NSImage, initialFrame: NSRect? = nil) {
        allPinsHidden = false
        let pin = PinWindowController(image: image, initialFrame: initialFrame)
        pin.delegate = self
        pin.show()
        pinControllers.forEach { $0.setSelected(false) }
        pin.setSelected(true)
        pinControllers.append(pin)
    }

    /// The public entry point is wired to menu and global shortcuts in P3.4.
    /// Keeping it independent from `startCapture` guarantees this feature never
    /// obtains a screen image or changes ordinary capture state.
    func startTransparentAnnotation() {
        if let transparentAnnotationSession {
            transparentAnnotationSession.focus()
            return
        }
        prepareTransparentSessionFocus()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let session = TransparentAnnotationSessionController(screen: screen, mode: .annotation)
        session.onCancel = { [weak self] in
            self?.transparentAnnotationSession = nil
            self?.restoreFocusAfterTransparentSessionCancellation()
        }
        session.onComplete = { [weak self] in
            self?.transparentAnnotationSession = nil
            self?.restoreFocusAfterTransparentSessionCancellation()
        }
        session.onFinish = { [weak self] result in
            guard let self else { return }
            self.transparentAnnotationSession = nil
            let appToRefocus = self.previousApp
            self.previousApp = nil
            let pin = TransparentAnnotationPinController(payload: result)
            pin.onClose = { [weak self, weak pin] in
                guard let pin else { return }
                self?.transparentAnnotationPins.removeAll { $0 === pin }
            }
            pin.show()
            self.transparentAnnotationPins.append(pin)
            if let appToRefocus, !appToRefocus.isTerminated,
               appToRefocus.bundleIdentifier != Bundle.main.bundleIdentifier {
                appToRefocus.activate(options: .activateIgnoringOtherApps)
            }
        }
        transparentAnnotationSession = session
        session.show()
    }

    @objc private func startTransparentAnnotationFromMenu() {
        startTransparentAnnotation()
    }

    private func startPresentationDrawing() {
        if let presentationDrawingSession {
            presentationDrawingSession.focus()
            return
        }
        prepareTransparentSessionFocus()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let session = TransparentAnnotationSessionController(screen: screen, mode: .presentation)
        session.onCancel = { [weak self] in
            self?.presentationDrawingSession = nil
            self?.restoreFocusAfterTransparentSessionCancellation()
        }
        presentationDrawingSession = session
        session.show()
    }

    @objc private func startPresentationDrawingFromMenu() {
        startPresentationDrawing()
    }

    private func restoreFocusAfterTransparentSessionCancellation() {
        scheduleBackgroundWindowRestore()
        returnFocusIfNeeded()
    }

    /// Transparent sessions need the same active AppKit input owner as the
    /// ordinary capture overlay, but do not start a capture or dismiss it.
    private func prepareTransparentSessionFocus() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if frontmostApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmostApp
            stashBackgroundWindows()
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func restorePersistedPins() {
        let session = PinPersistenceStore.open()
        pinPersistenceSession = session
        let records = session.records
        guard !records.isEmpty else { return }
        allPinsHidden = false
        for record in records {
            guard let imagePNG = record.imagePNG,
                  let image = NSImage(data: imagePNG) else { continue }
            let frame = record.visualFrame.nsRect
            guard frame.width > 1, frame.height > 1 else { continue }
            let normalFrame = record.normalVisualFrame?.nsRect
            let initialFrame = (record.isCompact ?? false) ? normalFrame : (normalFrame ?? frame)
            let translationSession: ScreenTranslationSession? = record.translationState.flatMap { state in
                guard let originalData = state.originalImagePNG,
                      let translatedData = state.translatedImagePNG,
                      let storedOriginalImage = NSImage(data: originalData),
                      let storedTranslatedImage = NSImage(data: translatedData)
                else { return nil }
                // The ordinary pin image is the flattened current view (including
                // persisted annotations). Reuse it for the current translation
                // mode so switching away and back does not discard that visual.
                let originalImage = state.displayMode == .original ? image : storedOriginalImage
                let translatedImage = state.displayMode == .translated ? image : storedTranslatedImage
                return ScreenTranslationSession(
                    originalImage: originalImage, translatedImage: translatedImage,
                    translatedBlocks: state.translatedBlocks,
                    sourceLanguage: state.sourceLanguage, targetLanguage: state.targetLanguage,
                    globalFrame: initialFrame ?? frame,
                    originalBlocks: state.originalBlocks,
                    translatedSelectionBlocks: state.translatedSelectionBlocks,
                    displayMode: state.displayMode)
            }
            let pin = PinWindowController(
                image: image, initialFrame: initialFrame, textContent: record.textContent,
                translationSession: translationSession)
            pin.delegate = self
            pin.applyPersistedState(
                shadowHidden: record.shadowHidden,
                opacity: record.opacity,
                normalVisualFrame: normalFrame,
                compactCenter: record.compactCenter?.nsPoint,
                compactActualCenter: record.compactActualCenter?.nsPoint,
                isCompact: record.isCompact ?? false,
                persistedVisualFrame: frame
            )
            if record.pinKind == .ocr {
                pin.restoreDedicatedOCRIdentity(blocks: record.ocrBlocks)
            }
            pin.show(passively: true)
            pin.setSelected(false)
            pinControllers.append(pin)
        }
        rebuildStatusBarMenu()
    }

    private func savePersistedPins() {
        let records = pinControllers.map { $0.persistenceRecord() }
        guard records.allSatisfy({ $0 != nil }) else { return }
        _ = pinPersistenceSession?.save(records.compactMap { $0 })
    }

    #if !OFFLINE
    private func invalidateUploadOverlaySession() {
        uploadOverlaySession.invalidate()
        uploadOverlaySource = nil
    }

    private func beginUploadOverlaySession(
        _ sourceOverlay: OverlayWindowController
    ) -> UploadOverlaySession.Token? {
        guard overlayControllers.contains(where: { $0 === sourceOverlay }) else { return nil }
        invalidateUploadOverlaySession()
        let sessionToken = uploadOverlaySession.begin()
        uploadOverlaySource = sourceOverlay
        return sessionToken
    }

    private func acceptUploadSession(_ sessionToken: UploadOverlaySession.Token) -> Bool {
        guard uploadOverlaySession.accept(sessionToken) else { return false }
        for overlay in overlayControllers {
            overlay.suspendForModalSave()
        }
        return true
    }

    private func completeUploadSuccess(_ sessionToken: UploadOverlaySession.Token) -> Bool {
        guard uploadOverlaySession.completeSuccess(sessionToken),
              let sourceOverlay = uploadOverlaySource,
              overlayControllers.contains(where: { $0 === sourceOverlay })
        else { return false }
        uploadOverlaySource = nil
        return true
    }

    private func prepareUploadFailure(
        _ sessionToken: UploadOverlaySession.Token,
        message: String
    ) -> Bool {
        guard uploadOverlaySession.prepareFailure(sessionToken),
              let sourceOverlay = uploadOverlaySource,
              overlayControllers.contains(where: { $0 === sourceOverlay })
        else { return false }
        sourceOverlay.showUploadError(String(format: L("Upload failed: %@"), message))
        for overlay in overlayControllers {
            overlay.restoreAfterModalSave()
        }
        guard uploadOverlaySession.restoreAfterFailure(sessionToken) else { return false }
        uploadOverlaySource = nil
        return true
    }

    private func cancelUploadOverlaySession(_ sessionToken: UploadOverlaySession.Token) -> Bool {
        guard uploadOverlaySession.cancel(sessionToken),
              let sourceOverlay = uploadOverlaySource,
              overlayControllers.contains(where: { $0 === sourceOverlay })
        else { return false }
        for overlay in overlayControllers {
            overlay.restoreAfterModalSave()
        }
        uploadOverlaySource = nil
        return true
    }

    private func showUploadProgress(
        image: NSImage,
        sourceOverlay: OverlayWindowController? = nil,
        presentingWindow: NSWindow? = nil,
        onAccepted: (() -> Void)? = nil,
        onSuccess: ((UploadGateway.Result) -> Void)? = nil
    ) -> Bool {
        let providerAtStart = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        var toast: UploadToastController?
        func makeToast() -> UploadToastController {
            if let toast { return toast }
            uploadToastController?.dismiss()
            let newToast = UploadToastController()
            uploadToastController = newToast
            newToast.onDismiss = { [weak self] in self?.uploadToastController = nil }
            toast = newToast
            return newToast
        }

        let sessionToken = sourceOverlay.flatMap(beginUploadOverlaySession)
        let accepted = UploadGateway.shared.upload(
            .image(image),
            presentingWindow: presentingWindow ?? sourceOverlay?.presentationWindow,
            onAccepted: onAccepted,
            onCancelled: {
                if let sessionToken { _ = self.cancelUploadOverlaySession(sessionToken) }
            },
            onStart: {
                guard sessionToken.map({ self.acceptUploadSession($0) }) ?? true else { return }
                makeToast().show(status: "Uploading...")
            },
            onProgress: { makeToast().updateProgress($0) }
        ) { [weak self] result in
            guard let self else { return }
            let toast = makeToast()
            switch result {
            case .success(let result):
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result.link, forType: .string)
                UploadHistoryStore.shared.append(
                    provider: providerAtStart,
                    link: result.link,
                    deleteURL: result.deleteURL
                )
                if let sessionToken, self.completeUploadSuccess(sessionToken) {
                    onSuccess?(result)
                    self.dismissOverlays(refocusPreviousApp: false)
                } else if sourceOverlay == nil {
                    onSuccess?(result)
                }
                toast.showSuccess(link: result.link, deleteURL: result.deleteURL)
            case .failure(let error):
                if let sessionToken,
                   self.prepareUploadFailure(sessionToken, message: error.localizedDescription) {
                    toast.dismiss()
                } else {
                    toast.showError(message: error.localizedDescription)
                }
            }
        }
        return accepted
    }
    #endif

    // MARK: - Open Image

    @objc private func openImageFromMenu() {
        openImageWithPanel()
    }

    @objc private func openImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = L("No Image on Clipboard")
            alert.informativeText = L("Copy an image to the clipboard first, then try again.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        showPin(image: image)
    }

    @objc private func pinFromClipboard() {
        let selectedOverlay = overlayControllers.first(where: {
            $0.selectionRect.width > 0 && $0.selectionRect.height > 0
        })
        switch GlobalPinShortcutRouting.route(
            hasTransparentAnnotationSession: transparentAnnotationSession != nil,
            hasOrdinarySelection: selectedOverlay != nil,
            workflowAllowsOrdinaryPin: activeCaptureWorkflow.allowsGlobalPinShortcut
        ) {
        case .transparentAnnotation:
            transparentAnnotationSession?.requestPin()
            return
        case .ordinarySelection:
            selectedOverlay?.overlayViewDidRequestPin()
            return
        case .blocked:
            return
        case .clipboard:
            break
        }

        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            showNoPinClipboardContentAlert()
            return
        }

        switch ClipboardPinService.image(from: item) {
        case .image(let image):
            showPin(image: image)
        case .text(let image, let content):
            showTextPin(image: image, content: content)
        case .unsupported:
            showNoPinClipboardContentAlert()
        }
    }

    private func showTextPin(image: NSImage, content: String) {
        allPinsHidden = false
        let pin = PinWindowController(image: image, textContent: content)
        pin.delegate = self
        pin.show()
        pinControllers.forEach { $0.setSelected(false) }
        pin.setSelected(true)
        pinControllers.append(pin)
    }

    @objc private func toggleAllPinsVisibility() {
        guard !pinControllers.isEmpty else { return }
        allPinsHidden.toggle()
        pinControllers.forEach { $0.setTemporarilyHidden(allPinsHidden) }
        rebuildStatusBarMenu()
    }

    private func showNoPinClipboardContentAlert() {
        let alert = NSAlert()
        alert.messageText = L("No Image or Text on Clipboard")
        alert.informativeText = L("Copy an image or text to the clipboard first, then try again.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    private func openImageWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .image]
        panel.message = L("Choose an image to pin to screen")

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openImageFile(url: url)
            }
        }
    }

    private func openImageFile(url: URL) {
        let image: NSImage
        if url.pathExtension.lowercased() == "webp",
           let data = try? Data(contentsOf: url),
           let decoded = try? WebPDecoder().decode(toNSImage: data, options: WebPDecoderOptions()) {
            image = decoded
        } else if let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            return
        }
        showPin(image: image)
    }

    // MARK: - Open Video

    @objc private func openVideoFromMenu() {
        openVideoWithPanel()
    }

    private func openVideoWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video, .gif]
        panel.message = L("Choose a video to open in Pinlume editor")

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openVideoFile(url: url)
            }
        }
    }

    private func openVideoFile(url: URL) {
        // Never let the editor delete the user's source file on close.
        VideoEditorWindowController.open(url: url, deleteOnClose: false)
    }

    /// Handle files opened via Finder "Open With", drag-to-dock, or command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif", "webp", "icns"]
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        for url in urls {
            if url.scheme == BuildVariant.actionsURLScheme {
                let urlSchemeEnabled = UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true
                guard urlSchemeEnabled else { continue }
                handleURLSchemeAction(url)
                continue
            }
            let ext = url.pathExtension.lowercased()
            // GIFs can be opened in either the image editor or the video
            // editor. Default to image editor (matches prior behavior) — users
            // wanting to trim a GIF use "Open Video..." explicitly.
            if imageExtensions.contains(ext) {
                openImageFile(url: url)
            } else if videoExtensions.contains(ext) {
                openVideoFile(url: url)
            }
        }
    }

    /// Handle URL scheme actions from external tools (Raycast, Alfred, etc.).
    /// Usage: `open pinlume://capture` or `open pinlume://capture`.
    private func handleURLSchemeAction(_ url: URL) {
        guard let action = url.host else { return }
        defer { pendingCaptureTrigger = nil }
        switch action {
        case "capture", "capture-fullscreen", "quick-capture", "ocr", "record", "record-fullscreen", "scroll-capture", "capture-last":
            pendingCaptureTrigger = .urlScheme
        default:
            break
        }
        switch action {
        case "capture":             captureScreen()
        case "capture-fullscreen":  captureFullScreen()
        case "quick-capture":       quickCapture()
        case "ocr":                 captureOCR()
        case "record":              recordArea()
        case "record-fullscreen":   recordFullScreen()
        case "scroll-capture":      scrollCapture()
        case "history":             showHistoryOverlay()
        case "settings":            openSettings()
        case "stop-recording":      stopRecording()
        case "capture-last":        captureLastArea()
        case "open":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "file" })?.value {
                openImageFile(url: URL(fileURLWithPath: path))
            }
        default: break
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        ensureSettingsController().showWindow()
    }

    @discardableResult
    private func ensureSettingsController() -> SettingsWindowController {
        if let settingsController { return settingsController }
        let controller = SettingsWindowController()
        controller.onHotkeyChanged = { [weak self] in
            self?.refreshSettingsProfileRuntime()
        }
        controller.onStorageCleanup = { [weak self] options, completion in
            self?.clearAppStorage(options, completion: completion)
        }
        settingsController = controller
        return controller
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SelectedTextTranslationPreference.reconcilePermission()
        settingsController?.refreshSelectedTextTranslationPermissionState()
    }

    /// The only profile-application route: validate first, write the existing
    /// preference keys transactionally, then refresh shared runtime surfaces.
    func applySettingsProfile(_ profile: SettingsProfile) throws {
        let coordinator = SettingsProfileApplyCoordinator()
        try coordinator.validate(profile)
        try settingsProfileRuntimeCoordinator.preflightHotkeys(profile.payload)
        try coordinator.apply(profile)
        refreshSettingsProfileRuntime()
    }

    /// Restores just the active profile's shortcut settings. This is used by
    /// the settings reset action so protected profiles remain protected rather
    /// than being copied after their own defaults are restored.
    func applySettingsProfileShortcuts(_ profile: SettingsProfile) throws {
        try settingsProfileRuntimeCoordinator.preflightHotkeys(profile.payload)
        try SettingsProfilePreferenceBridge().applyShortcutPreferences(from: profile.payload)
        refreshSettingsProfileRuntime()
    }

    private func refreshSettingsProfileRuntime() {
        ToolbarColorScheme.applyCurrentAppearance(appearance: NSApp.effectiveAppearance)
        refreshStatusBarIcon()
        settingsProfileRuntimeCoordinator.refreshAfterApply()
        pinControllers.forEach { $0.refreshAfterSettingsProfileApply() }
        settingsController?.refreshAfterSettingsProfileApply()
    }

    private func clearAppStorage(_ options: AppStorageCleanupOptions, completion: @escaping () -> Void) {
        let pending = DispatchGroup()
        if options.contains(.history) {
            pending.enter()
            ScreenshotHistory.shared.clear {
                pending.leave()
            }
        }
        if options.contains(.clipboard) { ClipboardBackingStore.clear() }
        if options.contains(.diagnostics) { DiagnosticLogStore.clear() }
        if options.contains(.pins) {
            pinControllers.forEach { $0.close() }
            pinControllers.removeAll()
            PinPersistenceStore.clear()
            pinPersistenceSession = PinPersistenceStore.open()
        }
        pending.notify(queue: .main, execute: completion)
    }

    // MARK: - Quit

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

}

// MARK: - OverlayWindowControllerDelegate

extension AppDelegate: OverlayWindowControllerDelegate {
    func overlayDidBeginModalSave(_ controller: OverlayWindowController) {
        for other in overlayControllers where other !== controller {
            other.suspendForModalSave()
        }
    }

    func overlayDidEndModalSave(_ controller: OverlayWindowController, restoreOverlays: Bool) {
        guard restoreOverlays else { return }
        for other in overlayControllers where other !== controller {
            other.restoreAfterModalSave()
        }
    }

    func overlayDidRequestScreenTranslation(
        _ controller: OverlayWindowController, image: NSImage,
        result: StructuredOCRResult, initialFrame: NSRect, requestToken: Int
    ) {
        let token = screenTranslationState.begin()
        translateScreenBlocks(result.blocks, targetOverride: nil) { [weak self] translated, source, target in
            guard let self, self.screenTranslationState.accept(token) else { return }
            TranslatedImageRenderer.render(image: image, blocks: translated) {
                [weak self] rendered, translatedSelectionBlocks in
                guard let self, self.screenTranslationState.accept(token) else { return }
                let session = ScreenTranslationSession(
                    originalImage: image, translatedImage: rendered,
                    translatedBlocks: translated, sourceLanguage: source,
                    targetLanguage: target, globalFrame: initialFrame,
                    originalBlocks: result.blocks,
                    translatedSelectionBlocks: translatedSelectionBlocks)
                controller.finishScreenTranslation(
                    requestToken: requestToken, session: session)
            }
        }
    }

    func overlayDidRequestScreenTranslationPin(
        _ controller: OverlayWindowController, session: ScreenTranslationSession
    ) {
        receiveScreenTranslationPin(session)
    }

    func overlayDidRequestOpenScreenTranslation(
        _ controller: OverlayWindowController, session: ScreenTranslationSession
    ) {
        dismissOverlays(refocusPreviousApp: false)
        openTranslationWindow(
            sourceText: session.originalText,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage)
    }

    private func translateScreenBlocks(
        _ blocks: [RecognizedTextBlock], targetOverride: String?,
        completion: @escaping ([TranslatedTextBlock], String, String) -> Void
    ) {
        let paragraphs = OCRTextParagraph.group(blocks: blocks)
        let plain = paragraphs.map(\.text).joined(separator: "\n\n")
        let source = TranslationTextProcessor.detectedSourceLanguage(for: plain)
        let target = targetOverride
            ?? TranslationTextProcessor.automaticTargetLanguage(for: plain)
        let plans = paragraphs.map {
            target == "zh-CN"
                ? TranslationTextProcessor.segmentsForAutomaticTranslation(
                    $0.text, detectedSourceLanguage: source)
                : TranslationTextProcessor.segments(
                    for: $0.text, direction: .englishToSimplifiedChinese)
        }
        let requests = plans.flatMap { $0.filter { $0.kind == .translatable }.map(\.requestText) }
        guard !requests.isEmpty else {
            completion(paragraphs.map {
                TranslatedTextBlock(block: $0.recognizedBlock, translatedText: $0.text)
            }, source, target)
            return
        }
        TranslationService.translateBatch(
            texts: requests, sourceLang: source, targetLang: target) { result in
            let values = (try? result.get()) ?? []
            var cursor = 0
            let output = zip(paragraphs, plans).map { paragraph, segments -> TranslatedTextBlock in
                let text = segments.map { segment -> String in
                    guard segment.kind == .translatable else { return segment.original }
                    defer { cursor += 1 }
                    guard cursor < values.count, !values[cursor].isEmpty else { return segment.original }
                    return values[cursor]
                }.joined()
                return TranslatedTextBlock(block: paragraph.recognizedBlock, translatedText: text)
            }
            completion(output, source, target)
        }
    }

    private func recaptureScreenTranslation(
        at globalFrame: NSRect,
        in window: ScreenTranslationWindowController
    ) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(globalFrame) }) else {
            window.showStatus(L("Screen translation must stay on one display"))
            window.show()
            return
        }

        let token = screenTranslationState.begin()
        let excludedWindowNumbers = window.excludedWindowNumbersForRecapture()
        window.prepareForRecapture()
        ScreenCaptureManager.captureAllScreens(excludingWindowNumbers: excludedWindowNumbers) { [weak self, weak window] captures in
            guard let self, let window, self.screenTranslationState.accept(token) else { return }
            guard let capture = captures.first(where: { $0.screen == screen }),
                  let image = Self.cropScreenCapture(capture, to: globalFrame),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                window.showStatus(L("Unable to capture selection"))
                window.show()
                return
            }

            VisionOCR.performStructuredTextRecognition(
                cgImage: cgImage,
                mode: .screenTranslation) { [weak self, weak window] result in
                guard let self, let window, self.screenTranslationState.accept(token) else { return }
                guard case .success(let structured) = result, !structured.blocks.isEmpty else {
                    window.showStatus(L("No text found"))
                    window.show()
                    return
                }
                self.translateScreenBlocks(structured.blocks, targetOverride: nil) { translated, source, target in
                    guard self.screenTranslationState.accept(token) else { return }
                    TranslatedImageRenderer.render(image: image, blocks: translated) {
                        rendered, translatedSelectionBlocks in
                        guard self.screenTranslationState.accept(token) else { return }
                        window.update(session: ScreenTranslationSession(
                            originalImage: image,
                            translatedImage: rendered,
                            translatedBlocks: translated,
                            sourceLanguage: source,
                            targetLanguage: target,
                            globalFrame: globalFrame,
                            originalBlocks: structured.blocks,
                            translatedSelectionBlocks: translatedSelectionBlocks))
                    }
                }
            }
        }
    }

    private static func cropScreenCapture(_ capture: ScreenCapture, to globalFrame: NSRect) -> NSImage? {
        let screenFrame = capture.screen.frame
        let local = globalFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.minX >= 0, local.minY >= 0,
              local.maxX <= screenFrame.width, local.maxY <= screenFrame.height
        else { return nil }

        let scaleX = CGFloat(capture.image.width) / screenFrame.width
        let scaleY = CGFloat(capture.image.height) / screenFrame.height
        let crop = CGRect(
            x: local.minX * scaleX,
            y: (screenFrame.height - local.maxY) * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
        guard crop.width > 0, crop.height > 0,
              let cropped = capture.image.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: globalFrame.size)
    }

    func receiveScreenTranslationPin(_ session: ScreenTranslationSession) {
        let appToRefocus = previousApp
        screenTranslationState.cancel()
        dismissOverlays(refocusPreviousApp: false)
        allPinsHidden = false
        pinControllers.forEach { $0.setSelected(false) }

        var pinSessions: [ScreenTranslationSession] = []
        if session.comparisonEnabled,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(session.globalFrame) }),
           let comparisonFrame = ScreenTranslationGeometry.comparisonFrame(
            primary: session.globalFrame, visibleFrame: screen.frame) {
            var original = session
            original.displayMode = .original
            original.comparisonEnabled = false
            var translated = session
            translated.displayMode = .translated
            translated.comparisonEnabled = false
            translated = ScreenTranslationSession(
                originalImage: translated.originalImage,
                translatedImage: translated.translatedImage,
                translatedBlocks: translated.translatedBlocks,
                sourceLanguage: translated.sourceLanguage,
                targetLanguage: translated.targetLanguage,
                globalFrame: comparisonFrame,
                originalBlocks: translated.originalBlocks,
                translatedSelectionBlocks: translated.translatedSelectionBlocks,
                displayMode: translated.displayMode,
                comparisonEnabled: false)
            pinSessions = [original, translated]
        } else {
            var single = session
            single.comparisonEnabled = false
            pinSessions = [single]
        }

        for (index, pinSession) in pinSessions.enumerated() {
            let displayedImage = pinSession.displayMode == .original
                ? pinSession.originalImage : pinSession.translatedImage
            let pin = PinWindowController(
                image: displayedImage, initialFrame: pinSession.globalFrame,
                translationSession: pinSession)
            pin.delegate = self
            pin.show()
            pin.setSelected(index == pinSessions.count - 1)
            pinControllers.append(pin)
        }
        screenTranslationController?.close()
        screenTranslationController = nil
        if let app = appToRefocus, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }
    func overlayDidCancel(_ controller: OverlayWindowController) {
        // If the user cancels while in recording setup (before capture started),
        // just dismiss. If recording is actively capturing, stop it.
        if controller === recordingOverlayController, recordingLifecycle.state != .idle {
            stopRecording()
            // stopRecordingUI() runs after the writer completion callback.
        }
        dismissOverlays()

        // Focus is returned to the previous app by dismissOverlays() above.
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?) {
        handleOverlayConfirmation(
            controller,
            capturedImage: capturedImage,
            annotationData: annotationData,
            showsFloatingThumbnail: false
        )
    }

    func overlayDidConfirmQuickCapture(
        _ controller: OverlayWindowController,
        capturedImage: NSImage?,
        annotationData: CaptureAnnotationData?
    ) {
        handleOverlayConfirmation(
            controller,
            capturedImage: capturedImage,
            annotationData: annotationData,
            showsFloatingThumbnail: true
        )
    }

    private func handleOverlayConfirmation(
        _ controller: OverlayWindowController,
        capturedImage: NSImage?,
        annotationData: CaptureAnnotationData?,
        showsFloatingThumbnail: Bool
    ) {
        captureTimingTrace?.mark("overlayDidConfirm entered image=\(capturedImage != nil)")
        let thumbnailScreen = controller.screen
        dismissOverlays()
        captureTimingTrace?.mark("overlayDidConfirm after dismissOverlays")
        if let image = capturedImage {
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: annotationData?.rawImage,
                annotations: annotationData?.annotations,
                editState: annotationData?.editState)
            captureTimingTrace?.mark("screenshot added to history")
            // The entry just added is at index 0
            let entryID = ScreenshotHistory.shared.entries.first?.id
            if showsFloatingThumbnail {
                // Defer thumbnail to the next run loop so overlay teardown is
                // complete. Ordinary selection Copy intentionally skips it.
                let annData = annotationData
                DispatchQueue.main.async { [weak self] in
                    self?.showFloatingThumbnail(
                        image: image,
                        annotationData: annData,
                        historyEntryID: entryID,
                        preferredScreen: thumbnailScreen
                    )
                }
            }

            if let report = finishCaptureTimingReport("timing report generated") {
                DispatchQueue.main.async { [weak self] in
                    self?.showCaptureTimingDialog(report)
                }
            }
        }
    }

    func overlayDidCopyQuickCaptureToClipboard(_ controller: OverlayWindowController) {
        showClipboardToast(L("Quick capture copied to clipboard"))
    }

    func overlayDidCopySelectableText(_ controller: OverlayWindowController, text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        showOverlayStyleClipboardMessage(L("Text copied"))
        if let app = appToRefocus, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    private func stitchCrossScreenCapture(primary: OverlayWindowController, others: [OverlayWindowController]) -> NSImage? {
        let primaryOrigin = primary.screen.frame.origin
        let primarySelRect = primary.selectionRect
        // Global selection rect
        let globalRect = NSRect(x: primarySelRect.origin.x + primaryOrigin.x,
                                y: primarySelRect.origin.y + primaryOrigin.y,
                                width: primarySelRect.width, height: primarySelRect.height)

        // Determine scale from primary screen
        let scale: CGFloat
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = primary.screen.backingScaleFactor
        }

        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        // Use the source image's color space to avoid expensive conversion
        let cs: CGColorSpace
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let cgCtx = CGContext(data: nil, width: pixelW, height: pixelH,
                                     bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        cgCtx.scaleBy(x: scale, y: scale)

        // Draw each screen's contribution
        let allControllers = [primary] + others
        for controller in allControllers {
            guard let screenshot = controller.screenshotImage else { continue }
            let screenFrame = controller.screen.frame
            // Where this screen sits relative to the global selection rect
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)

            cgCtx.saveGState()
            // Clip to only the portion within our output bounds
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?, initialFrame: NSRect?) {
        ScreenshotHistory.shared.add(
            image: image,
            rawImage: annotationData?.rawImage,
            annotations: annotationData?.annotations,
            editState: annotationData?.editState
        )
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        allPinsHidden = false
        let pin = PinWindowController(image: image, initialFrame: initialFrame)
        pin.delegate = self
        pin.show()
        pinControllers.forEach { $0.setSelected(false) }
        pin.setSelected(true)
        pinControllers.append(pin)
        // Return focus to previous app — pin stays visible (hidesOnDeactivate=false, orderFrontRegardless)
        if let app = appToRefocus, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    func overlayDidRequestSelectableTextPin(
        _ controller: OverlayWindowController,
        image: NSImage,
        initialFrame: NSRect?,
        result: StructuredOCRResult?
    ) {
        guard let result, !result.blocks.isEmpty else { return }
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        allPinsHidden = false
        let pin = PinWindowController(image: image, initialFrame: initialFrame)
        pin.delegate = self
        pin.show()
        pinControllers.forEach { $0.setSelected(false) }
        pin.setSelected(true)
        pinControllers.append(pin)
        pin.beginTextSelectionMode(blocks: result.blocks, dedicatedOCR: true)
        if let app = appToRefocus, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {
        // OCR & QR action: 0 = window + copy (default), 1 = window only, 2 = copy only
        let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
        let shouldCopy = ocrAction == 0 || ocrAction == 2
        let shouldShowWindow = ocrAction == 0 || ocrAction == 1
        dismissOverlays(refocusPreviousApp: !shouldShowWindow)

        if shouldCopy && !result.copyText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.copyText, forType: .string)
        }

        if shouldShowWindow {
            ocrController?.close()
            let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
            ocr.onClose = { [weak self, weak ocr] in
                if self?.ocrController === ocr { self?.ocrController = nil }
            }
            ocrController = ocr
            ocr.show()
        }
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {
        #if !OFFLINE
        _ = showUploadProgress(
            image: image,
            sourceOverlay: controller,
            onSuccess: { [weak self] _ in
                guard let self else { return }
                self.playCopySound()
                ScreenshotHistory.shared.add(
                    image: image,
                    rawImage: annotationData?.rawImage,
                    annotations: annotationData?.annotations,
                    editState: annotationData?.editState
                )
                let appToRefocus = self.previousApp
                // Return focus — upload toast stays visible (hidesOnDeactivate=false).
                if let app = appToRefocus, !app.isTerminated,
                   app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    DispatchQueue.main.async { AppDelegate.activateApp(app) }
                }
            }
        )
        #endif
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        // Capture session overrides before dismissing overlays (which destroys the overlay view)
        let fpsOverride = controller.sessionRecordingFPS
        let onStopOverride = controller.sessionRecordingOnStop
        let delayOverride = controller.sessionRecordingDelay
        let hideHUD = controller.sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")
        let delay = delayOverride ?? UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        let generation = delay > 0
            ? recordingLifecycle.beginCountdown()
            : recordingLifecycle.beginStarting()
        guard let generation else { return }
        recordingScreenRect = rect
        recordingScreen = screen

        // Detach webcam preview before dismissing overlays so we can reuse the live session
        let existingWebcam = controller.detachWebcamPreview()

        // Use the same focus return path as normal screenshot confirm:
        // dismissOverlays with refocus → returnFocusIfNeeded → NSApp.hide(nil).
        // This reliably transfers focus AND mouse event routing.
        // Then create recording UI on the next run loop — all non-activating
        // panels, so they appear without stealing focus back.
        dismissOverlays()  // refocusPreviousApp: true (default) — handles focus
        previousApp = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if delay > 0 {
                guard self.recordingLifecycle.generation == generation,
                      self.recordingLifecycle.state == .countdown else { return }
                existingWebcam?.stopPreview()
                existingWebcam?.close()
                self.startRecordingCountdown(seconds: delay, rect: rect, screen: screen,
                                             fpsOverride: fpsOverride,
                                             onStopOverride: onStopOverride,
                                             generation: generation)
            } else {
                guard self.recordingLifecycle.generation == generation,
                      self.recordingLifecycle.state == .starting else { return }
                self.beginRecording(rect: rect, screen: screen,
                                    fpsOverride: fpsOverride,
                                    onStopOverride: onStopOverride,
                                    existingWebcam: existingWebcam,
                                    hideHUD: hideHUD,
                                    generation: generation)
            }
        }
    }

    private func startRecordingCountdown(seconds: Int, rect: NSRect, screen: NSScreen,
                                          fpsOverride: Int?,
                                          onStopOverride: String?,
                                          generation: UInt) {
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Show selection border during countdown so user sees what area will be recorded
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorderOverlay = border

        // Escape to cancel
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelRecordingCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self,
                  self.recordingLifecycle.generation == generation,
                  self.recordingLifecycle.state == .countdown else {
                timer.invalidate()
                return
            }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.delayTimer = nil
                self.delayCountdownWindow?.orderOut(nil)
                self.delayCountdownWindow = nil
                self.removeDelayEscMonitors()
                guard self.recordingLifecycle.markStarting(generation: generation) else { return }
                self.beginRecording(rect: rect, screen: screen,
                                    fpsOverride: fpsOverride,
                                    onStopOverride: onStopOverride,
                                    generation: generation)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func cancelRecordingCountdown() {
        guard recordingLifecycle.state == .countdown else { return }
        _ = recordingLifecycle.stop()
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        removeDelayEscMonitors()
    }

    private func beginRecording(rect: NSRect, screen: NSScreen,
                                 fpsOverride: Int?,
                                 onStopOverride: String?,
                                 existingWebcam: WebcamOverlay? = nil,
                                 hideHUD: Bool = false,
                                 generation: UInt) {
        guard recordingLifecycle.generation == generation,
              recordingLifecycle.state == .starting else { return }
        let engine = RecordingEngine()
        engine.onStarted = { [weak self, weak engine] in
            guard let self, self.recordingEngine === engine,
                  self.recordingLifecycle.markRecording(generation: generation) else { return }
        }
        engine.onStopping = { [weak self, weak engine] in
            guard let self, self.recordingEngine === engine,
                  self.recordingLifecycle.generation == generation else { return }
            _ = self.recordingLifecycle.stop()
        }
        engine.onProgress = { [weak self, weak engine] seconds in
            guard let self, self.recordingEngine === engine,
                  self.recordingLifecycle.generation == generation,
                  self.recordingLifecycle.state == .recording else { return }
            self.updateRecordingHUD(seconds: seconds)
        }
        // Capture audio settings before recording starts (they may change during)
        let hadSystemAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
        let hadMicAudio = UserDefaults.standard.bool(forKey: "recordMicAudio")

        engine.onCompletion = { [weak self, weak engine] url, error in
            guard let self, self.recordingEngine === engine,
                  self.recordingLifecycle.generation == generation else { return }
            let finished = error == nil
                ? self.recordingLifecycle.complete(generation: generation)
                : self.recordingLifecycle.abort(generation: generation)
            guard finished else { return }
            self.stopRecordingUI()

            if self.recordingTerminationPending {
                self.recordingTerminationPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            if let url = url {
                let deliverRecording: (URL) -> Void = { [weak self] finalURL in
                    guard let self = self else { return }
                    let onStop = onStopOverride ?? UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
                    switch onStop {
                    case "finder":
                        // Move the recording out of our sandbox tmp to a
                        // user-visible directory before revealing. Otherwise
                        // Finder would open inside the sandbox container
                        // (confusing to navigate, and our launch sweep can't
                        // safely clean tmp Recordings since they look
                        // user-managed).
                        self.revealRecordingInFinder(tmpURL: finalURL)
                    case "clipboard":
                        self.copyRecordingToClipboard(url: finalURL)
                    default:
                        VideoEditorWindowController.open(url: finalURL)
                    }
                }

                // Offer audio merge when both mic + system audio were recorded
                if hadSystemAudio && hadMicAudio {
                    let merger = AudioMergeController()
                    self.audioMergeController = merger
                    merger.show(url: url) { [weak self] finalURL in
                        self?.audioMergeController = nil
                        deliverRecording(finalURL)
                    }
                } else {
                    deliverRecording(url)
                }
            } else if let error = error {
                #if DEBUG
                print("Recording failed: \(error.localizedDescription)")
                #endif
            }
        }
        recordingEngine = engine
        recordingElapsedSeconds = 0

        // Always show selection border so user knows what area is being recorded
        // (may already exist from countdown — recreate to be safe)
        selectionBorderOverlay?.close()
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorderOverlay = border

        if !hideHUD {
            // Show the floating timer HUD
            let hud = RecordingHUDPanel()
            hud.update(elapsedSeconds: 0)
            hud.positionOnScreen(relativeTo: rect, screen: screen)
            hud.onStopRecording = { [weak self] in
                self?.stopRecording()
            }
            hud.onPauseRecording = { [weak self] in
                guard let self, self.recordingLifecycle.pause(generation: generation) else { return }
                self.recordingEngine?.pauseRecording()
            }
            hud.onResumeRecording = { [weak self] in
                guard let self, self.recordingLifecycle.resume(generation: generation) else { return }
                self.recordingEngine?.resumeRecording()
            }
            hud.orderFrontRegardless()
            recordingHUDPanel = hud

            engine.onPauseChanged = { [weak self] paused in
                self?.recordingHUDPanel?.setPaused(paused)
            }
        }

        // Start mouse highlight overlay if enabled (requires Input Monitoring permission)
        if UserDefaults.standard.bool(forKey: "recordMouseHighlight") && CGPreflightListenEventAccess() {
            let overlay = MouseHighlightOverlay(screen: screen)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            mouseHighlightOverlay = overlay
        }

        // Start keystroke overlay if enabled
        if UserDefaults.standard.bool(forKey: "recordKeystroke") && KeystrokeOverlay.hasInputMonitoringPermission {
            let overlay = KeystrokeOverlay(screen: screen)
            overlay.setRecordingRect(rect)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            keystrokeOverlay = overlay
        }

        // Start webcam overlay if enabled — reuse existing session to avoid camera restart flash
        if UserDefaults.standard.bool(forKey: "recordWebcam") &&
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            if let existing = existingWebcam {
                // Reuse the live preview — just lock it in place
                existing.setDraggable(false)
                existing.orderFrontRegardless()
                webcamOverlay = existing
            } else {
                let overlay = WebcamOverlay(screen: screen)
                let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
                let wcSize = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
                let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle
                overlay.configure(position: position, size: wcSize, shape: shape, recordingRect: rect)
                overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
                overlay.setDraggable(false)
                overlay.orderFrontRegardless()
                webcamOverlay = overlay
            }
        } else {
            // Webcam not enabled — clean up any detached preview
            existingWebcam?.stopPreview()
            existingWebcam?.close()
        }

        if let hud = recordingHUDPanel, !hud.userHasDragged {
            hud.positionOnScreen(relativeTo: rect, screen: screen, avoiding: webcamOverlay?.frame)
        }

        // Keep the status-bar menu available during recording: it exposes Stop
        // plus every non-recording capture action.
        enterRecordingMenuBarMode()

        // Collect window IDs of UI chrome to exclude from the recording
        // (selection border + HUD). Webcam, mouse highlight, and keystroke
        // overlays are intentionally captured.
        var excludeIDs: [CGWindowID] = []
        if let w = selectionBorderOverlay { excludeIDs.append(CGWindowID(w.windowNumber)) }
        if let w = recordingHUDPanel { excludeIDs.append(CGWindowID(w.windowNumber)) }

        // Start recording
        engine.startRecording(rect: rect, screen: screen, fpsOverride: fpsOverride, excludeWindowNumbers: excludeIDs)
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        stopRecording()
    }

    // MARK: - Recording UI

    @objc private func stopRecording() {
        let wasCountdown = recordingLifecycle.state == .countdown
        guard recordingLifecycle.stop() != nil else { return }
        if wasCountdown {
            cancelRecordingCountdownUI()
            return
        }
        recordingEngine?.stopRecording()
    }

    private func cancelRecordingCountdownUI() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        removeDelayEscMonitors()
    }

    private func updateRecordingHUD(seconds: Int) {
        recordingElapsedSeconds = seconds
        recordingHUDPanel?.update(elapsedSeconds: seconds)
        recordingStatusMenuItem?.title = recordingStatusTitle()
        if let screen = recordingScreen, !(recordingHUDPanel?.userHasDragged ?? false) {
            recordingHUDPanel?.positionOnScreen(
                relativeTo: recordingScreenRect,
                screen: screen,
                avoiding: webcamOverlay?.frame
            )
        }
    }

    private func enterRecordingMenuBarMode() {
        menuBarIconWasHidden = UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        if menuBarIconWasHidden {
            setMenuBarIconVisible(true)
        }
        // Keep the menu available; the first two items show the elapsed time
        // and provide Stop Recording, while new recording actions are disabled.
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 22, height: 22)
        }
        rebuildStatusBarMenu()
    }

    private func exitRecordingMenuBarMode() {
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()

        // Hide icon again if user had it hidden before recording
        if menuBarIconWasHidden {
            setMenuBarIconVisible(false)
            menuBarIconWasHidden = false
        }
    }

    /// Move a recording out of our sandbox tmp to a user-visible directory
    /// and reveal it in Finder. Used by the `recordingOnStop = "finder"`
    /// flow so the user doesn't end up staring at a deep sandbox path.
    ///
    /// Resolution order:
    ///   1. Recording save directory (if configured + bookmark still valid)
    ///   2. Same as screenshots (if configured + bookmark still valid)
    ///   3. Save panel — user picks a location explicitly
    ///
    /// On a collision at the destination, we append " (N)" to the filename
    /// so nothing gets silently overwritten.
    private func revealRecordingInFinder(tmpURL: URL) {
        // Try the configured recording dir first.
        if let recDir = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() {
            defer { SaveDirectoryAccess.stopAccessing(url: recDir) }
            if let moved = moveRecording(from: tmpURL, intoDirectory: recDir) {
                NSWorkspace.shared.activateFileViewerSelecting([moved])
                return
            }
        }
        // Fall back to the general screenshot save directory if THAT has a
        // valid security-scoped bookmark (without one we have no sandbox write
        // access). resolveIfAccessible() returns nil precisely in that case.
        if let screenshotDir = SaveDirectoryAccess.resolveIfAccessible() {
            defer { SaveDirectoryAccess.stopAccessing(url: screenshotDir) }
            if let moved = moveRecording(from: tmpURL, intoDirectory: screenshotDir) {
                NSWorkspace.shared.activateFileViewerSelecting([moved])
                return
            }
        }
        // No usable saved location — prompt the user via NSSavePanel.
        promptToSaveRecording(tmpURL: tmpURL)
    }

    /// Move `src` into `dir`, renaming on collision, returning the new URL.
    /// Returns nil if the move fails (bad permissions, disk full, etc.).
    private func moveRecording(from src: URL, intoDirectory dir: URL) -> URL? {
        let name = src.lastPathComponent
        do {
            let dest = try TransactionalOutput.reserveUnique(in: dir, filename: name)
            try TransactionalOutput.transfer(src, to: dest, reservedDestination: true)
            return dest
        } catch {
            return nil
        }
    }

    /// Last-resort: the user has no configured save dir, so ask them where
    /// to put the recording. On cancel we leave the tmp file in place —
    /// the launch sweep won't touch it (Recording prefix is preserved)
    /// but the user can still deal with it manually if they want.
    private func promptToSaveRecording(tmpURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tmpURL.lastPathComponent
        panel.title = L("Save Recording")
        panel.prompt = L("Save")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try TransactionalOutput.transferFileScoped(tmpURL, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                self.showOutputSaveFailure(error)
            }
        }
    }

    private func copyRecordingToClipboard(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Move the recording to a fixed clipboard path so we only ever have
        // one-per-extension on disk. The user's recording tmp at `url` would
        // otherwise linger forever (the pasteboard keeps the file URL
        // reference so we can't delete it; but we can overwrite the same
        // fixed path on the next clipboard copy).
        let ext = url.pathExtension.lowercased()
        let fixedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pinlume-clipboard-recording.\(ext)")
        try? FileManager.default.removeItem(at: fixedURL)
        let pasteURL: URL
        if (try? FileManager.default.moveItem(at: url, to: fixedURL)) != nil {
            pasteURL = fixedURL
        } else {
            // Move failed (cross-volume? permissions?) — fall back to the
            // original path. Launch sweep will still clean it up later.
            pasteURL = url
        }

        if ext == "gif", let data = try? Data(contentsOf: pasteURL) {
            // Write raw GIF data so apps can render the animation inline
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            // Also add file URL for Finder compatibility
            item.setString(pasteURL.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            // MP4: write file URL (apps like Slack/Discord accept file drops)
            pasteboard.writeObjects([pasteURL as NSURL])
        }
        playCopySound()
    }

    private func stopRecordingUI() {
        recordingHUDPanel?.close()
        recordingHUDPanel = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        mouseHighlightOverlay?.stopMonitoring()
        mouseHighlightOverlay?.close()
        mouseHighlightOverlay = nil
        keystrokeOverlay?.stopMonitoring()
        keystrokeOverlay?.close()
        keystrokeOverlay = nil
        webcamOverlay?.stopPreview()
        webcamOverlay?.close()
        webcamOverlay = nil
        recordingEngine = nil
        recordingElapsedSeconds = 0
        recordingOverlayController = nil
        recordingScreenRect = .zero
        recordingScreen = nil
        exitRecordingMenuBarMode()
    }

    private var recordingCaptureChromeWindowNumbers: [CGWindowID] {
        guard recordingEngine != nil else { return [] }
        return [selectionBorderOverlay, recordingHUDPanel].compactMap {
            guard let window = $0 else { return nil }
            return CGWindowID(window.windowNumber)
        }
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        if !AXIsProcessTrusted() {
            dismissOverlays()
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required")
            alert.informativeText = L("Pinlume needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Open Settings"))
            alert.addButton(withTitle: L("Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        scrollCaptureOverlayController = controller

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        scc.excludedWindowIDs = overlayControllers.map { $0.windowNumber }
        scrollCaptureController = scc

        // Read max height for the overlay HUD progress bar
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000

        // Tell the triggering overlay to enter scroll capture mode
        controller.setScrollCaptureState(isActive: true, maxHeight: maxH)

        // Create live preview panel if there's space beside the capture region
        let overlayLevel = 257  // matches overlay window level
        if let previewPanel = ScrollCapturePreviewPanel(captureRect: rect, screen: screen, overlayLevel: overlayLevel) {
            previewPanel.orderFront(nil)
            scrollCapturePreviewPanel = previewPanel
        }

        scc.onStripAdded = { [weak self, weak controller] count in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: count, pixelSize: scc.stitchedPixelSize,
                autoScrolling: scc.autoScrollActive)
        }
        scc.onPreviewUpdated = { [weak self] image in
            self?.scrollCapturePreviewPanel?.updatePreview(image: image)
        }
        scc.onAutoScrollStarted = { [weak self, weak controller] in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
                autoScrolling: true)
        }
        scc.onSessionDone = { [weak self] finalImage in
            self?.handleScrollCaptureCompleted(finalImage: finalImage)
        }

        Task { await scc.startSession() }
    }

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {
        scrollCaptureController?.stopSession()
        // onSessionDone fires asynchronously via handleScrollCaptureCompleted
    }

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        let alert = NSAlert()
        alert.messageText = L("Accessibility Access Required")
        alert.informativeText = L("Pinlume needs Accessibility permission to show keystrokes during recording. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        KeystrokeOverlay.requestInputMonitoringPermission()
        let alert = NSAlert()
        alert.messageText = L("Input Monitoring Required")
        alert.informativeText = L("Pinlume needs Input Monitoring permission to show keystrokes during recording. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {
        guard let scc = scrollCaptureController else { return }

        // If turning on, check Accessibility permission first
        if !scc.autoScrollActive {
            if !AXIsProcessTrusted() {
                // Cancel session without delivering a result, then dismiss overlays
                scc.cancelSession()
                scrollCaptureController = nil
                scrollCapturePreviewPanel?.close()
                scrollCapturePreviewPanel = nil
                scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
                scrollCaptureOverlayController = nil
                dismissOverlays()

                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                let alert = NSAlert()
                alert.messageText = L("Accessibility Access Required")
                alert.informativeText = L("Pinlume needs Accessibility permission to auto-scroll other apps. Please grant access in System Settings, then try again.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("Open Settings"))
                alert.addButton(withTitle: L("Cancel"))
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                return
            }
        }

        scc.toggleAutoScroll()
        let autoScrolling = scc.isActive && scc.autoScrollActive
        controller.updateScrollCaptureProgress(
            stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
            autoScrolling: autoScrolling)
    }

    func overlayDidRequestPointerFocus(_ controller: OverlayWindowController) {
        guard overlayControllers.allSatisfy({
            $0.selectionRect.width < 1 && $0.selectionRect.height < 1
        }) else { return }
        controller.makeKey()
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        captureTimingTrace?.mark("user began selection")
        for other in overlayControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in overlayControllers where other !== controller {
            other.setRemoteSelection(.zero)
        }
    }

    func overlayDidRequestFullScreenAtMouse(_ controller: OverlayWindowController) {
        let mouse = NSEvent.mouseLocation
        let target = overlayControllers.first { $0.screen.frame.contains(mouse) } ?? controller
        for other in overlayControllers where other !== target {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
        target.applyFullScreenSelection()
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Update the primary screen's actual selection
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)

        // Update other secondary screens (not the caller — it manages its own remoteSelectionRect during drag)
        for other in overlayControllers where other !== controller && other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Final sync after remote resize — update primary, re-sync ALL secondaries, transfer focus
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)
        primary.makeKey()

        // Re-sync ALL secondary screens (including the caller) from the primary's authoritative rect
        let primarySel = primary.selectionRect
        let primaryGlobal = NSRect(x: primarySel.origin.x + primaryOrigin.x,
                                   y: primarySel.origin.y + primaryOrigin.y,
                                   width: primarySel.width, height: primarySel.height)
        for other in overlayControllers where other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: primaryGlobal.origin.x - otherOrigin.x,
                                   y: primaryGlobal.origin.y - otherOrigin.y,
                                   width: primaryGlobal.width, height: primaryGlobal.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        nil
    }

    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController) {
        // Notify all other overlays to redraw (for multi-monitor setups)
        // When window snap state changes via Tab key, all overlays need to update
        // their helper text to show the new ON/OFF state
        for other in overlayControllers where other !== controller {
            other.triggerRedraw()
        }
    }

    private func handleScrollCaptureCompleted(finalImage: NSImage?) {
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        scrollCaptureController = nil

        dismissOverlays()

        guard let image = finalImage else { return }

        ScreenshotHistory.shared.add(image: image)
        let entryID = ScreenshotHistory.shared.entries.first?.id
        let outputAction = CaptureOutputAction.current()
        if outputAction.copiesToClipboard {
            ImageEncoder.copyToClipboard(image)
            showClipboardToast(L("Scroll capture copied to clipboard"))
        }
        if outputAction.savesToFolder {
            saveImageToConfiguredFolder(image)
        }
        playCopySound()
        if outputAction.pinsToScreen {
            showPin(image: image)
        } else {
            showFloatingThumbnail(image: image, historyEntryID: entryID)
        }
    }

}

// MARK: - PinWindowControllerDelegate

extension AppDelegate: PinWindowControllerDelegate {
    func pinWindowDidSelect(_ controller: PinWindowController) {
        pinControllers.forEach { $0.setSelected($0 === controller) }
    }

    func pinWindowDidClose(_ controller: PinWindowController) {
        pinControllers.removeAll { $0 === controller }
        if pinControllers.isEmpty {
            allPinsHidden = false
            rebuildStatusBarMenu()
        }
    }
}

// MARK: - NSMenuDelegate (status bar menu + Recent Captures submenu)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Only for the main status-bar menu (the history submenu rebuilds via
        // menuNeedsUpdate). Dismiss any active modal before the menu shows, and
        // pre-warm ScreenCaptureKit content while the user browses.
        guard menu === statusBarMenu else { return }
        ScreenCaptureManager.prewarm()
        if let modalWin = NSApp.modalWindow {
            NSApp.stopModal()
            modalWin.close()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only rebuild the history submenu, not the main status bar menu
        guard menu === historyMenu else { return }

        menu.removeAllItems()

        let entries = ScreenshotHistory.shared.entries
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: L("No recent captures"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for (i, entry) in entries.enumerated() {
            let title = "\(entry.pixelWidth) \u{00D7} \(entry.pixelHeight)  —  \(entry.timeAgoString)"
            let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = ScreenshotHistory.shared.loadThumbnail(for: entry)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: L("Clear History"), action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        clearItem.tag = 9000
        menu.addItem(clearItem)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        let index = sender.tag
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }

        ImageEncoder.copyToClipboard(image, sourceFileURL: ScreenshotHistory.shared.fileURL(for: entry))
        showFloatingThumbnail(image: image, historyEntryID: entry.id)

        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            Self.captureSound?.stop()
            Self.captureSound?.play()
        }
    }

    @objc private func clearHistory() {
        confirmClearHistory()
    }

    private func clearHistorySilently() {
        ScreenshotHistory.shared.clear()
    }

    /// Show a confirmation dialog before clearing all history. Reused by history panel trash button.
    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = L("Clear History?")
        alert.informativeText = L("This will permanently delete all screenshots from history.")
        alert.addButton(withTitle: L("Clear All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenshotHistory.shared.clear()
        }
    }
}
