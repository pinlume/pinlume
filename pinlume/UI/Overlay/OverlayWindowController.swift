import Cocoa
import CoreImage
import UniformTypeIdentifiers
import Vision
import os.log

private let overlaySaveLog = OSLog(subsystem: AppIdentity.bundleIdentifier, category: "Pinlume-save")

/// Editable annotation data bundled with a confirmed capture.
struct CaptureAnnotationData {
    let rawImage: NSImage       // screenshot without annotations
    let annotations: [Annotation]
    let editState: CaptureEditState?

    init(rawImage: NSImage, annotations: [Annotation], editState: CaptureEditState? = nil) {
        self.rawImage = rawImage
        self.annotations = annotations
        self.editState = editState
    }
}

private final class ScreenshotOverlayRootView: NSView {
    private let previewLayer = CALayer()
    let overlayView: OverlayView

    init(frame: NSRect, overlayView: OverlayView) {
        self.overlayView = overlayView
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        previewLayer.contentsGravity = .resize
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setScreenshotPreviewImage(_ cgImage: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        previewLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        previewLayer.contents = cgImage
        CATransaction.commit()
        overlayView.usesExternalScreenshotPreview = true
    }

    func clearScreenshotPreview() {
        previewLayer.contents = nil
        overlayView.usesExternalScreenshotPreview = false
    }
}

@MainActor
protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?)
    func overlayDidConfirmQuickCapture(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?)
    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?, initialFrame: NSRect?)
    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?)
    func overlayDidCopySelectableText(_ controller: OverlayWindowController, text: String)
    func overlayDidRequestSelectableTextPin(
        _ controller: OverlayWindowController, image: NSImage, initialFrame: NSRect?,
        result: StructuredOCRResult?)
    func overlayDidRequestScreenTranslation(
        _ controller: OverlayWindowController, image: NSImage,
        result: StructuredOCRResult, initialFrame: NSRect, requestToken: Int)
    func overlayDidRequestScreenTranslationPin(
        _ controller: OverlayWindowController, session: ScreenTranslationSession)
    func overlayDidRequestOpenScreenTranslation(
        _ controller: OverlayWindowController, session: ScreenTranslationSession)
    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?)
    func overlayDidRequestStartRecording(
        _ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopRecording(_ controller: OverlayWindowController)
    func overlayDidRequestScrollCapture(
        _ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController)
    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController)
    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController)
    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController)
    func overlayDidRequestPointerFocus(_ controller: OverlayWindowController)
    func overlayDidBeginSelection(_ controller: OverlayWindowController)
    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage?
    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController)
    func overlayDidRequestFullScreenAtMouse(_ controller: OverlayWindowController)
    func overlayDidCopyQuickCaptureToClipboard(_ controller: OverlayWindowController)
    func overlayDidBeginModalSave(_ controller: OverlayWindowController)
    func overlayDidEndModalSave(_ controller: OverlayWindowController, restoreOverlays: Bool)
}

extension OverlayWindowControllerDelegate {
    /// Most delegates only need the completed image. The app delegate opts in
    /// to the quick-capture distinction so ordinary Copy never creates a
    /// floating thumbnail.
    func overlayDidConfirmQuickCapture(
        _ controller: OverlayWindowController,
        capturedImage: NSImage?,
        annotationData: CaptureAnnotationData?
    ) {
        overlayDidConfirm(controller, capturedImage: capturedImage, annotationData: annotationData)
    }
}

extension OverlayWindowControllerDelegate {
    func overlayDidRequestFullScreenAtMouse(_ controller: OverlayWindowController) {}
    func overlayDidCopyQuickCaptureToClipboard(_ controller: OverlayWindowController) {}
    func overlayDidCopySelectableText(_ controller: OverlayWindowController, text: String) {}
    func overlayDidRequestSelectableTextPin(
        _ controller: OverlayWindowController, image: NSImage, initialFrame: NSRect?,
        result: StructuredOCRResult?) {}
    func overlayDidRequestScreenTranslation(
        _ controller: OverlayWindowController, image: NSImage,
        result: StructuredOCRResult, initialFrame: NSRect, requestToken: Int) {}
    func overlayDidRequestScreenTranslationPin(
        _ controller: OverlayWindowController, session: ScreenTranslationSession) {}
    func overlayDidRequestOpenScreenTranslation(
        _ controller: OverlayWindowController, session: ScreenTranslationSession) {}
    func overlayDidRequestPointerFocus(_ controller: OverlayWindowController) {}
    func overlayDidBeginModalSave(_ controller: OverlayWindowController) {}
    func overlayDidEndModalSave(_ controller: OverlayWindowController, restoreOverlays: Bool) {}
}

/// Manages one fullscreen overlay per screen.
/// Does NOT subclass NSWindowController to avoid AppKit retain-cycle issues.
@MainActor
class OverlayWindowController {

    weak var overlayDelegate: OverlayWindowControllerDelegate?
    var capturedWindowTitle: String?
    var timingMark: ((String) -> Void)? {
        didSet {
            overlayView?.timingMark = timingMark
        }
    }

    private var overlayView: OverlayView?
    private var rootView: ScreenshotOverlayRootView?
    private var overlayWindow: OverlayWindow?
    private var shareDelegate: SharePickerDelegate?
    private var shareDismissTime: Date = .distantPast
    private var screenTranslationRequestToken = 0
    private var captureSessionGeneration: UInt = 0
    private var operationGeneration: UInt = 0
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    /// The source overlay remains ordered only to anchor an NSSavePanel sheet
    /// on its capture display. Its pixels and input must stay hidden until the
    /// sheet completes, then cancellation can restore the same selection.
    private var saveSheetHostIsVisuallyHidden = false
    private func beginOperationGeneration() -> (capture: UInt, operation: UInt) {
        operationGeneration &+= 1
        return (captureSessionGeneration, operationGeneration)
    }

    private func isCurrentOperation(_ token: (capture: UInt, operation: UInt)) -> Bool {
        token.capture == captureSessionGeneration && token.operation == operationGeneration
    }
    var windowNumber: CGWindowID {
        overlayWindow.map { CGWindowID($0.windowNumber) } ?? CGWindowID.max
    }
    var presentationWindow: NSWindow? { overlayWindow }
    private(set) var screen: NSScreen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    var screenshotImage: NSImage? { overlayView?.screenshotImage }
    var selectionRect: NSRect { overlayView?.selectionRect ?? .zero }
    var remoteSelectionRect: NSRect { overlayView?.remoteSelectionRect ?? .zero }

    // Session recording overrides (from toolbar popover, nil = use UserDefaults default)
    var sessionRecordingFPS: Int? { overlayView?.sessionRecordingFPS }
    var sessionRecordingOnStop: String? { overlayView?.sessionRecordingOnStop }
    var sessionRecordingDelay: Int? { overlayView?.sessionRecordingDelay }
    var sessionHideRecordingHUD: Bool? { overlayView?.sessionHideRecordingHUD }
    /// Create an overlay pre-populated with a screenshot. Visible immediately on showOverlay().
    init(capture: ScreenCapture) {
        let screen = capture.screen
        self.screen = screen
        setupWindow(screen: screen)
        installScreenshot(capture.image)
    }

    /// Create an empty overlay. Stays transparent (showing the live desktop) until
    /// setScreenshot() is called with the captured image.
    init(screen: NSScreen) {
        self.screen = screen
        setupWindow(screen: screen)
    }

    private func setupWindow(screen: NSScreen) {
        // .nonactivatingPanel lets the overlay become key without activating the
        // Pinlume app — no NSApp.activate, no focus dance with the previous app.
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Idle/warmed panels are click-through by invariant. Mouse events are
        // enabled only when a real capture is presented (showOverlay/makeKey).
        // This guarantees that a stranded warm panel — e.g. if warmPanel()'s
        // deferred orderOut is delayed across a sleep/wake or display
        // reconfigure — can never swallow clicks (see issue #231).
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // No automatic appearance animation when the overlay is ordered front.
        // With the default behavior, AppKit auto-animates window appearance —
        // and under the system "Reduce Motion" setting that becomes a brief
        // scale/zoom-in, visible at the screenshot edges (issue #205). The
        // overlay must appear instantly so its screenshot lines up 1:1 with
        // the real screen.
        window.animationBehavior = .none

        let view = OverlayView()
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        window.onDedicatedToolbarShortcut = { [weak view] event in
            view?.handleDedicatedToolbarShortcut(event) ?? false
        }
        view.overlayDelegate = self
        view.timingMark = timingMark

        let rootView = ScreenshotOverlayRootView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            overlayView: view)
        view.externalScreenshotPreviewUpdater = { [weak rootView] cgImage in
            if let cgImage {
                rootView?.setScreenshotPreviewImage(cgImage)
            } else {
                rootView?.clearScreenshotPreview()
            }
        }

        window.contentView = rootView
        self.overlayWindow = window
        self.rootView = rootView
        self.overlayView = view
    }

    /// Install the screenshot into the overlay's backing layer. Once set, the
    /// window becomes opaque (dark dim) and the overlay can render annotations.
    private func installScreenshot(_ image: CGImage) {
        captureSessionGeneration &+= 1
        operationGeneration &+= 1
        overlayView?.beginCaptureSessionGeneration()
        let nsImage = NSImage(cgImage: image, size: screen.frame.size)
        overlayView?.captureSourceImage = nsImage
        overlayView?.screenshotImage = nsImage
        rootView?.setScreenshotPreviewImage(image)
        overlayWindow?.isOpaque = true
        overlayWindow?.backgroundColor = .black
    }

    /// Show the overlay. Multi-display capture orders every panel without
    /// repeatedly transferring key-window ownership, then makes only the panel
    /// beneath the pointer key. Single-window restore paths keep the default.
    func showOverlay(makeKey: Bool = true) {
        guard let window = overlayWindow else { return }
        timingMark?("showOverlay begin appActive=\(NSApp.isActive)")
        // A real capture is being presented — enable mouse interaction.
        // (Idle/warmed panels are click-through; see setupWindow.)
        saveSheetHostIsVisuallyHidden = false
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        rootView?.layoutSubtreeIfNeeded()
        timingMark?("after layoutSubtreeIfNeeded")
        overlayView?.displayIfNeeded()
        timingMark?("after displayIfNeeded")
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        timingMark?("after order front isVisible=\(window.isVisible) isKey=\(window.isKeyWindow)")
        if let view = overlayView {
            if makeKey {
                window.makeFirstResponder(view)
                refreshCursorAtPointerIfInside()
            }
            view.requestInitialWindowSnapQuery()
        }
        installEscapeMonitors()
        timingMark?("showOverlay end")
        // Cursor-rect invalidation does not reliably update a stationary pointer,
        // so the overlay under the pointer refreshes its cursor explicitly above.
    }

    /// Install the captured screenshot after the overlay has been prepared.
    /// The overlay was previously transparent; this is the moment it becomes
    /// screenshot-backed with the dim mask.
    func setScreenshot(_ image: CGImage) {
        installScreenshot(image)
        if let view = overlayView {
            if screen.frame.contains(NSEvent.mouseLocation) {
                overlayWindow?.invalidateCursorRects(for: view)
            }
            view.requestInitialWindowSnapQuery()
        }
    }

    func setWindowSnapSnapshot(_ snapshot: FrozenWindowSnapSnapshot) {
        overlayView?.windowSnapSnapshot = snapshot
        overlayView?.requestInitialWindowSnapQuery()
    }

    /// Window ordering and cursor ownership settle at different points in the
    /// AppKit runloop. The caller may invoke this both immediately and once
    /// after all screen overlays are ordered; only the overlay under the real
    /// pointer is allowed to change the global cursor.
    func refreshCursorAtPointerIfInside() {
        guard screen.frame.contains(NSEvent.mouseLocation),
              let window = overlayWindow,
              window.isVisible,
              let view = overlayView
        else { return }
        window.invalidateCursorRects(for: view)
        view.refreshCursorAtPointerIfInside()
    }

    private func installEscapeMonitors() {
        installLocalEscapeMonitor()
        installGlobalEscapeMonitor()
    }

    private func installLocalEscapeMonitor() {
        removeLocalEscapeMonitor()
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53,
                  let self,
                  let window = self.overlayWindow,
                  window.isVisible,
                  self.ownsEscapeFocus(window: window),
                  self.overlayView?.handleOverlayEscape() == true
            else { return event }
            return nil
        }
    }

    /// A nonactivating overlay can be visible while a system status item still
    /// owns keyboard focus. The global monitor complements the local monitor
    /// for that external-focus route; it needs no new prompt here and simply
    /// remains inactive on systems that have not granted event access.
    private func installGlobalEscapeMonitor() {
        removeGlobalEscapeMonitor()
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.ownsGlobalEscape() else { return }
                _ = self.overlayView?.handleOverlayEscape()
            }
        }
    }

    private func ownsEscapeFocus(window: NSWindow) -> Bool {
        if window.isKeyWindow { return true }
        var candidate = NSApp.keyWindow
        while let current = candidate {
            if current === window { return true }
            candidate = current.parent
        }
        return PopoverHelper.isVisible && screen.frame.contains(NSEvent.mouseLocation)
    }

    private func removeLocalEscapeMonitor() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
    }

    private func removeGlobalEscapeMonitor() {
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
    }

    private func ownsGlobalEscape() -> Bool {
        guard let window = overlayWindow, window.isVisible else { return false }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    func makeKey() {
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            overlayWindow?.makeFirstResponder(view)
            refreshCursorAtPointerIfInside()
        }
    }

    /// One-shot warmup: briefly order the (currently empty) panel front so
    /// WindowServer allocates its surface and composes one frame. We
    /// immediately order it out — but the CGSWindow stays alive and so does
    /// WindowServer's per-window composition cache. Next real `showOverlay()`
    /// hits the warm path. Pair with the overlay controller pool that keeps
    /// the panel alive across capture sessions.
    func warmPanel() {
        guard let panel = overlayWindow else { return }
        // Use a barely-visible alpha so WindowServer doesn't optimize the
        // window away as a transparent no-op. Restore after we order out.
        let savedAlpha = panel.alphaValue
        // Keep the warm panel click-through. Even if the deferred orderOut
        // below is stranded (e.g. across a sleep/wake or display reconfigure),
        // an invisible click-through window can't lock out input (issue #231).
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.001
        panel.orderFrontRegardless()
        rootView?.layoutSubtreeIfNeeded()
        overlayView?.displayIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = savedAlpha
            panel.ignoresMouseEvents = true
        }
    }

    func applySelection(_ rect: NSRect) {
        overlayView?.applySelection(rect)
    }

    func clearSelection() {
        overlayView?.clearSelection()
    }

    func triggerRedraw() {
        overlayView?.needsDisplay = true
    }

    func yieldTransientInteraction(modifierFlags: NSEvent.ModifierFlags) {
        overlayView?.yieldPixelInspectorToShortcut(modifierFlags: modifierFlags)
    }

    func setRemoteSelection(_ rect: NSRect, fullRect: NSRect = .zero) {
        overlayView?.remoteSelectionRect = rect
        overlayView?.remoteSelectionFullRect = fullRect.width >= 1 ? fullRect : rect
        if rect.width >= 1 && rect.height >= 1 {
            overlayView?.clearHoveredWindowSnap()
        }
        overlayView?.needsDisplay = true
    }

    /// Auto-select the full screen (as if user clicked without dragging).
    func applyFullScreenSelection() {
        overlayView?.applyFullScreenSelection()
    }

    /// Set flag so overlay enters recording mode after user makes a selection.
    func setAutoRecordMode() {
        overlayView?.autoEnterRecordingMode = true
    }

    /// Set flag so overlay triggers OCR immediately after user makes a selection.
    func setAutoOCRMode() {
        overlayView?.autoOCRMode = true
    }

    func setCaptureWorkflowMode(_ mode: CaptureWorkflowMode) {
        overlayView?.setCaptureWorkflowMode(mode)
    }

    /// Set flag so overlay quick-saves immediately after user makes a selection.
    func setAutoQuickSaveMode() {
        overlayView?.autoQuickSaveMode = true
    }

    /// Set flag so overlay triggers scroll capture immediately after user makes a selection.
    func setAutoScrollCaptureMode() {
        overlayView?.autoScrollCaptureMode = true
    }

    /// Set flag so overlay auto-confirms immediately after selection (no toolbars, no save).
    func setAutoConfirmMode() {
        overlayView?.autoConfirmMode = true
    }

    /// Enter recording mode — shows recording toolbar buttons in the normal toolbar.
    func enterRecordingMode() {
        overlayView?.isRecording = true
        overlayView?.rebuildToolbarLayout()
        overlayView?.needsDisplay = true
    }

    /// Auto-start recording immediately (used when timer + fullscreen record).
    func autoStartRecording() {
        overlayView?.overlayDelegate?.overlayViewDidRequestStartRecording(
            rect: overlayView?.selectionRect ?? .zero)
    }

    func setScrollCaptureState(isActive: Bool, stripCount: Int = 0, pixelSize: CGSize = .zero,
                               maxHeight: Int = 0) {
        overlayView?.scrollCaptureMaxHeight = maxHeight
        if isActive {
            // Make the overlay window fully transparent + pass-through so the
            // user sees AND interacts with the live app underneath. We must:
            //   1) Clear the rootView's previewLayer (which holds the frozen
            //      screenshot independent of OverlayView's drawing).
            //   2) Mark the window non-opaque + clear background so AppKit
            //      doesn't paint a solid backing behind the layer.
            //   3) ignoresMouseEvents = true so scroll/click events fall
            //      through to the app beneath (the HUD has its own panel).
            rootView?.clearScreenshotPreview()
            overlayWindow?.isOpaque = false
            overlayWindow?.backgroundColor = .clear
            overlayView?.startScrollCaptureMode()
        } else {
            overlayView?.stopScrollCaptureMode()
            // Restore the screenshot-backed opaque overlay so the next
            // action (selection adjustment, confirm, etc.) sees the screenshot.
            if let img = overlayView?.captureSourceImage,
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                rootView?.setScreenshotPreviewImage(cg)
                overlayWindow?.isOpaque = true
                overlayWindow?.backgroundColor = .black
            }
        }
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize = pixelSize
        overlayView?.needsDisplay = true
    }

    func updateScrollCaptureProgress(stripCount: Int, pixelSize: CGSize,
                                     autoScrolling: Bool = false) {
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize = pixelSize
        overlayView?.scrollCaptureAutoScrolling = autoScrolling
        overlayView?.updateScrollCaptureHUD()
        overlayView?.needsDisplay = true
    }

    /// End the current capture session. The window/view/panel are KEPT ALIVE
    /// and returned to a clean idle state, so the next session can reuse this
    /// same controller (and crucially, the same NSPanel CGSWindow — which is
    /// what makes the next capture instant, since WindowServer's per-window
    /// composition cache survives `orderOut`).
    func dismiss() {
        removeLocalEscapeMonitor()
        removeGlobalEscapeMonitor()
        saveSheetHostIsVisuallyHidden = false
        screenTranslationRequestToken &+= 1
        captureSessionGeneration &+= 1
        operationGeneration &+= 1
        overlayView?.invalidateAsyncOperations()
        saveSelectionIfNeeded()
        overlayView?.dismissPixelInspector()
        overlayView?.reset()
        timingMark = nil
        overlayView?.screenshotImage = nil
        overlayView?.captureSourceImage = nil
        rootView?.clearScreenshotPreview()
        // Restore the window's transparent state so the next session starts
        // with the same defaults as a fresh install.
        overlayWindow?.isOpaque = false
        overlayWindow?.backgroundColor = .clear
        overlayWindow?.alphaValue = 1
        // Return to the idle click-through invariant before ordering out.
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderOut(nil)
        NSCursor.arrow.set()
        // Note: overlayDelegate is intentionally NOT cleared here; the
        // controller-pool owner re-assigns it before each session.
        // overlayWindow/rootView/overlayView remain alive for the next session.
    }

    /// Fully tear down the controller. Used when the screen config changes
    /// (display added/removed), or app shutdown. After this the controller is
    /// dead and a new one must be constructed.
    func tearDown() {
        removeLocalEscapeMonitor()
        removeGlobalEscapeMonitor()
        overlayView?.dismissPixelInspector()
        overlayView?.reset()
        timingMark = nil
        overlayView?.overlayDelegate = nil
        overlayWindow?.contentView = nil
        rootView = nil
        overlayView = nil
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func saveSelectionIfNeeded() {
        guard let view = overlayView, view.state == .selected,
            view.selectionRect.width > 1, view.selectionRect.height > 1
        else { return }
        UserDefaults.standard.set(NSStringFromRect(view.selectionRect), forKey: "lastSelectionRect")
        UserDefaults.standard.set(
            NSStringFromRect(screen.frame), forKey: "lastSelectionScreenFrame")
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }

    private func captureRegion(ignoringWindowOcclusion: Bool = false) -> NSImage? {
        if ignoringWindowOcclusion,
           let view = overlayView,
           view.independentWindowCapturePending || view.independentWindowCaptureFailed {
            return nil
        }
        if ignoringWindowOcclusion,
           let view = overlayView,
           view.windowSnapOutputSource == .independentWindow,
           let windowImage = view.snappedWindowImage {
            return compositeAnnotationsOnSnappedWindow(
                windowImage,
                annotations: view.annotations,
                selectionRect: view.selectionRect)
        }
        return overlayDelegate?.overlayCrossScreenImage(self)
            ?? overlayView?.captureSelectedRegion()
    }

    private func shouldDeferOrRejectIndependentWindowOutput() -> Bool {
        guard let view = overlayView else { return false }
        if view.independentWindowCapturePending {
            view.showOverlayStatus(L("Preparing full window…"), autoHide: false)
            return true
        }
        if view.independentWindowCaptureFailed {
            view.showOverlayError(L("Unable to capture full window"))
            return true
        }
        return false
    }

    private func selectedGlobalFrame() -> NSRect? {
        guard let view = overlayView, view.selectionRect.width > 0, view.selectionRect.height > 0 else {
            return nil
        }
        let sel = view.selectionRect
        return NSRect(
            x: sel.origin.x + screen.frame.origin.x,
            y: sel.origin.y + screen.frame.origin.y,
            width: sel.width,
            height: sel.height
        )
    }

    /// Opt-in diagnostics only: records geometry and image dimensions while
    /// leaving the actual Pin placement path untouched.
    private func appendPinPlacementInputDiagnostic(image: NSImage, initialFrame: NSRect?) {
        guard DiagnosticLogStore.isEnabled, let view = overlayView else { return }

        let source = view.captureSourceImage ?? view.screenshotImage
        let sourcePixels = source.flatMap { source in
            source.cgImage(forProposedRect: nil, context: nil, hints: nil).map {
                "\($0.width)x\($0.height)"
            }
        } ?? "none"
        let outputPixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map {
            "\($0.width)x\($0.height)"
        } ?? "none"
        let requestedVisual = initialFrame?.debugDescription ?? "nil"
        let sourceScale = source.flatMap { source -> CGFloat? in
            guard source.size.width > 0,
                  let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return CGFloat(cgImage.width) / source.size.width
        } ?? (view.window?.backingScaleFactor ?? screen.backingScaleFactor)

        DiagnosticLogStore.append(
            "pin placement input rawSelection=\(view.selectionRect.debugDescription) "
                + "requestedVisual=\(requestedVisual) "
                + "screenFrame=\(screen.frame.debugDescription) "
                + "sourceScale=\(sourceScale) sourcePixels=\(sourcePixels) "
                + "outputSize=\(image.size.debugDescription) outputPixels=\(outputPixels)"
        )
    }

    /// Snapshot editable history data, using a pre-captured raw image.
    /// Returns nil if there are no movable annotations or post-processing edits.
    private func snapshotAnnotationData(rawImage: NSImage) -> CaptureAnnotationData? {
        guard let view = overlayView else { return nil }
        let annotations = view.annotations.filter { $0.isMovable }
        let editState = view.captureEditState()
        guard !annotations.isEmpty || editState.hasPostProcessing else { return nil }

        let sel = view.selectionRect
        let shifted = annotations.map { ann -> Annotation in
            let c = ann.clone()
            c.move(dx: -sel.origin.x, dy: -sel.origin.y)
            return c
        }
        return CaptureAnnotationData(
            rawImage: rawImage,
            annotations: shifted,
            editState: editState.hasPostProcessing ? editState : nil
        )
    }

    private func currentAnnotationDataForHistory(
        ignoringWindowOcclusion: Bool = false
    ) -> CaptureAnnotationData? {
        guard let view = overlayView else { return nil }
        let editState = view.captureEditState()
        let snapWindowImg = view.snappedWindowImage
        let hasAnnotations = view.annotations.contains(where: { $0.isMovable })
        guard hasAnnotations || editState.hasPostProcessing else { return nil }
        let rawImage: NSImage?
        if ignoringWindowOcclusion,
           view.windowSnapOutputSource == .independentWindow,
           let snapWindowImg {
            rawImage = snapWindowImg
        } else {
            rawImage = (editState.beautifyIsWindowSnap && snapWindowImg != nil)
                ? snapWindowImg : view.captureSelectedRegionRaw()
        }
        guard let rawImage else { return nil }
        return snapshotAnnotationData(rawImage: rawImage)
    }

    /// Composite annotations onto the snapped window image (preserving transparency).
    private func compositeAnnotationsOnSnappedWindow(_ windowImage: NSImage, annotations: [Annotation], selectionRect: NSRect) -> NSImage {
        guard !annotations.isEmpty else { return windowImage }
        let sel = selectionRect
        let size = windowImage.size
        let result = NSImage(size: size, flipped: false) { _ in
            windowImage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
            guard let ctx = NSGraphicsContext.current else { return true }
            // Translate so annotation coords (relative to selectionRect) map to image coords
            ctx.cgContext.translateBy(x: -sel.origin.x, y: -sel.origin.y)
            // Match the live order: censor, then the spotlight dim (union of
            // highlight rects, clipped to the selection), then shapes on top.
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: ctx)
            }
            Annotation.drawHighlightDim(for: annotations, in: sel)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: ctx)
            }
            return true
        }
        return result
    }

    private func applyBeautifyIfNeeded(_ image: NSImage?) -> NSImage? {
        guard let image = image, let view = overlayView else { return image }
        var result = image
        // Apply image effects first (non-destructive CIFilter adjustments)
        if view.effectsActive {
            result = ImageEffects.apply(to: result, config: view.effectsConfig)
        }
        // Apply beautify second (gradient background wrapping)
        if view.beautifyEnabled {
            result = BeautifyRenderer.render(image: result, config: view.beautifyConfig)
        }
        return result
    }

    private func copyImageToClipboard(_ image: NSImage) {
        ImageEncoder.copyToClipboard(image)
    }

}

// MARK: - OverlayViewDelegate

extension OverlayWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {
        // No-op: window is already key (.nonactivatingPanel + makeKeyAndOrderFront).
    }

    func overlayViewSelectionDidChange(_ rect: NSRect) {
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidChangeSelection(self, globalRect: globalRect)
    }

    func overlayViewDidCancel() {
        dismiss()
        overlayDelegate?.overlayDidCancel(self)
    }

    func overlayViewDidConfirm() {
        // Snapshot post-processing config before dismissing (view will be torn down)
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage

        // Capture the composited image (screenshot + annotations baked in).
        // This is a single render — no double capture.
        guard let compositedImage = captureRegion(ignoringWindowOcclusion: true) else {
            if shouldDeferOrRejectIndependentWindowOutput() { return }
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        // Snapshot annotations + selection rect before dismiss (view will be torn down)
        let snapshotAnnotations = overlayView?.annotations ?? []
        let snapshotSelRect = overlayView?.selectionRect ?? .zero

        // Snapshot annotation data using the raw screenshot (without annotations).
        // For window snaps, use the independently captured window image (transparent corners)
        // so the editor shows clean corners when re-editing.
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations || hasEffects || hasBeautify {
            let usesIndependentWindowImage = overlayView?.windowSnapOutputSource == .independentWindow
            let rawImage: NSImage? = usesIndependentWindowImage && snapWindowImg != nil
                ? snapWindowImg : (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                    ? snapWindowImg : overlayView?.captureSelectedRegionRaw()
            if let raw = rawImage {
                annotationData = snapshotAnnotationData(rawImage: raw)
            } else {
                annotationData = nil
            }
        } else {
            annotationData = nil
        }

        // Dismiss immediately — user is free to continue working
        playCopySound()
        dismiss()

        // Apply post-processing if needed
        var finalImage = compositedImage
        if hasEffects {
            finalImage = ImageEffects.apply(to: finalImage, config: effectsCfg)
        }
        if hasBeautify {
            // For snapped windows, use the independently captured window image (transparent corners)
            // with annotations composited on top (using pre-dismiss snapshot)
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnnotations, selectionRect: snapshotSelRect)
                : finalImage
            finalImage = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        // Copy button / Cmd+C always copies to clipboard
        ImageEncoder.copyToClipboard(finalImage)

        overlayDelegate?.overlayDidConfirm(self, capturedImage: finalImage, annotationData: annotationData)
    }

    func overlayViewDidRequestClipboardCopy() {
        overlayView?.commitTextFieldIfNeeded()
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage
        let snapshotAnnotations = overlayView?.annotations ?? []
        let snapshotSelRect = overlayView?.selectionRect ?? .zero

        guard var image = captureRegion(ignoringWindowOcclusion: true) else {
            if shouldDeferOrRejectIndependentWindowOutput() { return }
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        if hasEffects {
            image = ImageEffects.apply(to: image, config: effectsCfg)
        }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(
                    snapWindowImg!,
                    annotations: snapshotAnnotations,
                    selectionRect: snapshotSelRect
                )
                : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        ImageEncoder.copyToClipboard(image)
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidCancel(self)
    }

    func overlayViewDidRequestPin() {
        overlayView?.commitTextFieldIfNeeded()
        guard var image = captureRegion(ignoringWindowOcclusion: true) else {
            _ = shouldDeferOrRejectIndependentWindowOutput()
            return
        }
        let annotationData = currentAnnotationDataForHistory(ignoringWindowOcclusion: true)
        let initialFrame = selectedGlobalFrame()
        appendPinPlacementInputDiagnostic(image: image, initialFrame: initialFrame)
        image = applyBeautifyIfNeeded(image) ?? image
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidRequestPin(self, image: image, annotationData: annotationData, initialFrame: initialFrame)
    }

    func overlayViewDidRequestOCR() {
        guard let image = captureRegion() else { return }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let token = beginOperationGeneration()
        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                guard let self = self else { return }
                let capturedImage = image  // capture before dismiss
                DispatchQueue.main.async {
                    guard self.isCurrentOperation(token) else { return }
                    self.playCopySound()
                    self.dismiss()
                    self.overlayDelegate?.overlayDidRequestOCR(self, result: result, image: capturedImage)
                }
            }
        }
    }

    func overlayViewDidRequestRecognizeSelectableText(token: Int) {
        guard let image = captureRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            overlayView?.failSelectableOCRRecognition(token: token)
            return
        }
        let operationToken = beginOperationGeneration()
        VisionOCR.performStructuredTextRecognition(cgImage: cgImage) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentOperation(operationToken) else { return }
            switch result {
            case .success(let structuredResult):
                self.overlayView?.finishSelectableOCRRecognition(token: token, result: structuredResult)
            case .failure:
                self.overlayView?.failSelectableOCRRecognition(token: token)
            }
        }
    }

    func overlayViewDidRequestCopyRecognizedText(text: String) {
        guard !text.isEmpty else { return }
        overlayDelegate?.overlayDidCopySelectableText(self, text: text)
    }

    func overlayViewDidRequestPinSelectableText(result: StructuredOCRResult?) {
        guard let image = captureRegion() else { return }
        let initialFrame = selectedGlobalFrame()
        dismiss()
        overlayDelegate?.overlayDidRequestSelectableTextPin(
            self, image: image, initialFrame: initialFrame, result: result)
    }

    func overlayViewDidRequestScreenTranslation() {
        screenTranslationRequestToken &+= 1
        let token = screenTranslationRequestToken
        let operationToken = beginOperationGeneration()
        guard let frame = selectedGlobalFrame(), screen.frame.contains(frame) else {
            overlayView?.failScreenTranslation(L("Screen translation must stay on one display")); return
        }
        guard let image = captureRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            overlayView?.failScreenTranslation(L("Unable to capture selection")); return
        }
        VisionOCR.performStructuredTextRecognition(
            cgImage: cgImage,
            mode: .screenTranslation) { [weak self] result in
            guard let self, token == self.screenTranslationRequestToken,
                  self.isCurrentOperation(operationToken) else { return }
            switch result {
            case .success(let structured) where !structured.blocks.isEmpty:
                self.overlayDelegate?.overlayDidRequestScreenTranslation(
                    self, image: image, result: structured, initialFrame: frame,
                    requestToken: token)
            default:
                self.overlayView?.failScreenTranslation(L("No text found"))
            }
        }
    }

    func overlayViewDidInvalidateScreenTranslation() {
        screenTranslationRequestToken &+= 1
        operationGeneration &+= 1
    }

    func finishScreenTranslation(requestToken: Int, session: ScreenTranslationSession) {
        guard requestToken == screenTranslationRequestToken else { return }
        overlayView?.finishScreenTranslation(session: session)
    }

    func overlayViewDidRequestPinScreenTranslation(_ session: ScreenTranslationSession) {
        overlayDelegate?.overlayDidRequestScreenTranslationPin(self, session: session)
    }

    func overlayViewDidRequestOpenScreenTranslation(_ session: ScreenTranslationSession) {
        overlayDelegate?.overlayDidRequestOpenScreenTranslation(self, session: session)
    }

    func overlayViewDidRequestUpload() {
        #if !OFFLINE
        guard var image = captureRegion() else { return }
        let annotationData = currentAnnotationDataForHistory()
        image = applyBeautifyIfNeeded(image) ?? image
        // AppDelegate owns an explicit upload session. It hides this Overlay
        // before confirmation, restores it on cancellation/failure, and only
        // lets this session's own completion dismiss it.
        overlayDelegate?.overlayDidRequestUpload(self, image: image, annotationData: annotationData)
        #endif
    }

    func overlayViewDidRequestShare(anchorView: NSView?) {
        // Prevent re-entry: if a share session is active or was just dismissed, ignore
        if shareDelegate != nil { return }
        if Date().timeIntervalSince(shareDismissTime) < 0.5 {
            return
        }

        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        let annotationData = currentAnnotationDataForHistory()
        guard let imageData = ImageEncoder.encode(image) else { return }
        let tempURL = TmpScratchDirectory.makeURL(
            filename: FilenameFormatter.defaultImageFilename(windowTitle: capturedWindowTitle))
        try? imageData.write(to: tempURL)

        // Get the screen position of the share button
        let screenRect: NSRect
        if let anchor = anchorView, let win = anchor.window {
            let viewRect = anchor.convert(anchor.bounds, to: nil)
            screenRect = win.convertToScreen(viewRect)
        } else {
            let mid = NSScreen.main?.frame ?? NSRect(x: 400, y: 400, width: 100, height: 100)
            screenRect = NSRect(x: mid.midX - 20, y: mid.midY - 20, width: 40, height: 40)
        }

        // Temporarily lower the overlay so the system share picker popover appears on top.
        // NSSharingServicePicker creates its own window at a standard level that we can't control.
        let savedLevel = overlayWindow?.level ?? NSWindow.Level(257)
        overlayWindow?.level = .floating

        let picker = NSSharingServicePicker(items: [tempURL])
        let delegate = SharePickerDelegate(
            onPick: { [weak self] in
                guard let self = self else { return }
                self.overlayWindow?.level = savedLevel
                self.shareDelegate = nil
                self.playCopySound()
                let img = image
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: img, annotationData: annotationData)
            },
            onDismiss: { [weak self] in
                self?.overlayWindow?.level = savedLevel
                self?.shareDelegate = nil
                self?.shareDismissTime = Date()
            }
        )
        shareDelegate = delegate
        picker.delegate = delegate

        // Show anchored to the button in the overlay view
        if let anchor = anchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let view = overlayView {
            let center = NSRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
            picker.show(relativeTo: center, of: view, preferredEdge: .minY)
        }
    }

    func overlayViewDidRequestEnterRecordingMode() {
        enterRecordingMode()
    }

    func overlayViewDidRequestStartRecording(rect: NSRect) {
        // Convert overlay-local rect to screen coordinates
        let screenRect = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        overlayDelegate?.overlayDidRequestStartRecording(self, rect: screenRect, screen: screen)
    }

    /// Detach the webcam setup preview so it can be reused during recording.
    func detachWebcamPreview() -> WebcamOverlay? {
        overlayView?.detachWebcamSetupPreview()
    }

    func overlayViewDidRequestStopRecording() {
        overlayDelegate?.overlayDidRequestStopRecording(self)
    }

    func overlayViewDidRequestScrollCapture(rect: NSRect) {
        let screenRect = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        overlayDelegate?.overlayDidRequestScrollCapture(self, rect: screenRect, screen: screen)
    }

    func overlayViewDidRequestStopScrollCapture() {
        overlayDelegate?.overlayDidRequestStopScrollCapture(self)
    }

    func overlayViewDidRequestToggleAutoScroll() {
        overlayDelegate?.overlayDidRequestToggleAutoScroll(self)
    }

    func overlayViewDidRequestAccessibilityPermission() {
        overlayDelegate?.overlayDidRequestAccessibilityPermission(self)
    }

    func overlayViewDidRequestInputMonitoringPermission() {
        overlayDelegate?.overlayDidRequestInputMonitoringPermission(self)
    }

    func overlayViewDidBeginSelection() {
        overlayDelegate?.overlayDidBeginSelection(self)
    }

    func overlayViewDidRequestPointerFocus() {
        overlayDelegate?.overlayDidRequestPointerFocus(self)
    }

    func overlayViewDidChangeWindowSnapState() {
        overlayDelegate?.overlayDidChangeWindowSnapState(self)
    }

    func overlayViewDidRequestFullScreenAtMouse() {
        overlayDelegate?.overlayDidRequestFullScreenAtMouse(self)
    }

    func overlayViewDidRequestAddCapture() {}  // editor-only

    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {
        // Convert local rect to global screen coords and forward to delegate
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidRemoteResizeSelection(self, globalRect: globalRect)
    }

    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidFinishRemoteResize(self, globalRect: globalRect)
    }

    func overlayViewDidRequestDetach() {
        // Keep older custom shortcuts usable without retaining a second static
        // image workflow: the former editor action now pins the selection.
        overlayViewDidRequestPin()
    }

    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {
        guard var image = captureRegion() else { return }
        let token = beginOperationGeneration()
        image = applyBeautifyIfNeeded(image) ?? image

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                guard let result = request.results?.first else {
                    throw NSError(domain: "Pinlume", code: 1)
                }

                let maskPixelBuffer = try result.generateScaledMaskForImage(
                    forInstances: result.allInstances, from: handler)

                let originalCIImage = CIImage(cgImage: cgImage)
                let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)

                // Blend original with mask
                guard let filter = CIFilter(name: "CIBlendWithMask") else {
                    throw NSError(domain: "Pinlume", code: 2)
                }
                filter.setValue(originalCIImage, forKey: kCIInputImageKey)
                filter.setValue(maskCIImage, forKey: kCIInputMaskImageKey)
                filter.setValue(
                    CIImage(color: .clear).cropped(to: originalCIImage.extent),
                    forKey: kCIInputBackgroundImageKey)

                guard let outputCIImage = filter.outputImage else {
                    throw NSError(domain: "Pinlume", code: 3)
                }

                let context = CIContext()
                guard
                    let finalCGImage = context.createCGImage(
                        outputCIImage, from: outputCIImage.extent)
                else { throw NSError(domain: "Pinlume", code: 4) }

                let finalNSImage = NSImage(cgImage: finalCGImage, size: image.size)

                DispatchQueue.main.async {
                    guard self.isCurrentOperation(token) else { return }
                    let outputAction = CaptureOutputAction.current()
                    if outputAction.copiesToClipboard {
                        self.copyImageToClipboard(finalNSImage)
                    }
                    self.playCopySound()
                    self.dismiss()
                    if outputAction.pinsToScreen {
                        self.overlayDelegate?.overlayDidRequestPin(
                            self, image: finalNSImage, annotationData: nil, initialFrame: nil)
                    } else {
                        self.overlayDelegate?.overlayDidConfirm(
                            self, capturedImage: finalNSImage, annotationData: nil)
                    }
                    if outputAction.savesToFolder {
                        ImageSaveService.saveToConfiguredFolder(
                            finalNSImage, windowTitle: self.capturedWindowTitle)
                    }
                }
            } catch {
                #if DEBUG
                    print("Vision background removal error: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    guard self.isCurrentOperation(token) else { return }
                    self.overlayView?.showOverlayError(
                        "Background removal failed — no clear subject found.")
                }
            }
        }
    }

    func overlayViewDidRequestQuickSave() {
        // Snapshot post-processing config before dismissing
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage

        guard let compositedImage = captureRegion() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        // Snapshot annotations + selection rect before dismiss
        let snapshotAnns = overlayView?.annotations ?? []
        let snapshotSel = overlayView?.selectionRect ?? .zero
        // PinWindowController owns a global AppKit visual frame. Preserve the
        // source selection before this Overlay is dismissed so Quick Capture
        // (and Return, which shares this path) stays in place instead of
        // falling back to a centred Pin.
        let initialFrame = selectedGlobalFrame()

        // Snapshot annotation data — use snapped window image for clean corners
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations || hasEffects || hasBeautify {
            let rawImage: NSImage? = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? snapWindowImg : overlayView?.captureSelectedRegionRaw()
            if let raw = rawImage {
                annotationData = snapshotAnnotationData(rawImage: raw)
            } else {
                annotationData = nil
            }
        } else {
            annotationData = nil
        }

        dismiss()

        // Apply post-processing
        var image = compositedImage
        if hasEffects { image = ImageEffects.apply(to: image, config: effectsCfg) }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnns, selectionRect: snapshotSel)
                : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        let outputAction = CaptureOutputAction.current()

        if outputAction.copiesToClipboard {
            ImageEncoder.copyToClipboard(image)
            overlayDelegate?.overlayDidCopyQuickCaptureToClipboard(self)
        }
        playCopySound()

        if outputAction.savesToFolder {
            ImageSaveService.saveToConfiguredFolder(image, windowTitle: capturedWindowTitle)
        }
        if outputAction.pinsToScreen {
            appendPinPlacementInputDiagnostic(image: image, initialFrame: initialFrame)
            overlayDelegate?.overlayDidRequestPin(
                self, image: image, annotationData: annotationData, initialFrame: initialFrame)
        } else {
            overlayDelegate?.overlayDidConfirmQuickCapture(
                self, capturedImage: image, annotationData: annotationData)
        }
    }

    func overlayViewDidRequestFileSave() {
        overlayViewDidRequestSaveAs()
    }

    func overlayViewDidRequestSave() {
        overlayViewDidRequestSaveAs()
    }

    func overlayViewDidRequestSaveAs() {
        overlayView?.commitTextFieldIfNeeded()
        os_log("overlay save requested", log: overlaySaveLog, type: .info)
        overlayDelegate?.overlayDidBeginModalSave(self)
        let panelPlan = OverlaySavePresentationGeometry.panelPlan()
        applySavePresentationState(
            OverlaySavePresentationGeometry.stateAfterOpeningSavePanel(),
            keepsSavePanelHostVisible: panelPlan.keepsOverlayWindowVisible
        )
        ImageSaveService.showSavePanel(
            imageProvider: { [weak self] in
                let start = CFAbsoluteTimeGetCurrent()
                let image = self?.captureImageForSave()
                os_log(
                    "overlay image provider elapsed=%.3f success=%{public}@",
                    log: overlaySaveLog,
                    type: .info,
                    CFAbsoluteTimeGetCurrent() - start,
                    image == nil ? "false" : "true"
                )
                return image
            },
            windowTitle: capturedWindowTitle,
            panelLevel: NSWindow.Level(258),
            sheetWindow: panelPlan.usesOverlayWindowAsSheetHost ? overlayWindow : nil,
            preferredScreen: screen,
            activateApp: true
        ) { [weak self] success in
            guard let self = self else { return }
            switch OverlaySavePresentationGeometry.stateAfterSavePanelResponse(success: success) {
            case .dismissed:
                self.overlayDelegate?.overlayDidEndModalSave(self, restoreOverlays: false)
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: nil, annotationData: nil)
            case .visible:
                self.overlayDelegate?.overlayDidEndModalSave(self, restoreOverlays: true)
                self.resumeOverlayAfterModalSave()
            case .hiddenForSavePanel:
                break
            }
        }
    }

    private func applySavePresentationState(
        _ state: OverlaySavePresentationState,
        keepsSavePanelHostVisible: Bool = false
    ) {
        switch state {
        case .visible:
            resumeOverlayAfterModalSave()
        case .hiddenForSavePanel:
            suspendForModalSave(keepingWindowVisible: keepsSavePanelHostVisible)
        case .dismissed:
            dismiss()
        }
    }

    func suspendForModalSave(keepingWindowVisible: Bool = false) {
        overlayWindow?.ignoresMouseEvents = true
        if keepingWindowVisible {
            // AppKit chooses a sheet's display from its parent window. Keep
            // this window ordered for that ownership, but hide the previous
            // capture/selection completely just as standalone save did.
            saveSheetHostIsVisuallyHidden = true
            removeLocalEscapeMonitor()
            removeGlobalEscapeMonitor()
            overlayWindow?.alphaValue = 0
            overlayWindow?.orderBack(nil)
        } else {
            overlayWindow?.orderOut(nil)
        }
    }

    func showUploadError(_ message: String) {
        overlayView?.showOverlayError(message)
    }

    func restoreAfterModalSave() {
        let shouldRestoreEscapeMonitors = saveSheetHostIsVisuallyHidden
        saveSheetHostIsVisuallyHidden = false
        overlayWindow?.alphaValue = 1
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            overlayWindow?.makeFirstResponder(view)
        }
        if shouldRestoreEscapeMonitors {
            installEscapeMonitors()
        }
    }

    private func resumeOverlayAfterModalSave() {
        restoreAfterModalSave()
    }

    private func captureImageForSave() -> NSImage? {
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage
        let snapshotAnns = overlayView?.annotations ?? []
        let snapshotSel = overlayView?.selectionRect ?? .zero

        guard var image = captureRegion() else { return nil }
        if hasEffects {
            image = ImageEffects.apply(to: image, config: effectsCfg)
        }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnns, selectionRect: snapshotSel)
                : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }
        return image
    }
}

// MARK: - Custom Window subclass

class OverlayWindow: NSPanel {
    /// Dedicated OCR/translation shortcuts must still work while a selectable
    /// text layer owns first responder. Returning true consumes the event.
    var onDedicatedToolbarShortcut: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onDedicatedToolbarShortcut?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// Retained delegate for NSSharingServicePicker — dismisses overlay only when user picks a service.
private class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let onPick: () -> Void
    let onDismiss: () -> Void
    init(onPick: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onPick = onPick
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        if service != nil {
            onPick()
        } else {
            onDismiss()
        }
    }
}
