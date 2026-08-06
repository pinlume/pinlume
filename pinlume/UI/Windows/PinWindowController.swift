import Cocoa
import os.log

/// Keeps the compact-Pin display rule independent from the legacy whole-image
/// flag. New installs default to the requested local crop, while an explicit
/// old choice remains visually unchanged until the user changes the setting.
enum PinCompactDisplayPreference {
    private static let userDefaultsKey = "pinCompactShowsPartialImage"
    private static let legacyUserDefaultsKey = "pinCompactShowsThumbnail"

    static var showsPartialImage: Bool {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: userDefaultsKey) as? Bool {
            return stored
        }
        if let legacyValue = defaults.object(forKey: legacyUserDefaultsKey) as? Bool {
            return !legacyValue
        }
        return true
    }

    static func setShowsPartialImage(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }
}
import UniformTypeIdentifiers

private let pinZoomLog = OSLog(subsystem: AppIdentity.bundleIdentifier, category: "pin-zoom")
private let pinToolbarLog = OSLog(subsystem: AppIdentity.bundleIdentifier, category: "pin-toolbar")

@MainActor
protocol PinWindowControllerDelegate: AnyObject {
    func pinWindowDidSelect(_ controller: PinWindowController)
    func pinWindowDidClose(_ controller: PinWindowController)
}

/// Ordinary image Pins and vector-only transparent annotation Pins share one
/// window/event implementation, while retaining explicit content semantics.
enum PinContentKind {
    case image
    case transparentAnnotations([Annotation])
}

@MainActor
class PinWindowController {

    weak var delegate: PinWindowControllerDelegate?
    /// Transparent Pins use a dedicated re-edit session. The preview itself
    /// only asks its owner to open that session.
    var onRequestTransparentAnnotationEdit: (() -> Void)?

    private var window: NSPanel?
    private var pinView: PinView?
    private var image: NSImage
    private let contentKind: PinContentKind
    private var baseVisualSize: NSSize
    private var visualFrame: NSRect
    private var normalVisualFrame: NSRect?
    private var toolbarPanel: NSPanel?
    private var toolbarBottomStrip: ToolbarStripView?
    private var toolbarMoreStrip: ToolbarStripView?
    private var toolbarOptionsRow: ToolOptionsRowView?
    private var toolbarTooltipView: PinToolbarTooltipView?
    private weak var toolbarTooltipAnchor: ToolbarButtonView?
    private var toolbarTooltipText: String?
    private var isPinMoreToolsExpanded = false
    private var currentToolbarTool: AnnotationTool = .select
    private var pinOpacity: CGFloat = 1
    private var discreteWheelAccumulator: CGFloat = 0
    private var zoomSession: PinZoomSession?
    private var activeZoomAnchorMode: PinZoomAnchorMode?
    private var textContent: String?
    private var translationSession: ScreenTranslationSession?
    private var isDedicatedOCRPin = false
    private var recognizedTextContent: String?
    private var recognizedTextBlocks: [RecognizedTextBlock] = []
    private var isTemporarilyHidden = false
    private var transparentPreviewRevealWorkItem: DispatchWorkItem?
    private var transparentPreviewHideWorkItem: DispatchWorkItem?
    private let selectableTextOverlay = SelectableTextOverlayView(frame: .zero)
    private var textSelectionSession = PinTextSelectionSession()
    private var didLogInitialPlacement = false
    private struct ExternalMeasureDrag {
        var lastScreenPoint: NSPoint
        var hasEnteredImage = false
    }
    private var externalMeasureDrag: ExternalMeasureDrag?

    private static let compactSize = PinGeometry.defaultCompactSize
    private static let shadowOutset = PinGeometry.defaultShadowOutset
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 5.0
    private static let snapDistance: CGFloat = 8
    private static let transparentPreviewRevealDelay: TimeInterval = 0.12
    private static let transparentPreviewHideDelay: TimeInterval = 0.3
    static let pinShadowToolInPrimaryKey = "pinShadowToolInPrimary"
    static let textCopyToolInPrimaryKey = "textCopyToolInPrimary"
    static let selectTextToolInPrimaryKey = "selectTextToolInPrimary"
    private var preservesTextSelectionDuringPinDrag = false

    private var isTransparentAnnotationPin: Bool {
        if case .transparentAnnotations = contentKind { return true }
        return false
    }

    var transparentVisualFrame: NSRect { visualFrame }

    init(
        image: NSImage, initialFrame: NSRect? = nil, textContent: String? = nil,
        translationSession: ScreenTranslationSession? = nil,
        contentKind: PinContentKind = .image
    ) {
        self.image = image
        self.contentKind = contentKind
        self.translationSession = translationSession
        self.textContent = translationSession.map {
            $0.displayMode == .original ? $0.originalText : $0.translatedText
        } ?? textContent

        let screen = initialFrame.flatMap { frame in
            NSScreen.screens.first {
                $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
            }
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        let initialVisualFrame: NSRect
        if let initialFrame, initialFrame.width > 0, initialFrame.height > 0 {
            initialVisualFrame = initialFrame
        } else {
            let size = Self.defaultVisualSize(for: image, on: screen)
            let visualSize = NSSize(width: max(1, size.width), height: max(1, size.height))
            let origin = NSPoint(
                x: screenFrame.midX - visualSize.width / 2,
                y: screenFrame.midY - visualSize.height / 2
            )
            initialVisualFrame = NSRect(origin: origin, size: visualSize)
        }
        let pixelAlignedInitialVisualFrame = Self.pixelAlignedVisualFrame(initialVisualFrame, on: screen)
        self.baseVisualSize = pixelAlignedInitialVisualFrame.size
        self.visualFrame = pixelAlignedInitialVisualFrame
        self.normalVisualFrame = pixelAlignedInitialVisualFrame

        let panel = PinPanel(
            contentRect: Self.windowFrame(forVisualFrame: pixelAlignedInitialVisualFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pinlume Pin"
        // Stay above normal apps, Dock, and the menu bar surface, but below
        // pop-up menus/dropdowns so system and app menus remain usable.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.onToolbarShortcut = { [weak self] event in
            self?.handlePinToolbarShortcut(event) ?? false
        }

        let view = PinView(
            image: image,
            shadowOutset: Self.shadowOutset,
            canvasSize: self.baseVisualSize,
            isTransparentAnnotationContent: isTransparentAnnotationPin
        )
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        view.autoresizingMask = [.width, .height]
        view.onSelect = { [weak self] in
            self?.select()
        }
        view.onClose = { [weak self] in
            self?.close()
        }
        view.onToggleCompact = { [weak self] viewPoint in
            self?.toggleCompact(around: viewPoint)
        }
        view.onZoom = { [weak self] factor, screenPoint, viewPoint, isGesture, phase in
            self?.zoom(
                by: factor,
                screenPoint: screenPoint,
                viewPoint: viewPoint,
                isGesture: isGesture,
                phase: phase,
                source: "view"
            )
        }
        view.onZoomPhase = { [weak self] screenPoint, phase in
            self?.updateZoomGesturePhase(at: screenPoint, phase: phase)
        }
        view.onOpacityChange = { [weak self] delta in
            self?.adjustPinOpacity(by: delta)
        }
        view.onDrag = { [weak self] viewPoint, event in
            self?.drag(from: viewPoint, event: event)
        }
        view.onNudge = { [weak self] delta in
            guard let self else { return }
            var moved = self.visualFrame
            moved.origin.x += delta.x
            moved.origin.y += delta.y
            self.applyVisualFrame(moved, updateNormal: self.pinView?.isCompactMode != true)
        }
        view.onShowToolbar = { [weak self] screenPoint in
            self?.toggleToolbar(near: screenPoint)
        }
        view.onPreviewHover = { [weak self] screenPoint in
            self?.scheduleTransparentPreviewToolbarReveal(near: screenPoint)
        }
        view.onCanvasChanged = { [weak self] in
            self?.exitTextSelectionMode(rebuildToolbar: false)
            self?.rebuildPinToolbar()
        }
        view.onConfirmAnnotation = { [weak self] in
            self?.confirmPinAnnotationEditing()
        }
        view.onToolbarShortcut = { [weak self] action in
            self?.handlePinToolbarShortcut(action)
        }
        view.onSave = { [weak self] in
            self?.savePin()
        }
        view.onExitTextSelection = { [weak self] in
            self?.exitTextSelectionMode()
        }
        view.attachSelectableTextOverlay(selectableTextOverlay)
        if case .transparentAnnotations(let annotations) = contentKind {
            view.installTransparentAnnotations(annotations)
            view.setShadowHidden(true)
        }

        panel.contentView = view
        self.window = panel
        self.pinView = view
        updatePinViewDisplayFrame()
        PinEventRouter.shared.register(self)
    }

    convenience init(transparentAnnotation payload: TransparentAnnotationPinPayload, anchorOrigin: NSPoint? = nil) {
        let retainedAnnotations = TransparentAnnotationGeometry.retainedAnnotations(
            payload.annotations,
            cropRect: payload.cropRect
        )
        let contentBounds = TransparentAnnotationGeometry.pinContentBounds(for: payload)
        precondition(!contentBounds.isEmpty)
        let translatedAnnotations = TransparentAnnotationGeometry.translateForPin(
            retainedAnnotations,
            contentBounds: contentBounds,
            padding: 0
        )
        let naturalOrigin = anchorOrigin ?? NSPoint(
            x: payload.screen.frame.minX + contentBounds.minX,
            y: payload.screen.frame.minY + contentBounds.minY
        )
        let naturalVisualFrame = NSRect(
            x: naturalOrigin.x,
            y: naturalOrigin.y,
            width: contentBounds.width,
            height: contentBounds.height
        )
        let visualFrame = PinGeometry.pixelAlignedVisualFrame(
            naturalVisualFrame,
            scale: max(payload.screen.backingScaleFactor, 1)
        )
        self.init(
            image: Self.transparentCanvasImage(size: visualFrame.size),
            initialFrame: visualFrame,
            contentKind: .transparentAnnotations(translatedAnnotations)
        )
    }

    private static func transparentCanvasImage(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            return true
        }
    }

    func setSelected(_ selected: Bool) {
        pinView?.isSelected = selected
        if !selected {
            pinView?.dismissPixelInspector()
            pinView?.clearTextSelectionHighlights()
            if isTransparentAnnotationPin {
                hideToolbar(reason: .explicitAction)
            }
        }
        if selected {
            window?.orderFrontRegardless()
            window?.makeKey()
            if let pinView {
                window?.makeFirstResponder(pinView)
            }
        }
    }

    func yieldTransientInteraction(modifierFlags: NSEvent.ModifierFlags) {
        pinView?.yieldPixelInspectorToShortcut(modifierFlags: modifierFlags)
    }

    func refreshAfterSettingsProfileApply() {
        if currentToolbarTool != .select,
           !ToolbarToolPreferences.isToolEnabled(currentToolbarTool) {
            currentToolbarTool = .select
            pinView?.setAnnotationTool(.select)
            pinView?.clearAnnotationSelection()
        }
        rebuildPinToolbar()
        refreshPinAnnotationCursor()
    }

    func applyPersistedState(shadowHidden: Bool, opacity: CGFloat, normalVisualFrame: NSRect?, compactCenter: NSPoint?, compactActualCenter: NSPoint?, isCompact: Bool, persistedVisualFrame: NSRect? = nil) {
        pinView?.setShadowHidden(shadowHidden)
        pinOpacity = min(1, max(0.10, opacity))
        self.normalVisualFrame = normalVisualFrame ?? visualFrame
        pinView?.compactCenter = compactCenter ?? NSPoint(x: 0.5, y: 0.5)
        pinView?.compactActualCenter = compactActualCenter ?? NSPoint(x: 0.5, y: 0.5)
        pinView?.isCompactMode = isCompact
        applyWindowOpacity()
        if isCompact, let persistedVisualFrame {
            applyVisualFrame(persistedVisualFrame, updateNormal: false)
        }
    }

    func persistenceRecord() -> PersistedPinRecord? {
        guard let pinView,
              let imageData = ImageEncoder.encodePNGPreservingSourcePixels(pinView.outputImage())
        else { return nil }
        let persistedTranslation = translationSession.flatMap { session -> PersistedTranslationPinState? in
            guard let originalPNG = ImageEncoder.encodePNGPreservingSourcePixels(session.originalImage),
                  let translatedPNG = ImageEncoder.encodePNGPreservingSourcePixels(session.translatedImage)
            else { return nil }
            return PersistedTranslationPinState(
                originalImagePNG: originalPNG, translatedImagePNG: translatedPNG,
                translatedBlocks: session.translatedBlocks,
                originalBlocks: session.originalBlocks,
                translatedSelectionBlocks: session.translatedSelectionBlocks,
                sourceLanguage: session.sourceLanguage, targetLanguage: session.targetLanguage,
                displayMode: session.displayMode)
        }
        if translationSession != nil && persistedTranslation == nil { return nil }
        return PersistedPinRecord(
            imagePNG: imageData,
            visualFrame: CodableRect(visualFrame),
            normalVisualFrame: normalVisualFrame.map(CodableRect.init),
            compactCenter: CodablePoint(pinView.compactCenter),
            compactActualCenter: CodablePoint(pinView.compactActualCenter),
            isCompact: pinView.isCompactMode,
            shadowHidden: pinView.isShadowHidden,
            opacity: pinOpacity,
            textContent: textContent,
            translationState: persistedTranslation,
            pinKind: translationSession != nil ? .translation
                : (isDedicatedOCRPin ? .ocr : .ordinary),
            ocrBlocks: isDedicatedOCRPin ? recognizedTextBlocks : []
        )
    }

    private func select() {
        guard !isTemporarilyHidden else { return }
        delegate?.pinWindowDidSelect(self)
    }

    private var configuredZoomAnchorMode: PinZoomAnchorMode {
        let rawValue = UserDefaults.standard.string(forKey: PinZoomAnchorMode.userDefaultsKey)
        return rawValue.flatMap(PinZoomAnchorMode.init(rawValue:)) ?? .mouse
    }

    private func toggleCompact(around viewPoint: NSPoint) {
        exitTextSelectionMode()
        hideToolbar(reason: .temporaryInteraction)
        if pinView?.isCompactMode == true {
            let currentVisual = visualFrame
            let size = normalVisualFrame?.size ?? baseVisualSize
            let actualCenter = pinView?.compactActualCenter ?? NSPoint(x: 0.5, y: 0.5)
            let restored = PinGeometry.restoredVisualFrame(
                compactVisualFrame: currentVisual,
                normalVisualSize: size,
                compactActualCenter: actualCenter)
            pinView?.isCompactMode = false
            applyVisualFrame(restored)
        } else {
            let currentVisual = visualFrame
            normalVisualFrame = currentVisual
            pinView?.compactCenter = pinView?.normalizedImagePoint(for: viewPoint) ?? NSPoint(x: 0.5, y: 0.5)
            pinView?.isCompactMode = true
            let center = pinView?.screenPoint(forViewPoint: viewPoint)
                ?? NSPoint(x: currentVisual.midX, y: currentVisual.midY)
            let compactVisual = PinGeometry.compactVisualFrame(
                around: center,
                within: currentVisual,
                compactSize: Self.compactSize
            )
            applyVisualFrame(compactVisual, updateNormal: false)
            // After compact visual is set, calculate the actual visible crop center
            // (accounts for edge clamping in sourceRect()).
            if let pinView {
                let source = pinView.sourceRectForCompact()
                let imageW = max(pinView.imageSize.width, 1)
                let imageH = max(pinView.imageSize.height, 1)
                pinView.compactActualCenter = NSPoint(
                    x: (source.origin.x + source.size.width / 2) / imageW,
                    y: (source.origin.y + source.size.height / 2) / imageH
                )
            }
        }
        applyWindowOpacity()
        select()
    }

    private func zoom(
        by factor: CGFloat,
        screenPoint: NSPoint,
        viewPoint: NSPoint?,
        isGesture: Bool,
        phase: NSEvent.Phase,
        source: String
    ) {
        guard window != nil, pinView?.isCompactMode != true else { return }
        hideToolbar(reason: .temporaryInteraction)
        let currentVisual = visualFrame
        let effectiveFactor: CGFloat
        let targetScale: CGFloat?
        if PinZoomInputPreferences.isSmoothZoomEnabled {
            effectiveFactor = factor
            targetScale = nil
        } else {
            let currentScale = currentVisual.width / max(baseVisualSize.width, 1)
            let roundedScale = (currentScale * 10).rounded() / 10
            let nextScale = factor >= 1 ? roundedScale + 0.1 : roundedScale - 0.1
            let clampedScale = min(Self.maxScale, max(Self.minScale, nextScale))
            effectiveFactor = clampedScale / max(currentScale, 0.001)
            targetScale = clampedScale
        }
        let mode = activeZoomAnchorMode ?? configuredZoomAnchorMode
        beginZoomSessionIfNeeded(
            mode: mode,
            currentVisual: currentVisual,
            screenPoint: screenPoint,
            viewPoint: viewPoint
        )

        let visual: NSRect
        switch activeZoomAnchorMode ?? mode {
        case .topLeft:
            visual = PinGeometry.topLeftAnchoredZoomedVisualFrame(
                currentVisual: currentVisual,
                baseVisualSize: baseVisualSize,
                factor: effectiveFactor,
                minScale: Self.minScale,
                maxScale: Self.maxScale
            )
        case .mouse:
            if let zoomSession {
                visual = PinGeometry.zoomedVisualFrame(
                    currentVisual: currentVisual,
                    baseVisualSize: baseVisualSize,
                    factor: effectiveFactor,
                    zoomSession: zoomSession,
                    minScale: Self.minScale,
                    maxScale: Self.maxScale,
                    snapToUnitDistance: 0.04,
                    snapCandidates: []
                )
            } else {
                visual = PinGeometry.zoomedVisualFrame(
                    currentVisual: currentVisual,
                    baseVisualSize: baseVisualSize,
                    factor: effectiveFactor,
                    anchorScreen: screenPoint,
                    minScale: Self.minScale,
                    maxScale: Self.maxScale,
                    snapToUnitDistance: 0.04,
                    snapCandidates: []
                )
            }
        }

        applyVisualFrame(visual)
        if phase.isEmpty || phase.contains(.ended) || phase.contains(.cancelled) {
            refreshPinAnnotationCursor()
        }
        pinView?.showZoomPercentage(targetScale ?? (visual.width / max(baseVisualSize.width, 1)))
        logZoom(
            source: source,
            accepted: true,
            pointerInside: nil,
            factor: effectiveFactor,
            screenPoint: screenPoint,
            before: currentVisual,
            after: visual,
            phase: phase
        )
        if phase.contains(.ended) || phase.contains(.cancelled) {
            discreteWheelAccumulator = 0
            logZoomPhase(source: source, phase: phase, screenPoint: screenPoint)
        }
    }

    private func adjustPinOpacity(by delta: CGFloat) {
        guard let adjustedOpacity = PinOpacityPolicy.adjustedOpacity(
            storedOpacity: pinOpacity,
            by: delta,
            isCompact: pinView?.isCompactMode == true
        ) else { return }
        pinOpacity = adjustedOpacity
        applyWindowOpacity()
        pinView?.showOpacityPercentage(pinOpacity)
    }

    private func applyWindowOpacity() {
        window?.alphaValue = PinOpacityPolicy.displayedOpacity(
            storedOpacity: pinOpacity,
            isCompact: pinView?.isCompactMode == true
        )
    }

    private func zoomFromScreenPoint(
        factor: CGFloat,
        screenPoint: NSPoint,
        isGesture: Bool = false,
        phase: NSEvent.Phase = [],
        source: String = "screen"
    ) {
        guard window != nil, let pinView = pinView, pinView.isCompactMode != true else { return }
        let viewPoint = PinGeometry.viewPoint(
            forScreenPoint: screenPoint,
            windowFrame: currentWindowFrame
        )
        let pointerInside = pinView.containsOpaqueImagePoint(viewPoint)
        guard PinGeometry.acceptsZoomEvent(
            pointerInside: pointerInside,
            sessionActive: activeZoomAnchorMode != nil
        ) else {
            logZoomRejected(source: source, pointerInside: pointerInside, screenPoint: screenPoint, phase: phase)
            return
        }
        select()
        zoom(
            by: factor,
            screenPoint: screenPoint,
            viewPoint: pointerInside ? viewPoint : nil,
            isGesture: isGesture,
            phase: phase,
            source: source
        )
    }

    private func updatePixelInspectorFromScreenPoint(_ screenPoint: NSPoint) {
        guard let pinView, window != nil else { return }
        let viewPoint = PinGeometry.viewPoint(
            forScreenPoint: screenPoint,
            windowFrame: currentWindowFrame
        )
        pinView.updateTextSelectionCursor(at: viewPoint)
        pinView.updatePixelInspectorFromMouseMove(at: viewPoint)
    }

    private func shouldLetPinViewStartMouseAnchor(for event: NSEvent) -> Bool {
        guard PinZoomInputPreferences.isWheelZoomEnabled,
              activeZoomAnchorMode == nil,
              configuredZoomAnchorMode == .mouse,
              event.window === window
        else { return false }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return pointerIsInsidePin(at: screenPoint)
    }

    @discardableResult
    private func handleGestureEvent(_ event: NSEvent) -> Bool {
        guard !isTemporarilyHidden else { return false }
        if textSelectionSession.suspendsPinInteraction { return true }
        guard PinZoomInputPreferences.isMagnifyZoomEnabled else { return false }
        let screenPoint = NSEvent.mouseLocation
        let pointerInside = pointerIsInsidePin(at: screenPoint)
        guard PinGeometry.acceptsZoomEvent(
            pointerInside: pointerInside,
            sessionActive: activeZoomAnchorMode != nil
        ) else {
            logZoomRejected(source: "gesture-monitor", pointerInside: pointerInside, screenPoint: screenPoint, phase: mergedPhase(event))
            return false
        }

        switch event.type {
        case .beginGesture:
            beginZoomSessionIfNeeded(
                mode: activeZoomAnchorMode ?? configuredZoomAnchorMode,
                currentVisual: visualFrame,
                screenPoint: screenPoint,
                viewPoint: nil
            )
            logZoomPhase(source: "gesture-monitor", phase: .began, screenPoint: screenPoint)
            return true
        case .endGesture:
            refreshPinAnnotationCursor()
            logZoomPhase(source: "gesture-monitor", phase: .ended, screenPoint: screenPoint)
            return true
        case .magnify, .gesture:
            let magnification = event.magnification
            guard abs(magnification) > 0.0001 else { return true }
            zoomFromScreenPoint(
                factor: max(0.2, min(5.0, 1.0 + magnification)),
                screenPoint: screenPoint,
                isGesture: true,
                phase: mergedPhase(event),
                source: "gesture-monitor"
            )
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func handleScrollEvent(_ event: NSEvent) -> Bool {
        guard !isTemporarilyHidden else { return false }
        if textSelectionSession.suspendsPinInteraction { return true }
        let screenPoint = NSEvent.mouseLocation
        let pointerInside = pointerIsInsidePin(at: screenPoint)
        let phase = mergedPhase(event)

        if InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .pinOpacity, among: [.pinZoom, .pinOpacity]) {
            guard pointerInside, pinView?.isSelected == true else { return false }
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return true }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            let direction: CGFloat = delta > 0 ? 1 : -1
            adjustPinOpacity(by: direction * step)
            return true
        }

        guard InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .pinZoom, among: [.pinZoom, .pinOpacity]) else { return false }

        guard PinZoomInputPreferences.isWheelZoomEnabled else { return false }

        if activeZoomAnchorMode != nil, phase.contains(.ended) || phase.contains(.cancelled) {
            refreshPinAnnotationCursor()
            logZoomPhase(source: "scroll-monitor", phase: phase, screenPoint: screenPoint)
            return true
        }

        guard PinGeometry.acceptsZoomEvent(
            pointerInside: pointerInside,
            sessionActive: activeZoomAnchorMode != nil
        ) else {
            logZoomRejected(source: "scroll-monitor", pointerInside: pointerInside, screenPoint: screenPoint, phase: phase)
            return false
        }

        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return true }
        if !PinZoomInputPreferences.isSmoothZoomEnabled {
            discreteWheelAccumulator += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 0.5
            guard abs(discreteWheelAccumulator) >= threshold else { return true }
            discreteWheelAccumulator = 0
        }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
        let factor = max(0.2, min(5.0, 1.0 + delta * sensitivity))
        select()
        zoom(
            by: factor,
            screenPoint: screenPoint,
            viewPoint: nil,
            isGesture: true,
            phase: phase,
            source: "scroll-monitor"
        )
        return true
    }

    private func handleFlagsEvent(_ event: NSEvent, screenPoint: NSPoint) {
        guard !isTemporarilyHidden else { return }
        guard !textSelectionSession.suspendsPinInteraction else { return }
        guard let pinView else { return }
        let viewPoint = PinGeometry.viewPoint(
            forScreenPoint: screenPoint,
            windowFrame: currentWindowFrame
        )
        pinView.updatePixelInspectorForFlags(
            modifierFlags: event.modifierFlags,
            viewPoint: viewPoint
        )
    }

    private func mergedPhase(_ event: NSEvent) -> NSEvent.Phase {
        var phase = event.phase
        phase.formUnion(event.momentumPhase)
        return phase
    }

    private func pointerIsInsidePin(at screenPoint: NSPoint, includeCompact: Bool = false) -> Bool {
        guard window != nil, let pinView = pinView else { return false }
        if !includeCompact && pinView.isCompactMode { return false }
        let viewPoint = PinGeometry.viewPoint(
            forScreenPoint: screenPoint,
            windowFrame: currentWindowFrame
        )
        return pinView.containsInteractiveImagePoint(viewPoint)
    }

    private func deselectIfOutside(screenPoint: NSPoint) {
        if toolbarPanel?.frame.contains(screenPoint) == true {
            return
        }
        guard pinView?.isSelected == true else { return }
        if !pointerIsInsidePin(at: screenPoint, includeCompact: true) {
            setSelected(false)
            if PinGeometry.shouldHideToolbarOnDeselect(wasVisible: toolbarPanel?.isVisible == true) {
                hideToolbar(reason: .explicitAction)
            }
        }
    }

    private func updateZoomGesturePhase(at screenPoint: NSPoint, phase: NSEvent.Phase) {
        if phase.contains(.began) {
            beginZoomSessionIfNeeded(
                mode: activeZoomAnchorMode ?? configuredZoomAnchorMode,
                currentVisual: visualFrame,
                screenPoint: screenPoint,
                viewPoint: nil
            )
            logZoomPhase(source: "view", phase: phase, screenPoint: screenPoint)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            refreshPinAnnotationCursor()
            logZoomPhase(source: "view", phase: phase, screenPoint: screenPoint)
        }
    }

    private func beginZoomSessionIfNeeded(
        mode: PinZoomAnchorMode,
        currentVisual: NSRect,
        screenPoint: NSPoint,
        viewPoint: NSPoint?
    ) {
        if activeZoomAnchorMode == nil {
            activeZoomAnchorMode = mode
        }

        guard activeZoomAnchorMode == .mouse, zoomSession == nil else { return }
        let normalizedAnchor = viewPoint.map {
            pinView?.normalizedImagePoint(for: $0) ?? PinGeometry.normalizedVisualPoint(
                viewPoint: $0,
                visualSize: currentVisual.size,
                shadowOutset: Self.shadowOutset
            )
        } ?? PinGeometry.normalizedVisualPoint(
            screenPoint: screenPoint,
            visualFrame: currentVisual
        )
        zoomSession = PinZoomSession(
            anchorScreen: screenPoint,
            normalizedAnchor: normalizedAnchor
        )
    }

    private func resetZoomSession(reason: String) {
        guard activeZoomAnchorMode != nil || zoomSession != nil else { return }
        os_log(
            "zoom reset reason=%{public}@ mode=%{public}@",
            log: pinZoomLog,
            type: .info,
            reason,
            activeZoomAnchorMode?.rawValue ?? "none"
        )
        zoomSession = nil
        activeZoomAnchorMode = nil
    }

    private func refreshPinAnnotationCursor() {
        pinView?.annotationCanvasView.refreshCursorAtPointerIfInside()
    }

    private func logZoom(
        source: String,
        accepted: Bool,
        pointerInside: Bool?,
        factor: CGFloat,
        screenPoint: NSPoint,
        before: NSRect,
        after: NSRect,
        phase: NSEvent.Phase
    ) {
        os_log(
            "zoom %{public}@ source=%{public}@ mode=%{public}@ inside=%{public}@ factor=%.4f phase=%{public}lu screen=(%.1f,%.1f) before=(%.1f,%.1f %.1fx%.1f) after=(%.1f,%.1f %.1fx%.1f)",
            log: pinZoomLog,
            type: .info,
            accepted ? "accept" : "reject",
            source,
            activeZoomAnchorMode?.rawValue ?? configuredZoomAnchorMode.rawValue,
            pointerInside.map { $0 ? "true" : "false" } ?? "unknown",
            Double(factor),
            phase.rawValue,
            Double(screenPoint.x),
            Double(screenPoint.y),
            Double(before.origin.x),
            Double(before.origin.y),
            Double(before.width),
            Double(before.height),
            Double(after.origin.x),
            Double(after.origin.y),
            Double(after.width),
            Double(after.height)
        )
    }

    private func logZoomRejected(source: String, pointerInside: Bool, screenPoint: NSPoint, phase: NSEvent.Phase) {
        os_log(
            "zoom reject source=%{public}@ mode=%{public}@ inside=%{public}@ phase=%{public}lu screen=(%.1f,%.1f)",
            log: pinZoomLog,
            type: .info,
            source,
            activeZoomAnchorMode?.rawValue ?? configuredZoomAnchorMode.rawValue,
            pointerInside ? "true" : "false",
            phase.rawValue,
            Double(screenPoint.x),
            Double(screenPoint.y)
        )
    }

    private func logZoomPhase(source: String, phase: NSEvent.Phase, screenPoint: NSPoint) {
        os_log(
            "zoom phase source=%{public}@ mode=%{public}@ phase=%{public}lu screen=(%.1f,%.1f)",
            log: pinZoomLog,
            type: .info,
            source,
            activeZoomAnchorMode?.rawValue ?? configuredZoomAnchorMode.rawValue,
            phase.rawValue,
            Double(screenPoint.x),
            Double(screenPoint.y)
        )
    }

    fileprivate var isRoutable: Bool { !isTemporarilyHidden && window?.isVisible == true }
    fileprivate var needsRoutedMouseMovement: Bool {
        isRoutable && (isTransparentAnnotationPin || activeZoomAnchorMode != nil || pinView?.isPixelInspectorActive == true)
    }

    fileprivate func routeMouseDown(at screenPoint: NSPoint) {
        guard isRoutable else { return }
        resetZoomSession(reason: "mouse-down")
        guard toolbarPanel?.frame.contains(screenPoint) != true else { return }
        if currentToolbarTool == .measure,
           !pointerIsInsidePin(at: screenPoint) {
            externalMeasureDrag = ExternalMeasureDrag(lastScreenPoint: screenPoint)
            return
        }
        externalMeasureDrag = nil
        deselectIfOutside(screenPoint: screenPoint)
    }

    fileprivate func routeMouseMove(at screenPoint: NSPoint) {
        guard isRoutable else { return }
        resetZoomSession(reason: "mouse-move")
        if isTransparentAnnotationPin {
            updateTransparentPreviewHover(at: screenPoint)
            return
        }
        updatePixelInspectorFromScreenPoint(screenPoint)
    }

    fileprivate func routeMouseDrag(at screenPoint: NSPoint, modifierFlags: NSEvent.ModifierFlags) {
        guard var drag = externalMeasureDrag, let pinView else { return }
        defer { externalMeasureDrag = drag }

        let previousViewPoint = PinGeometry.viewPoint(
            forScreenPoint: drag.lastScreenPoint,
            windowFrame: currentWindowFrame
        )
        let currentViewPoint = PinGeometry.viewPoint(
            forScreenPoint: screenPoint,
            windowFrame: currentWindowFrame
        )
        drag.lastScreenPoint = screenPoint

        if !drag.hasEnteredImage {
            guard let entryPoint = pinView.measurementEntryPoint(
                from: previousViewPoint,
                to: currentViewPoint
            ) else { return }
            select()
            drag.hasEnteredImage = pinView.beginExternalMeasure(at: entryPoint)
            if drag.hasEnteredImage {
                pinView.updateExternalMeasure(
                    at: currentViewPoint,
                    shiftHeld: modifierFlags.contains(.shift)
                )
            }
            return
        }

        pinView.updateExternalMeasure(
            at: currentViewPoint,
            shiftHeld: modifierFlags.contains(.shift)
        )
    }

    fileprivate func finishExternalMeasureDrag() {
        guard let drag = externalMeasureDrag else { return }
        externalMeasureDrag = nil
        if drag.hasEnteredImage { pinView?.finishExternalMeasure() }
    }

    fileprivate func routeScroll(_ event: NSEvent) -> Bool {
        guard isRoutable else { return false }
        guard !isTransparentAnnotationPin else { return false }
        if shouldLetPinViewStartMouseAnchor(for: event) { return false }
        return handleScrollEvent(event)
    }

    fileprivate func routeGesture(_ event: NSEvent) -> Bool {
        guard isRoutable else { return false }
        guard !isTransparentAnnotationPin else { return false }
        return handleGestureEvent(event)
    }

    fileprivate func routeFlags(_ event: NSEvent, at screenPoint: NSPoint) {
        guard isRoutable else { return }
        handleFlagsEvent(event, screenPoint: screenPoint)
    }

    fileprivate func canRoutePointerEvent(at screenPoint: NSPoint) -> Bool {
        pointerIsInsidePin(at: screenPoint) || activeZoomAnchorMode != nil
    }

    fileprivate var routingWindow: NSWindow? { window }
    fileprivate var routingToolbarWindow: NSWindow? { toolbarPanel }
    fileprivate var hasLockedZoomSession: Bool { activeZoomAnchorMode != nil }

    private func removeMonitors() {
        PinEventRouter.shared.unregister(self)
        resetZoomSession(reason: "remove-monitors")
    }

    private func drag(from viewPoint: NSPoint, event: NSEvent) {
        guard window != nil else { return }
        let shouldRestoreToolbar = toolbarPanel?.isVisible == true
        hideToolbar(reason: .temporaryInteraction)
        let imagePointOffset = pinView?.imagePointOffset(for: viewPoint) ?? .zero
        let visualSize = visualFrame.size
        let updateNormal = pinView?.isCompactMode != true
        while true {
            guard let dragEvent = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            if dragEvent.type == .leftMouseUp { break }

            let mouse = NSEvent.mouseLocation
            let rawVisual = PinGeometry.visualFrameForDrag(
                mouseScreen: mouse,
                imagePointOffset: imagePointOffset,
                visualSize: visualSize
            )
            let visual = snappedVisualFrame(rawVisual)
            applyVisualFrame(visual, updateNormal: updateNormal)
        }
        if PinGeometry.shouldRestoreToolbarAfterDrag(
            wasVisible: shouldRestoreToolbar,
            isCompact: pinView?.isCompactMode == true
        ) {
            showToolbar(near: NSEvent.mouseLocation)
        }
    }

    /// Transparent previews intentionally consume pointer presses so marking a
    /// line never starts a window drag. The toolbar's move button owns the one
    /// explicit exception: holding it moves the Pin immediately.
    private func dragTransparentPinFromToolbar() {
        guard isTransparentAnnotationPin, window != nil else { return }
        hideToolbar(reason: .temporaryInteraction)
        let initialMouse = NSEvent.mouseLocation
        let initialVisualFrame = visualFrame
        while true {
            guard let dragEvent = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            guard dragEvent.type != .leftMouseUp else { break }

            let mouse = NSEvent.mouseLocation
            let moved = initialVisualFrame.offsetBy(
                dx: mouse.x - initialMouse.x,
                dy: mouse.y - initialMouse.y
            )
            applyVisualFrame(snappedVisualFrame(moved), updateNormal: false)
        }
        showTransparentPreviewToolbarIfNeeded(near: NSEvent.mouseLocation)
    }

    private static func windowFrame(forVisualFrame frame: NSRect) -> NSRect {
        PinGeometry.windowFrame(forVisualFrame: frame, shadowOutset: shadowOutset)
    }

    private static func pixelAlignedVisualFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        PinGeometry.pixelAlignedVisualFrame(frame, scale: max(screen.backingScaleFactor, 1))
    }

    private func pixelAlignedVisualFrame(_ frame: NSRect) -> NSRect {
        Self.pixelAlignedVisualFrame(
            frame,
            on: screenFrame(containing: NSPoint(x: frame.midX, y: frame.midY))
        )
    }

    private var currentWindowFrame: NSRect {
        window?.frame ?? Self.windowFrame(forVisualFrame: visualFrame)
    }

    private func updatePinViewDisplayFrame() {
        guard let window else { return }
        let displayFrame = PinGeometry.displayFrame(
            forVisualFrame: visualFrame,
            inWindowFrame: window.frame
        )
        pinView?.setDisplayFrame(displayFrame)
    }

    private func applyVisualFrame(_ frame: NSRect, display: Bool = true, updateNormal: Bool = true) {
        let pixelAlignedFrame = pixelAlignedVisualFrame(frame)
        visualFrame = pixelAlignedFrame
        window?.setFrame(Self.windowFrame(forVisualFrame: pixelAlignedFrame), display: display)
        updatePinViewDisplayFrame()
        if updateNormal {
            normalVisualFrame = pixelAlignedFrame
        }
        if toolbarPanel?.isVisible == true {
            positionToolbar()
        }
    }

    private func snappedVisualFrame(_ visual: NSRect) -> NSRect {
        PinGeometry.snappedVisualFrame(
            visual,
            screenFrames: NSScreen.screens.map(\.frame),
            snapDistance: Self.snapDistance
        )
    }

    private func showToolbar(near screenPoint: NSPoint, selectsPin: Bool = true) {
        guard window != nil, pinView?.isCompactMode != true else { return }
        if selectsPin { select() }

        if toolbarPanel == nil {
            toolbarPanel = makeToolbarPanel()
        }
        rebuildPinToolbar()
        positionToolbar()
        toolbarPanel?.orderFrontRegardless()
        os_log(
            "toolbar show screen=(%.1f,%.1f) visual=(%.1f,%.1f %.1fx%.1f)",
            log: pinToolbarLog,
            type: .info,
            Double(screenPoint.x),
            Double(screenPoint.y),
            Double(visualFrame.origin.x),
            Double(visualFrame.origin.y),
            Double(visualFrame.width),
            Double(visualFrame.height)
        )
    }

    private func toggleToolbar(near screenPoint: NSPoint) {
        switch PinGeometry.toolbarToggleAction(
            isVisible: toolbarPanel?.isVisible == true,
            isCompact: pinView?.isCompactMode == true
        ) {
        case .show:
            showToolbar(near: screenPoint)
        case .hide:
            hideToolbar(reason: .userToggle)
        case .ignore:
            break
        }
    }

    /// A transparent Pin deliberately stays preview-only. Its one editing
    /// action returns to the full transparent selection session, where the
    /// crop and annotations share the proven Overlay input state machine.
    func presentTransparentAnnotationPreviewOnly() {
        guard isTransparentAnnotationPin else { return }
        setSelected(true)
        showTransparentPreviewToolbarIfNeeded()
    }

    func showTransparentPreviewToolbarIfNeeded(near screenPoint: NSPoint? = nil) {
        guard isTransparentAnnotationPin, toolbarPanel?.isVisible != true else { return }
        showToolbar(
            near: screenPoint ?? NSPoint(x: visualFrame.midX, y: visualFrame.midY),
            selectsPin: false
        )
    }

    private func scheduleTransparentPreviewToolbarReveal(near screenPoint: NSPoint) {
        guard isTransparentAnnotationPin, pointerIsInsidePin(at: screenPoint) else { return }
        transparentPreviewHideWorkItem?.cancel()
        transparentPreviewHideWorkItem = nil
        guard toolbarPanel?.isVisible != true, transparentPreviewRevealWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pointerIsInsidePin(at: NSEvent.mouseLocation) else { return }
            self.transparentPreviewRevealWorkItem = nil
            self.showTransparentPreviewToolbarIfNeeded(near: NSEvent.mouseLocation)
        }
        transparentPreviewRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transparentPreviewRevealDelay, execute: workItem)
    }

    private func scheduleTransparentPreviewToolbarHide() {
        transparentPreviewRevealWorkItem?.cancel()
        transparentPreviewRevealWorkItem = nil
        guard isTransparentAnnotationPin, toolbarPanel?.isVisible == true,
              transparentPreviewHideWorkItem == nil
        else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.transparentPreviewContains(NSEvent.mouseLocation) else { return }
            self.transparentPreviewHideWorkItem = nil
            self.hideToolbar(reason: .explicitAction)
        }
        transparentPreviewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transparentPreviewHideDelay, execute: workItem)
    }

    private func updateTransparentPreviewHover(at screenPoint: NSPoint) {
        if transparentPreviewContains(screenPoint) {
            transparentPreviewHideWorkItem?.cancel()
            transparentPreviewHideWorkItem = nil
            if pointerIsInsidePin(at: screenPoint) {
                scheduleTransparentPreviewToolbarReveal(near: screenPoint)
            }
        } else {
            scheduleTransparentPreviewToolbarHide()
        }
    }

    private func transparentPreviewContains(_ screenPoint: NSPoint) -> Bool {
        pointerIsInsidePin(at: screenPoint) || toolbarPanel?.frame.contains(screenPoint) == true
    }

    private func makeToolbarPanel() -> NSPanel {
        let panel = PinToolbarPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onConfirm = { [weak self] in
            self?.confirmPinAnnotationEditing()
        }
        panel.onSave = { [weak self] in
            self?.savePin()
        }
        panel.onCopy = { [weak self] in
            self?.copyPin()
        }
        panel.onKeyEquivalent = { [weak self] event in
            self?.pinView?.handleTextSelectionKeyEquivalent(event) ?? false
        }
        panel.onToolbarShortcut = { [weak self] event in
            self?.handlePinToolbarShortcut(event) ?? false
        }
        panel.onExitTextSelection = { [weak self] in
            guard let self, self.textSelectionSession.suspendsPinInteraction else { return false }
            self.exitTextSelectionMode()
            return true
        }
        panel.title = "Pinlume Pin Toolbar"
        let baseLevel = window?.level.rawValue ?? NSWindow.Level.statusBar.rawValue
        panel.level = NSWindow.Level(rawValue: baseLevel + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)))
        contentView.appearance = ToolbarLayout.appearance

        let bottomStrip = ToolbarStripView(orientation: .horizontal)
        bottomStrip.showsNativeTooltips = false
        bottomStrip.onClick = { [weak self] action in
            self?.handlePinToolbarAction(action)
        }
        bottomStrip.onHover = { [weak self] action, hovered in
            self?.handlePinToolbarHover(action, hovered: hovered, strip: self?.toolbarBottomStrip)
        }
        let moreStrip = ToolbarStripView(orientation: .horizontal)
        moreStrip.showsNativeTooltips = false
        moreStrip.onClick = { [weak self] action in
            self?.handlePinToolbarAction(action)
        }
        moreStrip.onHover = { [weak self] action, hovered in
            self?.handlePinToolbarHover(action, hovered: hovered, strip: self?.toolbarMoreStrip)
        }
        let optionsRow = ToolOptionsRowView()
        optionsRow.overlayView = pinView?.annotationCanvasView
        optionsRow.isHidden = true
        contentView.addSubview(bottomStrip)
        contentView.addSubview(moreStrip)
        contentView.addSubview(optionsRow)
        let tooltipView = PinToolbarTooltipView(frame: .zero)
        tooltipView.isHidden = true
        contentView.addSubview(tooltipView)
        toolbarBottomStrip = bottomStrip
        toolbarMoreStrip = moreStrip
        toolbarOptionsRow = optionsRow
        toolbarTooltipView = tooltipView
        panel.contentView = contentView
        return panel
    }

    private func rebuildPinToolbar() {
        guard let toolbarPanel,
              let contentView = toolbarPanel.contentView,
              let bottomStrip = toolbarBottomStrip,
              let moreStrip = toolbarMoreStrip,
              let optionsRow = toolbarOptionsRow
        else { return }
        hidePinToolbarTooltip()

        if isTransparentAnnotationPin {
            isPinMoreToolsExpanded = false
            bottomStrip.setButtons(transparentAnnotationPinButtons(inPrimary: true))
            if let moveButton = bottomStrip.buttonViews.first(where: {
                if case .moveSelection = $0.action { return true }
                return false
            }) {
                moveButton.onMouseDown = { [weak self] _ in
                    self?.dragTransparentPinFromToolbar()
                }
            }
            moreStrip.setButtons([])
            moreStrip.isHidden = true
            optionsRow.isHidden = true
            contentView.frame = NSRect(origin: .zero, size: toolbarPanel.frame.size)
            positionToolbar()
            return
        }

        if let dedicatedButtons = dedicatedPinButtons() {
            bottomStrip.setButtons(dedicatedButtons)
            moreStrip.setButtons([])
            moreStrip.isHidden = true
            optionsRow.isHidden = true
            contentView.frame = NSRect(origin: .zero, size: toolbarPanel.frame.size)
            positionToolbar()
            return
        }

        let pinShadowInPrimary = Self.isPinShadowToolInPrimary
        let availableMoreButtons = pinToolbarSecondaryButtons(includePinShadow: !pinShadowInPrimary)
        if availableMoreButtons.isEmpty {
            isPinMoreToolsExpanded = false
        }
        var bottomButtons = ToolbarLayout.primaryOverlayButtons(
            selectedTool: currentToolbarTool,
            selectedColor: pinView?.currentAnnotationColor ?? Self.lastUsedToolbarColor,
            moreExpanded: isPinMoreToolsExpanded,
            hasMoreTools: !availableMoreButtons.isEmpty,
            trailingAction: .confirm,
            canUndo: pinView?.canUndoHistory ?? false,
            canRedo: pinView?.canRedoHistory ?? false,
            isRecording: false
        )
        insertPrimaryPinOnlyButtons(into: &bottomButtons)
        insertPrimaryTextCopyButtonIfNeeded(into: &bottomButtons)
        bottomStrip.setButtons(bottomButtons)

        let moreButtons = isPinMoreToolsExpanded
            ? availableMoreButtons
            : []
        moreStrip.setButtons(moreButtons)
        moreStrip.isHidden = moreButtons.isEmpty

        if currentToolbarTool != .select {
            pinView?.configureToolOptionsRow(optionsRow, fallbackTool: currentToolbarTool)
            optionsRow.isHidden = optionsRow.subviews.isEmpty
        } else {
            optionsRow.isHidden = true
        }

        contentView.frame = NSRect(origin: .zero, size: toolbarPanel.frame.size)
        positionToolbar()
    }

    private static var isPinShadowToolInPrimary: Bool {
        UserDefaults.standard.object(forKey: pinShadowToolInPrimaryKey) as? Bool ?? true
    }

    private var isTextPin: Bool { !(textContent?.isEmpty ?? true) }

    private func dedicatedPinButtons() -> [ToolbarButton]? {
        if translationSession != nil { return dedicatedTranslationPinButtons() }
        if isDedicatedOCRPin { return dedicatedOCRPinButtons() }
        return nil
    }

    private func transparentAnnotationPinButtons(inPrimary: Bool) -> [ToolbarButton] {
        guard inPrimary else { return [] }
        var buttons = [
            ToolbarButton(
                action: .reeditTransparentAnnotation,
                sfSymbol: "crop",
                tooltip: L("Adjust Area and Edit")
            ),
            ToolbarButton(
                action: .moveSelection,
                sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                tooltip: L("Move Selection")
            ),
        ]
        buttons.append(ToolbarButton(action: .separator, sfSymbol: nil, tooltip: "", isSeparator: true))
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        if ToolbarActionPreferences.isEnabled(.save, in: enabledActions) {
            buttons.append(ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down.fill", tooltip: L("Save")))
        }
        if ToolbarActionPreferences.isEnabled(.copy, in: enabledActions) {
            buttons.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        }
        buttons += [
            ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Close")),
        ]
        return buttons
    }

    private func dedicatedOCRPinButtons() -> [ToolbarButton] {
        let buttons: [(DedicatedToolbarTool, ToolbarButton)] = [
            (.selectText, ToolbarButton(
                action: .selectText, sfSymbol: "text.cursor", tooltip: L("Select Text"),
                isSelected: textSelectionSession.suspendsPinInteraction)),
            (.copyText, ToolbarButton(
                action: .copyText,
                sfSymbol: "doc.on.doc",
                tooltip: L("Copy Text"),
                shortcutAction: .copyRecognizedText
            )),
        ]
        return buttons.compactMap { tool, button in
            DedicatedToolPreferences.isVisible(tool, in: .ocrPin) ? button : nil
        }
    }

    private func dedicatedTranslationPinButtons() -> [ToolbarButton] {
        guard let session = translationSession else { return [] }
        let sourceName = TranslationService.availableLanguages.first(where: {
            $0.code == session.sourceLanguage
        }).map { L($0.name) } ?? session.sourceLanguage
        let targetName = TranslationService.availableLanguages.first(where: {
            $0.code == session.targetLanguage
        }).map { L($0.name) } ?? session.targetLanguage
        let buttons: [(DedicatedToolbarTool, ToolbarButton)] = [
            (.language, ToolbarButton(
                action: .translationPinLanguage, sfSymbol: "character.book.closed",
                tooltip: "\(sourceName) → \(targetName)",
                shortcutAction: .translationLanguage)),
            (.toggleOriginalTranslation, ToolbarButton(
                action: .translationPinToggle,
                sfSymbol: session.displayMode == .translated ? "character.book.closed.fill" : "photo",
                tooltip: session.displayMode == .translated ? L("Show Original") : L("Show Translation"),
                isSelected: session.displayMode == .translated,
                shortcutAction: .translationToggle)),
            (.copyOriginal, ToolbarButton(
                action: .copy,
                sfSymbol: "doc.on.doc",
                tooltip: L("Copy Original"),
                shortcutAction: .copyOriginalText
            )),
            (.copyTranslation, ToolbarButton(
                action: .copyText,
                sfSymbol: "character.book.closed",
                tooltip: L("Copy Translation"),
                shortcutAction: .copyTranslatedText
            )),
        ]
        return buttons.compactMap { tool, button in
            DedicatedToolPreferences.isVisible(tool, in: .translationPin) ? button : nil
        }
    }

    private static var isTextCopyToolInPrimary: Bool {
        UserDefaults.standard.object(forKey: textCopyToolInPrimaryKey) as? Bool ?? false
    }

    private static var isSelectTextToolInPrimary: Bool {
        // OCR pins open directly in text-selection mode, so keep its matching
        // control visible by default. Users can still move it back to More Tools.
        UserDefaults.standard.object(forKey: selectTextToolInPrimaryKey) as? Bool ?? true
    }

    private func pinToolbarSecondaryButtons(includePinShadow: Bool) -> [ToolbarButton] {
        var buttons = ToolbarLayout.secondaryOverlayButtons(
            selectedTool: currentToolbarTool,
            beautifyEnabled: false,
            translateEnabled: false,
            effectsActive: false,
            includeExtraActions: false,
            includeImageTransformActions: translationSession == nil,
            includePinShadowAction: false
        )
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        #if !OFFLINE
        if ToolbarActionPreferences.isEnabled(.upload, in: enabledActions),
           let uploadButton = ToolbarCustomAction.upload.makeToolbarButton() {
            buttons.append(uploadButton)
        }
        #endif
        let orderedItems = PinToolbarLayoutPreferences.items(inPrimary: false)
        if includePinShadow,
           ToolbarActionPreferences.isEnabled(.pinShadow, in: enabledActions),
           let shadowButton = pinShadowButton() {
            insertPinOnlyButton(shadowButton, item: .pinShadow, orderedItems: orderedItems, into: &buttons)
        }
        if isTextPin,
           !Self.isTextCopyToolInPrimary,
           ToolbarActionPreferences.isEnabled(.copyText, in: enabledActions),
           let copyButton = ToolbarCustomAction.copyText.makeToolbarButton() {
            buttons.append(copyButton)
        }
        var pinOnlyButtons: [ToolbarButton] = []
        if let translationSession {
            var toggle = ToolbarButton(
                action: .translationPinToggle,
                sfSymbol: "arrow.left.arrow.right.square",
                tooltip: translationSession.displayMode == .original
                    ? L("Show Translation") : L("Show Original"))
            toggle.isSelected = translationSession.displayMode == .original
            pinOnlyButtons.insert(toggle, at: 0)
            pinOnlyButtons.insert(ToolbarButton(
                action: .translationPinLanguage,
                sfSymbol: "translate",
                tooltip: L("Open Translation Window")), at: 1)
        }
        if !Self.isSelectTextToolInPrimary,
           ToolbarActionPreferences.isEnabled(.selectText, in: enabledActions),
           let selectButton = ToolbarCustomAction.selectText.makeToolbarButton() {
            var button = selectButton
            button.isSelected = textSelectionSession.suspendsPinInteraction
            insertPinOnlyButton(button, item: .selectText, orderedItems: orderedItems, into: &buttons)
        }
        buttons.append(contentsOf: pinOnlyButtons)
        return buttons
    }

    private func pinShadowButton() -> ToolbarButton? {
        var button = ToolbarButton(
            action: .pinShadowToggle,
            sfSymbol: "square.stack.3d.down.right",
            tooltip: (pinView?.isShadowHidden ?? false) ? L("Show Pin Shadow") : L("Hide Pin Shadow")
        )
        button.isSelected = pinView?.isShadowHidden ?? false
        return button
    }

    private func insertPrimaryPinOnlyButtons(into buttons: inout [ToolbarButton]) {
        let orderedItems = PinToolbarLayoutPreferences.items(inPrimary: true)
        for item in orderedItems {
            switch item {
            case .pinShadow:
                guard ToolbarActionPreferences.isEnabled(
                    .pinShadow,
                    in: ToolbarActionPreferences.enabledRawValuesAfterMigration()
                ), let button = pinShadowButton() else { continue }
                insertPinOnlyButton(button, item: item, orderedItems: orderedItems, into: &buttons)
            case .selectText:
                guard ToolbarActionPreferences.isEnabled(
                    .selectText,
                    in: ToolbarActionPreferences.enabledRawValuesAfterMigration()
                ), let selectButton = ToolbarCustomAction.selectText.makeToolbarButton() else { continue }
                var button = selectButton
                button.isSelected = textSelectionSession.suspendsPinInteraction
                insertPinOnlyButton(button, item: item, orderedItems: orderedItems, into: &buttons)
            case .screenTranslation:
                continue
            case .tool:
                continue
            }
        }
    }

    private func insertPinOnlyButton(
        _ button: ToolbarButton,
        item: PinToolbarLayoutItem,
        orderedItems: [PinToolbarLayoutItem],
        into buttons: inout [ToolbarButton]
    ) {
        guard let itemIndex = orderedItems.firstIndex(of: item) else { return }
        let succeedingTools = orderedItems[orderedItems.index(after: itemIndex)...].compactMap {
            if case .tool(let tool) = $0 { return tool }
            return nil
        }
        if let insertion = buttons.firstIndex(where: { candidate in
            guard case .tool(let tool) = candidate.action else { return false }
            return succeedingTools.contains(tool)
        }) {
            buttons.insert(button, at: insertion)
            return
        }
        let fallback = buttons.firstIndex {
            if case .tool = $0.action { return false }
            return true
        } ?? buttons.endIndex
        buttons.insert(button, at: fallback)
    }

    private func insertPrimaryTextCopyButtonIfNeeded(into buttons: inout [ToolbarButton]) {
        guard isTextPin,
              Self.isTextCopyToolInPrimary,
              ToolbarActionPreferences.isEnabled(.copyText, in: ToolbarActionPreferences.enabledRawValuesAfterMigration()),
              let copyButton = ToolbarCustomAction.copyText.makeToolbarButton()
        else { return }
        let insertion = buttons.firstIndex { button in
            if case .moreTools = button.action { return true }
            if case .separator = button.action { return true }
            return false
        } ?? buttons.count
        buttons.insert(copyButton, at: insertion)
    }

    private func updatePinToolbarButtonState() {
        guard let bottomStrip = toolbarBottomStrip,
              let moreStrip = toolbarMoreStrip
        else { return }

        if dedicatedPinButtons() != nil {
            rebuildPinToolbar()
            return
        }

        let pinShadowInPrimary = Self.isPinShadowToolInPrimary
        let availableMoreButtons = pinToolbarSecondaryButtons(includePinShadow: !pinShadowInPrimary)
        if availableMoreButtons.isEmpty {
            isPinMoreToolsExpanded = false
        }
        var bottomButtons = ToolbarLayout.primaryOverlayButtons(
            selectedTool: currentToolbarTool,
            selectedColor: pinView?.currentAnnotationColor ?? Self.lastUsedToolbarColor,
            moreExpanded: isPinMoreToolsExpanded,
            hasMoreTools: !availableMoreButtons.isEmpty,
            trailingAction: .confirm,
            canUndo: pinView?.canUndoHistory ?? false,
            canRedo: pinView?.canRedoHistory ?? false,
            isRecording: false
        )
        insertPrimaryPinOnlyButtons(into: &bottomButtons)
        insertPrimaryTextCopyButtonIfNeeded(into: &bottomButtons)
        let moreButtons = isPinMoreToolsExpanded ? availableMoreButtons : []

        if bottomButtons.count == bottomStrip.buttonViews.count,
           moreButtons.count == moreStrip.buttonViews.count {
            bottomStrip.updateState(from: bottomButtons)
            moreStrip.updateState(from: moreButtons)
        } else {
            rebuildPinToolbar()
        }
    }

    private func pinToolbarButtonView(for action: ToolbarButtonAction) -> ToolbarButtonView? {
        let strips: [ToolbarStripView?] = [toolbarBottomStrip, toolbarMoreStrip]
        for strip in strips {
            if let button = strip?.buttonViews.first(where: { toolbarActionsMatch($0.action, action) }) {
                return button
            }
        }
        return nil
    }

    private func handlePinToolbarHover(_ action: ToolbarButtonAction, hovered: Bool, strip: ToolbarStripView?) {
        if hovered,
           let button = strip?.buttonViews.first(where: { toolbarActionsMatch($0.action, action) }),
           !button.tooltipText.isEmpty,
           isPointerInsidePinToolbarButton(button) {
            showPinToolbarTooltip(
                ToolShortcutManager.tooltipText(
                    base: button.tooltipText,
                    toolbarAction: button.action,
                    shortcutOwner: button.shortcutAction,
                    showConfiguredShortcut: UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips")
                ),
                anchor: button
            )
        } else if !hovered {
            hidePinToolbarTooltip()
        }
    }

    /// Tracking events in a non-activating panel can arrive after a quick
    /// exit. Verify the current pointer before showing a tooltip so a stale
    /// enter event cannot briefly flash a label the user already left.
    private func isPointerInsidePinToolbarButton(_ button: ToolbarButtonView) -> Bool {
        guard let window = button.window else { return false }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return button.bounds.contains(button.convert(windowPoint, from: nil))
    }

    private func showPinToolbarTooltip(_ text: String, anchor: ToolbarButtonView) {
        guard toolbarTooltipView != nil else { return }
        toolbarTooltipText = text
        toolbarTooltipAnchor = anchor
        toolbarTooltipView?.text = text
        toolbarTooltipView?.isHidden = false
        positionToolbar()
    }

    private func hidePinToolbarTooltip() {
        guard toolbarTooltipText != nil || toolbarTooltipView?.isHidden == false else { return }
        toolbarTooltipText = nil
        toolbarTooltipAnchor = nil
        toolbarTooltipView?.isHidden = true
        positionToolbar()
    }

    private func toolbarActionsMatch(_ lhs: ToolbarButtonAction, _ rhs: ToolbarButtonAction) -> Bool {
        switch (lhs, rhs) {
        case (.tool(let a), .tool(let b)):
            return a == b
        case (.color, .color), (.moreTools, .moreTools), (.separator, .separator),
             (.undo, .undo), (.redo, .redo), (.copy, .copy), (.save, .save),
             (.confirmAnnotation, .confirmAnnotation), (.cancel, .cancel), (.detach, .detach),
             (.reeditTransparentAnnotation, .reeditTransparentAnnotation),
             (.flipHorizontal, .flipHorizontal), (.flipVertical, .flipVertical),
             (.rotateClockwise, .rotateClockwise), (.pinShadowToggle, .pinShadowToggle),
             (.selectText, .selectText),
             (.translationPinToggle, .translationPinToggle),
             (.translationPinLanguage, .translationPinLanguage),
             (.screenTranslationCompare, .screenTranslationCompare):
            return true
        default:
            return false
        }
    }

    private func confirmPinAnnotationEditing() {
        let hasActiveTool = pinView?.hasActiveAnnotationTool ?? (currentToolbarTool != .select)
        switch PinGeometry.toolbarConfirmAction(hasActiveAnnotationTool: hasActiveTool) {
        case .confirmAnnotations:
            pinView?.confirmAnnotationEditing()
            currentToolbarTool = .select
            pinView?.setAnnotationTool(.select)
            rebuildPinToolbar()
        case .hideToolbar:
            hideToolbar(reason: .explicitAction)
        }
    }

    private func handlePinToolbarAction(_ action: ToolbarButtonAction) {
        os_log(
            "toolbar action=%{public}@ currentTool=%{public}@",
            log: pinToolbarLog,
            type: .info,
            String(describing: action),
            String(describing: currentToolbarTool)
        )
        switch action {
        case .separator:
            break
        case .moreTools:
            isPinMoreToolsExpanded.toggle()
            rebuildPinToolbar()
        case .reeditTransparentAnnotation:
            onRequestTransparentAnnotationEdit?()
        case .tool(let tool):
            if textSelectionSession.suspendsPinInteraction {
                exitTextSelectionMode(rebuildToolbar: false)
            }
            pinView?.yieldPixelInspectorToShortcut(modifierFlags: NSEvent.modifierFlags)
            externalMeasureDrag = nil
            select()
            currentToolbarTool = currentToolbarTool == tool ? .select : tool
            pinView?.setAnnotationTool(currentToolbarTool)
            window?.makeFirstResponder(pinView)
            pinView?.annotationCanvasView.refreshCursorAtPointerIfInside()
            rebuildPinToolbar()
        case .color:
            let colorButton = pinToolbarButtonView(for: .color)
            pinView?.showColorPicker(anchorView: colorButton) { [weak self] in
                self?.updatePinToolbarButtonState()
            }
        case .undo:
            pinView?.undoAnnotation()
            rebuildPinToolbar()
        case .redo:
            pinView?.redoAnnotation()
            rebuildPinToolbar()
        case .confirmAnnotation:
            confirmPinAnnotationEditing()
        case .copy:
            if let translationSession {
                copyTextToPasteboard(translationSession.originalText)
            } else {
                copyPin()
                hideToolbar(reason: .explicitAction)
            }
        case .copyText:
            if isDedicatedOCRPin {
                let text = selectableTextOverlay.hasSelection
                    ? selectableTextOverlay.selectedText
                    : (recognizedTextContent ?? selectableTextOverlay.fullText)
                copyTextToPasteboard(text)
            } else if let translationSession {
                copyTextToPasteboard(translationSession.translatedText)
            } else if let textContent {
                copyTextToPasteboard(textContent)
            }
        case .selectText:
            toggleTextSelectionMode()
        case .translationPinToggle:
            toggleTranslationPinDisplay()
        case .translationPinLanguage:
            openTranslationPinLanguageWindow()
        #if !OFFLINE
        case .upload:
            uploadPin()
        #endif
        case .save:
            savePin()
        case .detach:
            // Legacy shortcut only: no static-image editor is opened from a Pin.
            break
        case .flipHorizontal:
            transformPinImage(.flipHorizontal)
        case .flipVertical:
            transformPinImage(.flipVertical)
        case .rotateClockwise:
            transformPinImage(.rotateClockwise)
        case .pinShadowToggle:
            pinView?.toggleShadowHidden()
            updatePinToolbarButtonState()
        case .cancel:
            close()
        default:
            break
        }
    }

    @discardableResult
    private func handlePinToolbarShortcut(_ event: NSEvent) -> Bool {
        guard let action = ToolShortcutManager.action(for: event) else { return false }
        handlePinToolbarShortcut(action)
        return true
    }

    private func handlePinToolbarShortcut(_ shortcutAction: ToolShortcutManager.Action) {
        let action: ToolbarButtonAction?
        if translationSession != nil {
            action = ToolShortcutManager.screenTranslationToolbarAction(for: shortcutAction)
        } else if isDedicatedOCRPin {
            action = shortcutAction == .copyRecognizedText ? .copyText : nil
        } else {
            action = ToolShortcutManager.toolbarAction(for: shortcutAction)
        }
        guard let action, pinToolbarContains(action) else { return }
        handlePinToolbarAction(action)
    }

    private func pinToolbarContains(_ action: ToolbarButtonAction) -> Bool {
        let displayed = [toolbarBottomStrip, toolbarMoreStrip].contains { strip in
            strip?.buttonViews.contains {
                $0.isEnabled && toolbarActionsMatch($0.action, action)
            } == true
        }
        if translationSession != nil || isDedicatedOCRPin {
            return toolbarPanel?.isVisible == true && displayed
        }
        guard !displayed, !isTransparentAnnotationPin else { return displayed }

        // Normal Pins keep More Tools collapsed most of the time, but their
        // configured drawing shortcuts must still work. Dedicated OCR and
        // translation Pins deliberately stay stricter above: only an actual
        // button in their current compact toolbar may receive a shortcut.
        let pinShadowInPrimary = Self.isPinShadowToolInPrimary
        let secondaryButtons = pinToolbarSecondaryButtons(includePinShadow: !pinShadowInPrimary)
        var primaryButtons = ToolbarLayout.primaryOverlayButtons(
            selectedTool: currentToolbarTool,
            selectedColor: pinView?.currentAnnotationColor ?? Self.lastUsedToolbarColor,
            moreExpanded: isPinMoreToolsExpanded,
            hasMoreTools: !secondaryButtons.isEmpty,
            trailingAction: .confirm,
            canUndo: pinView?.canUndoHistory ?? false,
            canRedo: pinView?.canRedoHistory ?? false,
            isRecording: false
        )
        insertPrimaryPinOnlyButtons(into: &primaryButtons)
        insertPrimaryTextCopyButtonIfNeeded(into: &primaryButtons)
        return (primaryButtons + secondaryButtons).contains {
            $0.isEnabled && toolbarActionsMatch($0.action, action)
        }
    }

    private enum PinImageTransform {
        case flipHorizontal
        case flipVertical
        case rotateClockwise
    }

    private func transformPinImage(_ transform: PinImageTransform) {
        guard let pinView else { return }
        exitTextSelectionMode()
        if pinView.hasActiveAnnotationTool {
            pinView.confirmAnnotationEditing()
        }
        let source = pinView.outputImage()
        guard let transformed = Self.transformedImage(source, transform: transform) else { return }
        let oldBaseSize = baseVisualSize
        let newBaseSize: NSSize = {
            switch transform {
            case .flipHorizontal, .flipVertical:
                return oldBaseSize
            case .rotateClockwise:
                return NSSize(width: oldBaseSize.height, height: oldBaseSize.width)
            }
        }()
        let scale = max(0.01, visualFrame.width / max(oldBaseSize.width, 1))
        let center = NSPoint(x: visualFrame.midX, y: visualFrame.midY)
        image = transformed
        baseVisualSize = newBaseSize
        normalVisualFrame = NSRect(
            x: center.x - newBaseSize.width * scale / 2,
            y: center.y - newBaseSize.height * scale / 2,
            width: newBaseSize.width * scale,
            height: newBaseSize.height * scale
        )
        pinView.replaceContent(image: transformed, canvasSize: newBaseSize)
        if pinView.isCompactMode {
            pinView.isCompactMode = false
        }
        if let normalVisualFrame {
            applyVisualFrame(normalVisualFrame)
        }
        currentToolbarTool = .select
        pinView.setAnnotationTool(.select)
        rebuildPinToolbar()
    }

    private func copyPin() {
        ImageEncoder.copyToClipboard(pinView?.outputImage() ?? image)
    }

    #if !OFFLINE
    private func uploadPin() {
        let uploadImage = pinView?.outputImage() ?? image
        (NSApp.delegate as? AppDelegate)?.uploadImage(
            uploadImage,
            presentingWindow: window,
            onAccepted: { [weak self] in self?.hideToolbar(reason: .explicitAction) }
        )
    }
    #endif

    private func toggleTextSelectionMode() {
        if textSelectionSession.suspendsPinInteraction {
            exitTextSelectionMode()
            return
        }
        guard let pinView, !pinView.isCompactMode else { return }

        if let translationSession {
            let blocks: [RecognizedTextBlock]
            switch translationSession.displayMode {
            case .original:
                blocks = translationSession.selectableOriginalBlocks
            case .translated:
                blocks = translationSession.selectableTranslatedBlocks
            }
            activateKnownTextSelection(blocks: blocks, in: pinView)
            return
        }
        if isDedicatedOCRPin, !recognizedTextBlocks.isEmpty {
            preservesTextSelectionDuringPinDrag = true
            activateKnownTextSelection(blocks: recognizedTextBlocks, in: pinView)
            return
        }

        let token = textSelectionSession.beginLoading()
        preservesTextSelectionDuringPinDrag = true
        pinView.dismissPixelInspector()
        pinView.setTextSelectionInteractionSuspended(
            true,
            preservesDuringPinDrag: preservesTextSelectionDuringPinDrag
        )
        pinView.showStatusText(L("Recognizing Text…"), autoHide: false)
        updatePinToolbarButtonState()

        let snapshot = pinView.outputImage()
        guard let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            finishTextSelectionFailure(token: token, message: L("Text recognition failed"))
            return
        }

        VisionOCR.performStructuredTextRecognition(cgImage: cgImage) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let structuredResult) where !structuredResult.blocks.isEmpty:
                guard self.textSelectionSession.activate(ifCurrent: token), let pinView = self.pinView else { return }
                if self.isDedicatedOCRPin {
                    self.recognizedTextBlocks = structuredResult.blocks
                    self.recognizedTextContent = structuredResult.plainText
                }
                self.preservesTextSelectionDuringPinDrag = true
                self.selectableTextOverlay.configure(
                    blocks: structuredResult.blocks,
                    in: pinView.textSelectionImageRect)
                self.selectableTextOverlay.isHidden = false
                pinView.setTextSelectionInteractionSuspended(
                    true,
                    preservesDuringPinDrag: self.preservesTextSelectionDuringPinDrag
                )
                self.window?.makeKey()
                self.window?.makeFirstResponder(self.selectableTextOverlay)
                pinView.hideStatusText()
                self.updatePinToolbarButtonState()
            case .success:
                self.finishTextSelectionFailure(token: token, message: L("No text found"))
            case .failure:
                self.finishTextSelectionFailure(token: token, message: L("Text recognition failed"))
            }
        }
    }

    /// Public workflow entry used by selectable OCR capture after creating a normal pin.
    func beginTextSelectionMode(
        blocks: [RecognizedTextBlock]? = nil,
        dedicatedOCR: Bool = false
    ) {
        guard !textSelectionSession.suspendsPinInteraction else { return }
        guard let pinView else { return }
        if dedicatedOCR, translationSession == nil {
            isDedicatedOCRPin = true
            preservesTextSelectionDuringPinDrag = true
            rebuildPinToolbar()
        }
        if let blocks, !blocks.isEmpty {
            if translationSession == nil {
                isDedicatedOCRPin = true
                recognizedTextBlocks = blocks
                recognizedTextContent = StructuredOCRResult(blocks: blocks).plainText
            }
            preservesTextSelectionDuringPinDrag = true
            activateKnownTextSelection(blocks: blocks, in: pinView)
        } else {
            preservesTextSelectionDuringPinDrag = dedicatedOCR
            toggleTextSelectionMode()
        }
    }

    func restoreDedicatedOCRIdentity(blocks: [RecognizedTextBlock]) {
        guard translationSession == nil, !blocks.isEmpty else { return }
        isDedicatedOCRPin = true
        recognizedTextBlocks = blocks
        recognizedTextContent = StructuredOCRResult(blocks: blocks).plainText
        rebuildPinToolbar()
    }

    private func copyTextToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pinView?.showStatusText(L("Text copied"))
    }

    private func activateKnownTextSelection(blocks: [RecognizedTextBlock], in pinView: PinView) {
        guard !blocks.isEmpty else {
            pinView.showStatusText(L("No text found"))
            return
        }
        let token = textSelectionSession.beginLoading()
        guard textSelectionSession.activate(ifCurrent: token) else { return }
        pinView.dismissPixelInspector()
        selectableTextOverlay.configure(blocks: blocks, in: pinView.textSelectionImageRect)
        selectableTextOverlay.isHidden = false
        pinView.setTextSelectionInteractionSuspended(
            true,
            preservesDuringPinDrag: preservesTextSelectionDuringPinDrag
        )
        window?.makeKey()
        window?.makeFirstResponder(selectableTextOverlay)
        updatePinToolbarButtonState()
    }

    private func toggleTranslationPinDisplay() {
        guard var session = translationSession, let pinView else { return }
        exitTextSelectionMode(rebuildToolbar: false)
        session.displayMode = session.displayMode == .original ? .translated : .original
        translationSession = session
        image = session.displayMode == .original ? session.originalImage : session.translatedImage
        textContent = session.displayMode == .original ? session.originalText : session.translatedText
        pinView.replaceBaseImagePreservingAnnotations(image)
        rebuildPinToolbar()
    }

    private func openTranslationPinLanguageWindow() {
        guard let session = translationSession else { return }
        (NSApp.delegate as? AppDelegate)?.openTranslationWindow(
            sourceText: session.originalText,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage)
    }

    private func finishTextSelectionFailure(token: Int, message: String) {
        guard textSelectionSession.fail(ifCurrent: token) else { return }
        selectableTextOverlay.clear()
        selectableTextOverlay.isHidden = true
        pinView?.hideStatusText()
        pinView?.setTextSelectionInteractionSuspended(false)
        pinView?.showStatusText(message)
        updatePinToolbarButtonState()
    }

    private func exitTextSelectionMode(rebuildToolbar: Bool = true) {
        let wasSuspended = textSelectionSession.suspendsPinInteraction
        let overlayOwnedFirstResponder = selectableTextOverlay.ownsFirstResponder(in: window)
        textSelectionSession.exit()
        preservesTextSelectionDuringPinDrag = false
        selectableTextOverlay.clear()
        selectableTextOverlay.isHidden = true
        pinView?.hideStatusText()
        pinView?.setTextSelectionInteractionSuspended(false)
        if wasSuspended, overlayOwnedFirstResponder {
            window?.makeFirstResponder(pinView)
        }
        if rebuildToolbar { updatePinToolbarButtonState() }
    }

    private static func transformedImage(_ image: NSImage, transform: PinImageTransform) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let targetPixelSize: CGSize
        let targetPointSize: CGSize
        switch transform {
        case .flipHorizontal, .flipVertical:
            targetPixelSize = CGSize(width: width, height: height)
            targetPointSize = image.size
        case .rotateClockwise:
            targetPixelSize = CGSize(width: height, height: width)
            targetPointSize = CGSize(width: image.size.height, height: image.size.width)
        }
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(targetPixelSize.width),
            height: Int(targetPixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        switch transform {
        case .flipHorizontal:
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .flipVertical:
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .rotateClockwise:
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: targetPointSize)
    }

    private func positionToolbar() {
        guard let toolbarPanel,
              let contentView = toolbarPanel.contentView,
              let bottomStrip = toolbarBottomStrip,
              let moreStrip = toolbarMoreStrip
        else { return }
        let screenFrame = screenFrame(containing: NSPoint(x: visualFrame.maxX, y: visualFrame.minY)).visibleFrame
        let bottomSize = bottomStrip.frame.size
        var optionsSize: CGSize?
        if let optionsRow = toolbarOptionsRow, !optionsRow.isHidden {
            optionsRow.frame.size.width = max(bottomSize.width, optionsRow.contentWidth)
            optionsSize = optionsRow.frame.size
        }
        let reservedOptionsSize: CGSize? = optionsSize == nil
            ? CGSize(width: max(bottomSize.width, 300), height: 34)
            : nil
        let frames = OverlayToolbarGeometry.frames(
            anchorRect: visualFrame,
            containerBounds: screenFrame,
            mainSize: bottomSize,
            moreSize: moreStrip.isHidden ? nil : moreStrip.frame.size,
            optionsSize: optionsSize,
            reservedOptionsSize: reservedOptionsSize,
            gap: 10,
            inset: 6
        )
        let tooltipFrame = pinToolbarTooltipFrame(
            mainFrame: frames.mainFrame,
            moreFrame: frames.moreFrame,
            stackFrame: frames.stackFrame,
            containerBounds: screenFrame
        )
        let panelFrame = tooltipFrame.map { frames.stackFrame.union($0) } ?? frames.stackFrame
        toolbarPanel.setFrame(panelFrame, display: true)
        contentView.frame = NSRect(origin: .zero, size: panelFrame.size)
        bottomStrip.frame.origin = NSPoint(
            x: frames.mainFrame.minX - panelFrame.minX,
            y: frames.mainFrame.minY - panelFrame.minY
        )
        if let moreFrame = frames.moreFrame, !moreStrip.isHidden {
            moreStrip.frame.origin = NSPoint(
                x: moreFrame.minX - panelFrame.minX,
                y: moreFrame.minY - panelFrame.minY
            )
        }
        if let optionsFrame = frames.optionsFrame, let optionsRow = toolbarOptionsRow, !optionsRow.isHidden {
            optionsRow.frame.origin = NSPoint(
                x: optionsFrame.minX - panelFrame.minX,
                y: optionsFrame.minY - panelFrame.minY
            )
        }
        if let tooltipFrame, let tooltipView = toolbarTooltipView {
            tooltipView.frame = NSRect(
                x: tooltipFrame.minX - panelFrame.minX,
                y: tooltipFrame.minY - panelFrame.minY,
                width: tooltipFrame.width,
                height: tooltipFrame.height
            )
            tooltipView.isHidden = false
        } else {
            toolbarTooltipView?.isHidden = true
        }
        os_log(
            "toolbar position visual=(%.1f,%.1f %.1fx%.1f) toolbar=(%.1f,%.1f %.1fx%.1f)",
            log: pinToolbarLog,
            type: .info,
            Double(visualFrame.origin.x),
            Double(visualFrame.origin.y),
            Double(visualFrame.width),
            Double(visualFrame.height),
            Double(panelFrame.origin.x),
            Double(panelFrame.origin.y),
            Double(panelFrame.width),
            Double(panelFrame.height)
        )
    }

    /// Uses the same placement policy as the selection toolbar, but keeps the
    /// label in the Pin toolbar's existing panel so entering or leaving a
    /// button never has to order a second floating window.
    private func pinToolbarTooltipFrame(
        mainFrame: NSRect,
        moreFrame: NSRect?,
        stackFrame: NSRect,
        containerBounds: NSRect
    ) -> NSRect? {
        guard let text = toolbarTooltipText,
              !text.isEmpty,
              let anchor = toolbarTooltipAnchor,
              toolbarTooltipView?.isHidden == false
        else { return nil }

        let anchorFrame: NSRect
        if anchor.superview === toolbarBottomStrip {
            anchorFrame = anchor.frame.offsetBy(dx: mainFrame.minX, dy: mainFrame.minY)
        } else if anchor.superview === toolbarMoreStrip, let moreFrame {
            anchorFrame = anchor.frame.offsetBy(dx: moreFrame.minX, dy: moreFrame.minY)
        } else {
            return nil
        }
        let textSize = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        return OverlayToolbarGeometry.tooltipFrame(
            buttonFrame: anchorFrame,
            stackFrame: stackFrame,
            tooltipSize: NSSize(width: ceil(textSize.width) + 18, height: 24),
            containerBounds: containerBounds,
            gap: 6,
            inset: 4
        )
    }

    private func hideToolbar(reason: PinToolbarHideReason = .explicitAction) {
        os_log("toolbar hide", log: pinToolbarLog, type: .info)
        if PinGeometry.toolbarHideAction(reason: reason) == .hideAndCancelTool {
            externalMeasureDrag = nil
            currentToolbarTool = .select
            pinView?.setAnnotationTool(.select)
            pinView?.clearAnnotationSelection()
        }
        hidePinToolbarTooltip()
        toolbarPanel?.orderOut(nil)
    }

    private func savePin() {
        hideToolbar(reason: .explicitAction)
        ImageSaveService.showSavePanel(
            imageProvider: { [weak self] in
                let start = CFAbsoluteTimeGetCurrent()
                let image = self?.pinView?.outputImage() ?? self?.image
                os_log(
                    "pin image provider elapsed=%.3f success=%{public}@",
                    log: pinToolbarLog,
                    type: .info,
                    CFAbsoluteTimeGetCurrent() - start,
                    image == nil ? "false" : "true"
                )
                return image
            },
            panelLevel: .screenSaver
        )
    }

    private func screenFrame(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static var lastUsedToolbarColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "lastUsedColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return .systemRed
    }

    private static func defaultVisualSize(for image: NSImage, on screen: NSScreen) -> NSSize {
        let imageSize = image.size
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return imageSize
        }

        let scale = max(screen.backingScaleFactor, 1)
        let pixelSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let imageSizeLooksLikePixels =
            abs(imageSize.width - pixelSize.width) < 1
            && abs(imageSize.height - pixelSize.height) < 1

        if scale > 1, imageSizeLooksLikePixels {
            return NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        }
        return imageSize
    }

    func show() {
        show(passively: false)
    }

    func show(passively: Bool) {
        window?.orderFrontRegardless()
        updatePinViewDisplayFrame()
        if !passively {
            window?.makeKey()
            if let pinView {
                window?.makeFirstResponder(pinView)
            }
        }
        if !didLogInitialPlacement {
            didLogInitialPlacement = true
            DispatchQueue.main.async { [weak self] in
                self?.appendInitialPlacementDiagnostic()
            }
        }
    }

    /// Observes the settled WindowServer frame without feeding it back into
    /// geometry, so diagnostics can never cause placement drift.
    private func appendInitialPlacementDiagnostic() {
        guard DiagnosticLogStore.isEnabled, let window else { return }

        let requestedWindow = Self.windowFrame(forVisualFrame: visualFrame)
        let actualWindow = window.frame
        let actualVisual = PinGeometry.visualFrame(
            fromWindowFrame: actualWindow,
            shadowOutset: Self.shadowOutset
        )
        let imagePixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map {
            "\($0.width)x\($0.height)"
        } ?? "none"
        let screenScale = window.screen?.backingScaleFactor ?? 0

        DiagnosticLogStore.append(
            "pin placement output requestedVisual=\(visualFrame.debugDescription) "
                + "requestedWindow=\(requestedWindow.debugDescription) "
                + "actualWindow=\(actualWindow.debugDescription) "
                + "actualVisual=\(actualVisual.debugDescription) "
                + "windowScale=\(screenScale) imageSize=\(image.size.debugDescription) "
                + "imagePixels=\(imagePixels)"
        )
    }

    func setTemporarilyHidden(_ hidden: Bool) {
        isTemporarilyHidden = hidden
        if hidden {
            exitTextSelectionMode()
            setSelected(false)
            hideToolbar(reason: .explicitAction)
            pinView?.dismissPixelInspector()
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func close() {
        exitTextSelectionMode(rebuildToolbar: false)
        hideToolbar(reason: .explicitAction)
        pinView?.dismissPixelInspector()
        toolbarTooltipView?.removeFromSuperview()
        toolbarTooltipView = nil
        toolbarTooltipAnchor = nil
        toolbarTooltipText = nil
        removeMonitors()
        window?.orderOut(nil)
        window?.close()
        window = nil
        pinView = nil
        delegate?.pinWindowDidClose(self)
    }
}

@MainActor
private final class PinEventRouter {
    static let shared = PinEventRouter()

    private final class Registration {
        weak var controller: PinWindowController?

        init(_ controller: PinWindowController) {
            self.controller = controller
        }
    }

    private var registrations: [Registration] = []
    private var persistentLocalMonitor: Any?
    private var persistentGlobalMonitor: Any?
    private var movementLocalMonitor: Any?
    private var movementGlobalMonitor: Any?

    /// AppKit invokes local monitors synchronously on the main thread. Box the
    /// callback value before entering the Swift 6 Sendable closure boundary.
    private final class MainThreadEventBox: @unchecked Sendable {
        let value: NSEvent
        var routedValue: NSEvent?

        init(value: NSEvent) {
            self.value = value
        }
    }

    private let persistentEventMask: NSEvent.EventTypeMask = [
        .beginGesture, .endGesture, .gesture, .magnify,
        .scrollWheel,
        .leftMouseDragged, .rightMouseDragged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown,
        .flagsChanged
    ]
    private let movementEventMask: NSEvent.EventTypeMask = [.mouseMoved]

    func register(_ controller: PinWindowController) {
        registrations.removeAll { $0.controller == nil || $0.controller === controller }
        registrations.append(Registration(controller))
        installMonitorsIfNeeded()
        refreshMovementMonitors()
    }

    func unregister(_ controller: PinWindowController) {
        registrations.removeAll { $0.controller == nil || $0.controller === controller }
        if registrations.isEmpty {
            removeMonitors()
        } else {
            refreshMovementMonitors()
        }
    }

    private func installMonitorsIfNeeded() {
        guard persistentLocalMonitor == nil, persistentGlobalMonitor == nil else { return }

        persistentLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: persistentEventMask) { [weak self] event in
            dispatchPrecondition(condition: .onQueue(.main))
            let box = MainThreadEventBox(value: event)
            MainActor.assumeIsolated {
                box.routedValue = self?.routeLocal(box.value) ?? box.value
            }
            return box.routedValue ?? event
        }
        persistentGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: persistentEventMask) { [weak self] event in
            Task { @MainActor in
                self?.routeGlobal(event)
            }
        }
    }

    private func refreshMovementMonitors() {
        guard liveControllers().contains(where: \.needsRoutedMouseMovement) else {
            removeMovementMonitors()
            return
        }
        guard movementLocalMonitor == nil, movementGlobalMonitor == nil else { return }

        movementLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: movementEventMask) { [weak self] event in
            dispatchPrecondition(condition: .onQueue(.main))
            let box = MainThreadEventBox(value: event)
            MainActor.assumeIsolated {
                box.routedValue = self?.routeLocal(box.value) ?? box.value
            }
            return box.routedValue ?? event
        }
        movementGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: movementEventMask) { [weak self] event in
            Task { @MainActor in
                self?.routeGlobal(event)
            }
        }
    }

    private func removeMovementMonitors() {
        if let movementLocalMonitor {
            NSEvent.removeMonitor(movementLocalMonitor)
            self.movementLocalMonitor = nil
        }
        if let movementGlobalMonitor {
            NSEvent.removeMonitor(movementGlobalMonitor)
            self.movementGlobalMonitor = nil
        }
    }

    private func removeMonitors() {
        if let persistentLocalMonitor {
            NSEvent.removeMonitor(persistentLocalMonitor)
            self.persistentLocalMonitor = nil
        }
        if let persistentGlobalMonitor {
            NSEvent.removeMonitor(persistentGlobalMonitor)
            self.persistentGlobalMonitor = nil
        }
        removeMovementMonitors()
    }

    private func liveControllers() -> [PinWindowController] {
        registrations.removeAll { $0.controller == nil }
        if registrations.isEmpty {
            removeMonitors()
            return []
        }
        return registrations.compactMap(\.controller).filter(\.isRoutable)
    }

    private func frontmostTargets() -> [PinWindowController] {
        let ordered = NSApp.orderedWindows
        let ranks = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.windowNumber, $0.offset) })
        return liveControllers().sorted { lhs, rhs in
            let left = lhs.routingWindow.flatMap { ranks[$0.windowNumber] } ?? Int.max
            let right = rhs.routingWindow.flatMap { ranks[$0.windowNumber] } ?? Int.max
            if left != right { return left < right }
            // Ordered windows can omit non-key floating panels while an app is
            // inactive. Key/main state is the next closest system z-order hint.
            let leftKey = lhs.routingWindow?.isKeyWindow == true || lhs.routingWindow?.isMainWindow == true
            let rightKey = rhs.routingWindow?.isKeyWindow == true || rhs.routingWindow?.isMainWindow == true
            return leftKey && !rightKey
        }
    }

    private func target(for event: NSEvent, screenPoint: NSPoint, isLocal: Bool) -> PinWindowController? {
        let controllers = frontmostTargets()
        if isLocal, let eventWindow = event.window,
           let exact = controllers.first(where: { $0.routingWindow === eventWindow || $0.routingToolbarWindow === eventWindow }) {
            return exact
        }
        // Keep a pinch/wheel session bound to its original pin even after the
        // image moves away from the mouse as it shrinks.
        if let locked = controllers.first(where: \.hasLockedZoomSession) {
            return locked
        }
        return controllers.first { $0.canRoutePointerEvent(at: screenPoint) }
    }

    private func routeActiveMouseMovement(at screenPoint: NSPoint) {
        liveControllers().filter(\.needsRoutedMouseMovement).forEach {
            $0.routeMouseMove(at: screenPoint)
        }
    }

    private func routeLocal(_ event: NSEvent) -> NSEvent? {
        route(event: event, isLocal: true)
    }

    private func route(event: NSEvent, isLocal: Bool) -> NSEvent? {
        defer { refreshMovementMonitors() }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            target(for: event, screenPoint: screenPoint, isLocal: isLocal)?.routeMouseDown(at: screenPoint)
        case .scrollWheel:
            guard let target = target(for: event, screenPoint: screenPoint, isLocal: isLocal) else { return event }
            return target.routeScroll(event) ? nil : event
        case .beginGesture, .endGesture, .gesture, .magnify:
            guard let target = target(for: event, screenPoint: screenPoint, isLocal: isLocal) else { return event }
            return target.routeGesture(event) ? nil : event
        case .mouseMoved, .rightMouseDragged:
            routeActiveMouseMovement(at: screenPoint)
        case .leftMouseDragged:
            target(for: event, screenPoint: screenPoint, isLocal: isLocal)?
                .routeMouseDrag(at: screenPoint, modifierFlags: event.modifierFlags)
            routeActiveMouseMovement(at: screenPoint)
        case .leftMouseUp:
            target(for: event, screenPoint: screenPoint, isLocal: isLocal)?.finishExternalMeasureDrag()
        case .flagsChanged:
            target(for: event, screenPoint: screenPoint, isLocal: isLocal)?.routeFlags(event, at: screenPoint)
        default:
            break
        }
        return event
    }

    private func routeGlobal(_ event: NSEvent) {
        _ = route(event: event, isLocal: false)
    }
}

private class PinPanel: NSPanel {
    var onToolbarShortcut: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (contentView as? PinView)?.handleTextSelectionKeyEquivalent(event) == true { return true }
        if let textView = firstResponder as? NSTextView,
           NativeTextCommandRouter.handle(event, in: textView) {
            return true
        }
        if onToolbarShortcut?(event) == true { return true }
        if event.modifierFlags.contains(.command) {
            switch PinGeometry.commandShortcutAction(keyCode: event.keyCode) {
            case .save:
                (contentView as? PinView)?.onSave?()
                return true
            case .copy:
                if let pinView = contentView as? PinView {
                    ImageEncoder.copyToClipboard(pinView.outputImage())
                    return true
                }
            case .close:
                (contentView as? PinView)?.onClose?()
                return true
            case .passThrough:
                break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if (contentView as? PinView)?.isTextSelectionInteractionSuspended == true { return true }
            (contentView as? PinView)?.onConfirmAnnotation?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onToolbarShortcut?(event) == true { return }
        super.keyDown(with: event)
    }
}

private class PinToolbarPanel: NSPanel {
    var onConfirm: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onToolbarShortcut: ((NSEvent) -> Bool)?
    var onExitTextSelection: (() -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, onExitTextSelection?() == true {
            return true
        }
        if onKeyEquivalent?(event) == true { return true }
        if onToolbarShortcut?(event) == true { return true }
        if event.modifierFlags.contains(.command) {
            switch PinGeometry.commandShortcutAction(keyCode: event.keyCode) {
            case .save:
                onSave?()
                return true
            case .copy:
                onCopy?()
                return true
            case .close:
                return false
            case .passThrough:
                break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onConfirm?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onExitTextSelection?() == true {
            return
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onConfirm?()
        } else if onToolbarShortcut?(event) == true {
            return
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class PinToolbarTooltipView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    /// The label is visual chrome only. It must not steal the toolbar button's
    /// mouse tracking or turn a hover into a panel-to-panel transition.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

/// Shared editable annotation canvas for image Pins and transparent annotation sessions.
/// The caller owns the visual base; this view only owns annotation interaction and text editing.
class PinCanvasView: EditorView, AnnotationSourceImageProviding {

    var onShowPinToolbar: ((NSPoint) -> Void)?
    var onPinContentChanged: (() -> Void)?
    var onConfirmPinAnnotation: (() -> Void)?
    var onToolbarShortcut: ((ToolShortcutManager.Action) -> Void)?

    private var baseImage: NSImage
    private var canvasSize: NSSize
    private var customPinColors: [NSColor?] = PinCanvasView.loadCustomColors()
    private var selectedPinColorSlot: Int = 0

    var onSelectPin: (() -> Void)?
    var isPreviewOnly = false
    var isToolActive: Bool {
        currentTool != .select
    }
    override var allowsMeasureSnapGuides: Bool { false }

    var hasPinAnnotations: Bool {
        !annotations.isEmpty
    }

    func hasEditableText(at point: NSPoint) -> Bool {
        annotations.reversed().contains {
            $0.tool == .text && $0.hitTest(point: point)
        }
    }

    init(image: NSImage, canvasSize: NSSize) {
        self.baseImage = image
        self.canvasSize = canvasSize
        super.init(frame: NSRect(origin: .zero, size: canvasSize))
        frame = NSRect(origin: .zero, size: canvasSize)
        bounds = NSRect(origin: .zero, size: canvasSize)
        screenshotImage = image
        captureSourceImage = image
        applySelection(NSRect(origin: .zero, size: canvasSize))
        // Pins use a stable base image owned by PinView. Keep the inherited
        // editor preview paths neutral so this child remains annotation-only.
        beautifyEnabled = false
        effectsPreset = .none
        effectsBrightness = 0
        effectsContrast = 1
        effectsSaturation = 1
        effectsSharpness = 0
        showToolbars = false
        currentTool = .select
        autoresizingMask = []
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        hidesDrawingCursorPreview = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDisplayFrame(_ displayFrame: NSRect) {
        frame = displayFrame
        bounds = NSRect(origin: .zero, size: canvasSize)
        layer?.masksToBounds = true
        showToolbars = false
        needsDisplay = true
    }

    func setPinTool(_ tool: AnnotationTool) {
        if currentTool == .text, tool != .text, textEditor.isEditing {
            commitTextFieldIfNeeded()
        }
        if tool != .select {
            clearAnnotationSelectionForExternalToolbar()
        }
        currentTool = tool
        showToolbars = false
        needsDisplay = true
    }

    func setPinPixelInspectorActive(_ active: Bool) {
        hidesDrawingCursorPreview = active
        if active {
            drawingCursorPoint = .zero
        }
        needsDisplay = true
    }

    func attachPinToolOptionsRow(_ row: ToolOptionsRowView?) {
        attachExternalToolOptionsRow(row)
    }

    func configurePinToolOptionsRow(_ row: ToolOptionsRowView, fallbackTool: AnnotationTool) {
        configureExternalToolOptionsRow(row, fallbackTool: fallbackTool)
    }

    var hasPinAnnotationSelection: Bool {
        hasAnnotationSelectionForExternalToolbar
    }

    func clearPinAnnotationSelection() {
        clearAnnotationSelectionForExternalToolbar()
    }

    func renderPinImage() -> NSImage {
        compositedImage() ?? baseImage
    }

    func annotationSourceImageForLoupe(at point: NSPoint) -> (image: NSImage, bounds: NSRect)? {
        guard isPreviewOnly else { return nil }
        let cropRect = NSRect(origin: .zero, size: canvasSize)
        let sourceAnnotations = annotations.filter { $0.tool != .loupe }
        guard let image = TransparentAnnotationGeometry.renderOutputImage(
            annotations: sourceAnnotations,
            cropRect: cropRect
        ) else { return nil }
        return (image, cropRect)
    }

    /// Cloning an Annotation intentionally releases its large source image.
    /// Transparent Pins have no bitmap base to fall back to, so recreate every
    /// existing loupe from the vector layer once the Pin installs its payload.
    func refreshTransparentLoupeSources() {
        guard let source = transparentLoupeSourceImage() else { return }
        for annotation in annotations where annotation.tool == .loupe {
            annotation.sourceImage = source.image
            annotation.sourceImageBounds = source.bounds
            annotation.bakedBlurNSImage = nil
            annotation.bakeLoupe()
        }
    }

    private func transparentLoupeSourceImage() -> (image: NSImage, bounds: NSRect)? {
        guard isPreviewOnly else { return nil }
        let cropRect = NSRect(origin: .zero, size: canvasSize)
        let sourceAnnotations = annotations.filter { $0.tool != .loupe }
        guard let image = TransparentAnnotationGeometry.renderOutputImage(
            annotations: sourceAnnotations,
            cropRect: cropRect
        ) else { return nil }
        return (image, cropRect)
    }

    /// Held pixel inspection follows the same source-only contract as the
    /// capture overlay. It must not synchronously render all pin annotations
    /// from an Option-key input event.
    func pixelInspectorSourceImage() -> NSImage {
        baseImage
    }

    func replaceBaseImagePreservingAnnotations(_ image: NSImage) {
        baseImage = image
        screenshotImage = image
        captureSourceImage = image
        needsDisplay = true
    }

    func undoPinAnnotation() {
        undo()
        showToolbars = false
        onPinContentChanged?()
    }

    func redoPinAnnotation() {
        redo()
        showToolbars = false
        onPinContentChanged?()
    }

    func confirmPinAnnotationEditing() {
        confirmAnnotationEditing()
        showToolbars = false
        onPinContentChanged?()
    }

    func showPinColorPicker(anchorView: NSView?, onChange: @escaping () -> Void) {
        let picker = ColorPickerView()
        picker.setColor(currentColor, opacity: currentColorOpacity)
        picker.customColors = customPinColors
        picker.selectedColorSlot = selectedPinColorSlot
        picker.onColorChanged = { [weak self, weak picker] color in
            guard let self else { return }
            self.currentColor = color
            self.applyCurrentColorToSelectedAnnotationsForExternalToolbar()
            picker?.saveToSelectedSlot(color)
            self.needsDisplay = true
            onChange()
        }
        picker.onOpacityChanged = { [weak self] opacity in
            guard let self else { return }
            self.currentColorOpacity = opacity
            UserDefaults.standard.set(Double(opacity), forKey: "lastUsedColorOpacity")
            self.applyCurrentColorToSelectedAnnotationsForExternalToolbar()
            self.needsDisplay = true
            onChange()
        }
        picker.onCustomSlotSelected = { [weak self] index in
            self?.selectedPinColorSlot = index
        }
        picker.onCustomColorsChanged = { [weak self] colors in
            self?.customPinColors = colors
            PinCanvasView.saveCustomColors(colors)
        }

        let size = picker.preferredSize
        if let anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker,
                size: size,
                at: NSPoint(x: bounds.midX, y: bounds.midY),
                in: self,
                preferredEdge: .minY
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        showToolbars = false
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        showToolbars = false
    }

    /// PinView owns the stable screenshot pixels. The child canvas redraws only
    /// committed annotations and the active stroke.
    override func drawEditorBackground(context: NSGraphicsContext) {
        drewFromCompositeCache = false
    }

    override func shouldDrawAnnotationsLiveDuringManipulation() -> Bool { true }

    override func invalidateLiveAnnotationSegment(
        from start: NSPoint,
        to end: NSPoint,
        effectiveWidth: CGFloat
    ) {
        let dirtyRect = FreeformLiveRenderGeometry.dirtyRect(
            from: start,
            to: end,
            effectiveWidth: effectiveWidth
        ).intersection(bounds)
        if !dirtyRect.isEmpty {
            setNeedsDisplay(dirtyRect)
        }
    }

    override func liveFreeformClipRect(for dirtyRect: NSRect) -> NSRect? {
        dirtyRect
    }

    private func notifyPinAttributeChangeIfNeeded() {
        guard currentTool == .colorSampler else { return }
        onPinContentChanged?()
    }

    override func mouseMoved(with event: NSEvent) {
        if isPreviewOnly {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isPreviewOnly {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPreviewOnly else { return }
        onSelectPin?()
        guard isToolActive else {
            super.mouseDown(with: event)
            return
        }
        showToolbars = false
        super.mouseDown(with: event)
        showToolbars = false
        notifyPinAttributeChangeIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isPreviewOnly else { return }
        guard isToolActive else {
            super.mouseDragged(with: event)
            return
        }
        showToolbars = false
        super.mouseDragged(with: event)
        showToolbars = false
    }

    override func mouseUp(with event: NSEvent) {
        guard !isPreviewOnly else { return }
        guard isToolActive else {
            super.mouseUp(with: event)
            return
        }
        showToolbars = false
        super.mouseUp(with: event)
        showToolbars = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isPreviewOnly else { return }
        onShowPinToolbar?(screenPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        guard !isPreviewOnly else { return }
        if let action = ToolShortcutManager.action(for: event) {
            onToolbarShortcut?(action)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onConfirmPinAnnotation?()
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        superview?.magnify(with: event)
    }

    override func beginGesture(with event: NSEvent) {
        superview?.beginGesture(with: event)
    }

    override func endGesture(with event: NSEvent) {
        superview?.endGesture(with: event)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private static func loadCustomColors() -> [NSColor?] {
        guard let hexArray = UserDefaults.standard.array(forKey: "customColors") as? [String] else {
            return Array(repeating: nil, count: 7)
        }
        var colors = hexArray.prefix(7).map { hex -> NSColor? in
            guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
            return NSColor(
                calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        while colors.count < 7 {
            colors.append(nil)
        }
        return colors
    }

    private static func saveCustomColors(_ colors: [NSColor?]) {
        let hexArray = colors.map { color -> String in
            guard let rgb = color?.usingColorSpace(.deviceRGB) else { return "" }
            return String(
                format: "%02X%02X%02X",
                Int(round(rgb.redComponent * 255)),
                Int(round(rgb.greenComponent * 255)),
                Int(round(rgb.blueComponent * 255))
            )
        }
        UserDefaults.standard.set(hexArray, forKey: "customColors")
    }
}

private final class PinHUDLabelView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSColor(calibratedWhite: 0, alpha: 0.68).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(
                x: bounds.minX,
                y: bounds.midY - textSize.height / 2,
                width: bounds.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }
}

private class PinView: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onPreviewHover: ((NSPoint) -> Void)?
    var onToggleCompact: ((NSPoint) -> Void)?
    var onZoom: ((CGFloat, NSPoint, NSPoint?, Bool, NSEvent.Phase) -> Void)?
    var onZoomPhase: ((NSPoint, NSEvent.Phase) -> Void)?
    var onOpacityChange: ((CGFloat) -> Void)?
    var onDrag: ((NSPoint, NSEvent) -> Void)?
    var onNudge: ((NSPoint) -> Void)?
    var onShowToolbar: ((NSPoint) -> Void)?
    var onCanvasChanged: (() -> Void)?
    var onCanvasToolChanged: ((AnnotationTool) -> Void)?
    var onConfirmAnnotation: (() -> Void)?
    var onToolbarShortcut: ((ToolShortcutManager.Action) -> Void)?
    var onSave: (() -> Void)?
    var onExitTextSelection: (() -> Void)?

    private var image: NSImage
    private let shadowOutset: CGFloat
    private var canvasView: PinCanvasView
    private let isTransparentAnnotationContent: Bool
    var imageSize: NSSize { image.size }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var isCompactMode: Bool = false {
        didSet {
            canvasView.isHidden = isCompactMode
            needsLayout = true
            needsDisplay = true
        }
    }
    var compactCenter = NSPoint(x: 0.5, y: 0.5)
    var compactActualCenter = NSPoint(x: 0.5, y: 0.5)
    private var showsPartialImage: Bool {
        PinCompactDisplayPreference.showsPartialImage
    }
    private var shiftDoubleClickRecognizer = PinShiftDoubleClickRecognizer()
    private var zoomLabelTimer: Timer?
    private var pixelInspectorActive = false
    private var pixelInspectorHoldPolicy = PixelInspectorHoldPolicy()
    private var pixelInspectorShiftWasDown = false
    private var pixelInspectorPoint: NSPoint = .zero
    private var pixelInspectorMode: PixelInspectorDisplayMode = .hex
    private let pixelInspectorPanel = PixelInspectorPanelController()
    private var pixelInspectorImageCache: NSImage?
    private let hudLabel = PinHUDLabelView(frame: .zero)
    private var discreteWheelAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private weak var selectableTextOverlay: SelectableTextOverlayView?
    private(set) var isTextSelectionInteractionSuspended = false
    private var preservesTextSelectionDuringPinDrag = false
    private var cachedTransparentImageCornerRadius: CGFloat?
    private var displayFrameOverride: NSRect?
    private var imageRect: NSRect {
        displayFrameOverride ?? bounds.insetBy(dx: shadowOutset, dy: shadowOutset)
    }
    private var selectedChromeColor: NSColor { ToolbarLayout.accentColor }
    /// Independently captured windows keep transparent corners. Reuse their
    /// actual alpha inset for Pin chrome so the selected accent outline and the
    /// shadow never refill those corners as a rectangle.
    private var transparentImageCornerRadius: CGFloat {
        if let cachedTransparentImageCornerRadius {
            return cachedTransparentImageCornerRadius
        }
        let radius = measuredTransparentImageCornerRadius()
        cachedTransparentImageCornerRadius = radius
        return radius
    }

    private func measuredTransparentImageCornerRadius() -> CGFloat {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.bitsPerPixel == 32,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data)
        else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        let limit = max(1, min(width, height) / 2)
        let alphaInfo = cgImage.alphaInfo
        func alphaAt(x: Int, y: Int) -> UInt8? {
            let offset = y * cgImage.bytesPerRow + x * 4
            guard offset + 3 < CFDataGetLength(data) else { return nil }
            switch alphaInfo {
            case .premultipliedLast, .last:
                return bytes[offset + 3]
            case .premultipliedFirst, .first, .alphaOnly:
                return bytes[offset]
            case .none, .noneSkipFirst, .noneSkipLast:
                return nil
            @unknown default:
                return nil
            }
        }
        func opaqueInset(startX: Int, startY: Int, stepX: Int, stepY: Int) -> Int {
            for offset in 0..<limit {
                guard let alpha = alphaAt(
                    x: startX + offset * stepX,
                    y: startY + offset * stepY
                ) else { return 0 }
                if alpha > 8 { return offset }
            }
            return 0
        }

        let inset = min(
            opaqueInset(startX: 0, startY: 0, stepX: 1, stepY: 0),
            opaqueInset(startX: width - 1, startY: 0, stepX: -1, stepY: 0),
            opaqueInset(startX: 0, startY: height - 1, stepX: 1, stepY: 0),
            opaqueInset(startX: width - 1, startY: height - 1, stepX: -1, stepY: 0)
        )
        guard inset > 1 else { return 0 }
        let scale = min(
            imageRect.width / max(CGFloat(width), 1),
            imageRect.height / max(CGFloat(height), 1)
        )
        return min(CGFloat(inset) * scale, min(imageRect.width, imageRect.height) / 2)
    }
    private func chromePath(in rect: NSRect) -> NSBezierPath {
        let cornerRadius = transparentImageCornerRadius
        return cornerRadius > 0
            ? NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            : NSBezierPath(rect: rect)
    }
    private var shadowHidden = false {
        didSet { needsDisplay = true }
    }
    var isShadowHidden: Bool { shadowHidden }

    init(
        image: NSImage,
        shadowOutset: CGFloat,
        canvasSize: NSSize,
        isTransparentAnnotationContent: Bool = false
    ) {
        self.image = image
        self.shadowOutset = shadowOutset
        self.canvasView = PinCanvasView(image: image, canvasSize: canvasSize)
        self.isTransparentAnnotationContent = isTransparentAnnotationContent
        super.init(frame: .zero)
        canvasView.isPreviewOnly = isTransparentAnnotationContent
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
        addSubview(canvasView)
        hudLabel.isHidden = true
        hudLabel.alphaValue = 0
        addSubview(hudLabel, positioned: .above, relativeTo: canvasView)
        installCanvasCallbacks()
        addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnificationGesture(_:))
        ))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolbarColorsChanged),
            name: .toolbarColorsDidChange,
            object: nil
        )
    }

    private func installCanvasCallbacks() {
        canvasView.onSelectPin = { [weak self] in
            self?.onSelect?()
        }
        canvasView.onShowPinToolbar = { [weak self] screenPoint in
            self?.onSelect?()
            self?.onShowToolbar?(screenPoint)
        }
        canvasView.onPinContentChanged = { [weak self] in
            self?.pixelInspectorImageCache = nil
            self?.onCanvasChanged?()
        }
        canvasView.onContentChanged = { [weak self] in
            self?.pixelInspectorImageCache = nil
            self?.onCanvasChanged?()
        }
        canvasView.onConfirmPinAnnotation = { [weak self] in
            self?.onConfirmAnnotation?()
        }
        canvasView.onToolbarShortcut = { [weak self] action in
            self?.onToolbarShortcut?(action)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        zoomLabelTimer?.invalidate()
        pixelInspectorPanel.hide()
    }

    @objc private func handleToolbarColorsChanged() {
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        canvasView.isHidden = isCompactMode
        canvasView.setDisplayFrame(imageRect)
        selectableTextOverlay?.frame = imageRect
        hudLabel.frame = NSRect(
            x: imageRect.midX - 42,
            y: imageRect.maxY - 32,
            width: 84,
            height: 24
        )
    }

    func setDisplayFrame(_ frame: NSRect) {
        displayFrameOverride = frame
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        var options: NSTrackingArea.Options = [.cursorUpdate, .activeAlways, .inVisibleRect]
        if isTextSelectionInteractionSuspended {
            options.insert(.mouseMoved)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isTransparentAnnotationContent {
            addCursorRect(imageRect, cursor: .arrow)
            return
        }
        guard isTextSelectionInteractionSuspended else { return }
        addCursorRect(imageRect, cursor: AppCursor.move)
    }

    var currentAnnotationColor: NSColor {
        canvasView.currentColor
    }

    var isPixelInspectorActive: Bool {
        pixelInspectorActive
    }

    var annotationCanvasView: PinCanvasView {
        canvasView
    }

    func installTransparentAnnotations(_ annotations: [Annotation]) {
        canvasView.annotations = annotations
        canvasView.refreshTransparentLoupeSources()
        canvasView.needsDisplay = true
    }

    func configureToolOptionsRow(_ row: ToolOptionsRowView, fallbackTool: AnnotationTool) {
        canvasView.configurePinToolOptionsRow(row, fallbackTool: fallbackTool)
    }

    func replaceContent(image: NSImage, canvasSize: NSSize) {
        self.image = image
        cachedTransparentImageCornerRadius = nil
        canvasView.removeFromSuperview()
        canvasView = PinCanvasView(image: image, canvasSize: canvasSize)
        pixelInspectorImageCache = nil
        addSubview(canvasView)
        if let selectableTextOverlay {
            addSubview(selectableTextOverlay, positioned: .above, relativeTo: canvasView)
        }
        addSubview(hudLabel, positioned: .above, relativeTo: canvasView)
        installCanvasCallbacks()
        needsLayout = true
        needsDisplay = true
    }

    func replaceBaseImagePreservingAnnotations(_ image: NSImage) {
        self.image = image
        cachedTransparentImageCornerRadius = nil
        canvasView.replaceBaseImagePreservingAnnotations(image)
        pixelInspectorImageCache = nil
        needsDisplay = true
    }

    var hasAnnotations: Bool {
        canvasView.hasPinAnnotations
    }

    var hasActiveAnnotationTool: Bool {
        canvasView.isToolActive
    }

    var canUndoHistory: Bool {
        canvasView.canUndoHistory
    }

    var canRedoHistory: Bool {
        canvasView.canRedoHistory
    }

    func setAnnotationTool(_ tool: AnnotationTool) {
        canvasView.setPinTool(tool)
    }

    func clearAnnotationSelection() {
        canvasView.clearPinAnnotationSelection()
    }

    func showColorPicker(anchorView: NSView?, onChange: @escaping () -> Void) {
        canvasView.showPinColorPicker(anchorView: anchorView, onChange: onChange)
    }

    func undoAnnotation() {
        canvasView.undoPinAnnotation()
    }

    func redoAnnotation() {
        canvasView.redoPinAnnotation()
    }

    func outputImage() -> NSImage {
        canvasView.renderPinImage()
    }

    func confirmAnnotationEditing() {
        canvasView.confirmPinAnnotationEditing()
    }

    var textSelectionImageRect: NSRect { selectableTextOverlay?.bounds ?? imageRect }

    func attachSelectableTextOverlay(_ overlay: SelectableTextOverlayView) {
        selectableTextOverlay = overlay
        overlay.onExit = { [weak self] in self?.onExitTextSelection?() }
        overlay.onInteractionBegan = { [weak self] in
            self?.onSelect?()
        }
        overlay.frame = imageRect
        overlay.isHidden = true
        addSubview(overlay, positioned: .above, relativeTo: canvasView)
        addSubview(hudLabel, positioned: .above, relativeTo: overlay)
    }

    func setTextSelectionInteractionSuspended(
        _ suspended: Bool,
        preservesDuringPinDrag: Bool = false
    ) {
        isTextSelectionInteractionSuspended = suspended
        preservesTextSelectionDuringPinDrag = suspended && preservesDuringPinDrag
        if !suspended {
            selectableTextOverlay?.isHidden = true
        }
        window?.invalidateCursorRects(for: self)
        if let selectableTextOverlay {
            window?.invalidateCursorRects(for: selectableTextOverlay)
        }
        updateTrackingAreas()
    }

    func clearTextSelectionHighlights() {
        selectableTextOverlay?.clearSelectionHighlights()
    }

    func handleTextSelectionKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isTextSelectionInteractionSuspended else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }
        switch event.keyCode {
        case 0:
            selectableTextOverlay?.selectAllText()
            return true
        case 8:
            if selectableTextOverlay?.hasSelection == true {
                _ = selectableTextOverlay?.copySelection()
            } else {
                _ = selectableTextOverlay?.copyAllText()
            }
            return true
        default:
            return false
        }
    }

    func toggleShadowHidden() {
        shadowHidden.toggle()
    }

    func setShadowHidden(_ hidden: Bool) {
        shadowHidden = hidden
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return }

        if !shadowHidden {
            drawOuterShadow(in: rect)
        }

        if isCompactMode || canvasView.isHidden {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let displayImage = canvasView.renderPinImage()
            displayImage.draw(in: rect, from: sourceRect(), operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        if isCompactMode {
            drawCompactHighlight(in: rect)
        }

        if isSelected && !isCompactMode {
            selectedChromeColor.withAlphaComponent(0.75).setStroke()
            let border = chromePath(in: rect.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            border.stroke()
        }

        if !isCompactMode && !canvasView.isHidden {
            drawNormalBaseImage(in: rect)
        }
    }

    private func drawNormalBaseImage(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: rect, from: sourceRect(), operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawOuterShadow(in rect: NSRect) {
        let shadowPath = chromePath(in: rect)
        NSGraphicsContext.saveGraphicsState()
        let dropShadow = NSShadow()
        dropShadow.shadowBlurRadius = isSelected ? 20 : 16
        dropShadow.shadowOffset = .zero
        dropShadow.shadowColor = isSelected
            ? selectedChromeColor.withAlphaComponent(0.75)
            : NSColor(srgbRed: 0x4e / 255, green: 0x4e / 255, blue: 0x50 / 255, alpha: 0.82)
        dropShadow.set()
        NSColor.white.setFill()
        shadowPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        if isSelected {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowBlurRadius = isCompactMode ? 9 : 12
            glow.shadowOffset = .zero
            glow.shadowColor = selectedChromeColor.withAlphaComponent(0.65)
            glow.set()
            selectedChromeColor.withAlphaComponent(0.3).setStroke()
            let glowBorder = chromePath(in: rect.insetBy(dx: 0.5, dy: 0.5))
            glowBorder.lineWidth = isCompactMode ? 2 : 2.5
            glowBorder.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor(srgbRed: 0x4e / 255, green: 0x4e / 255, blue: 0x50 / 255, alpha: 0.95).setStroke()
            let border = chromePath(in: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = isCompactMode ? 1.2 : 0.8
            border.stroke()
        }
    }

    func showZoomPercentage(_ scale: CGFloat) {
        showStatusText(String(format: L("Size %d%%"), Int(round(scale * 100))))
    }

    func showOpacityPercentage(_ opacity: CGFloat) {
        showStatusText(String(format: L("Opacity %d%%"), Int(round(opacity * 100))))
    }

    func showStatusText(_ text: String, autoHide: Bool = true) {
        hudLabel.text = text
        hudLabel.alphaValue = 1
        hudLabel.isHidden = false
        zoomLabelTimer?.invalidate()
        guard autoHide else { return }
        zoomLabelTimer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: false) { [weak self] _ in
            self?.hideStatusText()
        }
    }

    func hideStatusText() {
        zoomLabelTimer?.invalidate()
        zoomLabelTimer = nil
        hudLabel.alphaValue = 0
        hudLabel.isHidden = true
    }

    private func drawCompactHighlight(in rect: NSRect) {
        let segment = max(10, min(rect.width, rect.height) * 0.42)
        let lineWidth: CGFloat = 2
        let inset = lineWidth / 2
        let minX = rect.minX + inset
        let maxX = rect.maxX - inset
        let minY = rect.minY + inset
        let maxY = rect.maxY - inset

        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 0.95
            )
        }

        func stroke(_ color: NSColor, _ points: [NSPoint]) {
            guard let first = points.first else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .square
            path.move(to: first)
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.stroke()
        }

        stroke(color(0x3C76F4), [
            NSPoint(x: minX, y: maxY - segment),
            NSPoint(x: minX, y: maxY),
            NSPoint(x: minX + segment, y: maxY),
        ])
        stroke(color(0xB4520B), [
            NSPoint(x: maxX - segment, y: maxY),
            NSPoint(x: maxX, y: maxY),
            NSPoint(x: maxX, y: maxY - segment),
        ])
        stroke(color(0x4ADE80), [
            NSPoint(x: maxX, y: minY + segment),
            NSPoint(x: maxX, y: minY),
            NSPoint(x: maxX - segment, y: minY),
        ])
        stroke(color(0xFDE047), [
            NSPoint(x: minX + segment, y: minY),
            NSPoint(x: minX, y: minY),
            NSPoint(x: minX, y: minY + segment),
        ])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPointer(at: point) else { return nil }
        if isTextSelectionInteractionSuspended {
            guard let overlay = selectableTextOverlay, !overlay.isHidden else { return self }
            return overlay.hitTest(convert(point, to: overlay)) ?? self
        }
        if !isCompactMode, canvasView.isToolActive {
            return super.hitTest(point)
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard acceptsPointer(at: loc) else { return }
        if isTransparentAnnotationContent {
            onPreviewHover?(screenPoint(forEvent: event))
            let isCompactClick = InteractionShortcutManager.matchesModifiers(
                event.modifierFlags,
                action: .compactPin,
                among: [.closePin, .compactPin]
            )
            let shouldToggleCompact = shiftDoubleClickRecognizer.shouldToggle(
                timestamp: event.timestamp,
                point: loc,
                clickCount: event.clickCount,
                isShift: isCompactClick,
                doubleClickInterval: NSEvent.doubleClickInterval
            )
            onSelect?()
            if shouldToggleCompact {
                onToggleCompact?(loc)
                return
            }
            if isCompactMode {
                onDrag?(loc, event)
            }
            return
        }
        if isTextSelectionInteractionSuspended {
            if InteractionShortcutManager.matchesModifiers(
                event.modifierFlags,
                action: .closePin,
                among: [.closePin, .compactPin]
            ), event.clickCount == 2 {
                onClose?()
                return
            }
            switch routeTextSelectionPointer(at: loc) {
            case .text:
                return
            case .exitSelection:
                if !preservesTextSelectionDuringPinDrag {
                    onExitTextSelection?()
                }
                fallthrough
            case .movePin:
                onSelect?()
                selectableTextOverlay?.clearSelectionHighlights()
                onDrag?(loc, event)
                return
            }
        }
        let isCompactClick = InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .compactPin, among: [.closePin, .compactPin])
        let shouldToggleCompact = shiftDoubleClickRecognizer.shouldToggle(
            timestamp: event.timestamp,
            point: loc,
            clickCount: event.clickCount,
            isShift: isCompactClick,
            doubleClickInterval: NSEvent.doubleClickInterval
        )

        onSelect?()
        if shouldToggleCompact {
            onToggleCompact?(loc)
            return
        }
        if InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .closePin, among: [.closePin, .compactPin]) && event.clickCount == 2 {
            onClose?()
            return
        }
        onDrag?(loc, event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isTransparentAnnotationContent {
            updateTransparentPreviewCursor()
        } else if isTextSelectionInteractionSuspended {
            updateTextSelectionCursor(at: loc)
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isTransparentAnnotationContent {
            updateTransparentPreviewCursor()
            onPreviewHover?(screenPoint(forEvent: event))
            return
        }
        super.mouseMoved(with: event)
        guard isTextSelectionInteractionSuspended else { return }
        updateTextSelectionCursor(at: point)
    }

    private func updateTransparentPreviewCursor() {
        if isCompactMode {
            AppCursor.move.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func updateTextSelectionCursor(at point: NSPoint) {
        guard isTextSelectionInteractionSuspended,
              let overlay = selectableTextOverlay,
              !overlay.isHidden
        else { return }
        if overlay.hitTest(convert(point, to: overlay)) != nil {
            NSCursor.iBeam.set()
        } else {
            AppCursor.move.set()
        }
    }

    private func routeTextSelectionPointer(at point: NSPoint) -> PinTextSelectionPointerRoute {
        let isText = selectableTextOverlay.map {
            !$0.isHidden && $0.hitTest(convert(point, to: $0)) != nil
        } ?? false
        return PinTextSelectionPointerGate.route(
            isText: isText,
            keepsOCRActive: preservesTextSelectionDuringPinDrag)
    }

    func updatePixelInspectorFromMouseMove(at point: NSPoint) {
        guard !isTextSelectionInteractionSuspended else { return }
        if pixelInspectorActive, isSelected, imageRect.contains(point), isOpaqueAt(point) {
            pixelInspectorPoint = point
            updatePixelInspectorPanel(at: point)
        } else if pixelInspectorActive {
            pixelInspectorPanel.hide()
        }
    }

    func measurementEntryPoint(from previousPoint: NSPoint, to currentPoint: NSPoint) -> NSPoint? {
        guard containsOpaqueImagePoint(currentPoint) else { return nil }
        return PinGeometry.measurementEntryPoint(
            from: previousPoint,
            to: currentPoint,
            in: imageRect
        )
    }

    func beginExternalMeasure(at point: NSPoint) -> Bool {
        canvasView.beginExternalMeasure(at: canvasView.convert(point, from: self))
    }

    func updateExternalMeasure(at point: NSPoint, shiftHeld: Bool) {
        canvasView.updateExternalMeasure(
            to: canvasView.convert(point, from: self),
            shiftHeld: shiftHeld
        )
    }

    func finishExternalMeasure() {
        canvasView.finishExternalMeasure()
    }

    func updatePixelInspectorForFlags(modifierFlags: NSEvent.ModifierFlags, viewPoint: NSPoint) {
        guard !isTextSelectionInteractionSuspended else { return }
        let optionDown = InteractionShortcutManager.modifierIsHeld(
            modifierFlags, action: .togglePixelInspector)
        let shiftDown = InteractionShortcutManager.modifierIsHeld(
            modifierFlags, action: .togglePixelInspectorFormat)
        let transition = pixelInspectorHoldPolicy.update(
            modifierIsDown: optionDown,
            canActivate: isSelected && containsOpaqueImagePoint(viewPoint)
        )
        switch transition {
        case .activated:
            pixelInspectorActive = true
            pixelInspectorPoint = viewPoint
            pixelInspectorImageCache = pixelInspectorImage()
            canvasView.setPinPixelInspectorActive(true)
            updatePixelInspectorPanel(at: viewPoint)
        case .deactivated:
            deactivatePixelInspector()
        case .unchanged:
            break
        }
        if pixelInspectorActive && shiftDown && !pixelInspectorShiftWasDown {
            pixelInspectorMode.toggle()
            updatePixelInspectorPanel(at: pixelInspectorPoint)
        }
        pixelInspectorShiftWasDown = shiftDown
    }

    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard acceptsPointer(at: loc) else { return }
        onSelect?()
        onShowToolbar?(screenPoint(forEvent: event))
    }

    private func acceptsPointer(at point: NSPoint) -> Bool {
        containsInteractiveImagePoint(point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isTransparentAnnotationContent else { return }
        guard !isTextSelectionInteractionSuspended else { return }
        if InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .pinOpacity, among: [.pinZoom, .pinOpacity]), isSelected {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.01 else { return }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            onOpacityChange?((delta > 0 ? 1 : -1) * step)
            return
        }
        guard InteractionShortcutManager.matchesModifiers(event.modifierFlags, action: .pinZoom, among: [.pinZoom, .pinOpacity]) else {
            super.scrollWheel(with: event)
            return
        }
        guard PinZoomInputPreferences.isWheelZoomEnabled else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        if !PinZoomInputPreferences.isSmoothZoomEnabled {
            discreteWheelAccumulator += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 0.5
            guard abs(discreteWheelAccumulator) >= threshold else { return }
            discreteWheelAccumulator = 0
        }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
        let factor = max(0.2, min(5.0, 1.0 + delta * sensitivity))
        let loc = convert(event.locationInWindow, from: nil)
        guard containsOpaqueImagePoint(loc) else { return }
        let screenPoint = screenPoint(forEvent: event)
        onSelect?()
        onZoom?(
            factor,
            screenPoint,
            loc,
            event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != [],
            mergedPhase(event)
        )
    }

    override func magnify(with event: NSEvent) {
        guard !isTransparentAnnotationContent else { return }
        guard !isTextSelectionInteractionSuspended else { return }
        guard PinZoomInputPreferences.isMagnifyZoomEnabled else {
            super.magnify(with: event)
            return
        }
        let factor = max(0.2, min(5.0, 1.0 + event.magnification))
        let loc = convert(event.locationInWindow, from: nil)
        guard containsOpaqueImagePoint(loc) else { return }
        let screenPoint = screenPoint(forEvent: event)
        onSelect?()
        onZoom?(factor, screenPoint, loc, true, event.phase)
    }

    override func beginGesture(with event: NSEvent) {
        guard !isTransparentAnnotationContent else { return }
        guard !isTextSelectionInteractionSuspended else { return }
        guard PinZoomInputPreferences.isMagnifyZoomEnabled else {
            super.beginGesture(with: event)
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        if containsOpaqueImagePoint(loc) {
            let screenPoint = screenPoint(forEvent: event)
            onZoomPhase?(screenPoint, .began)
            return
        }
        super.beginGesture(with: event)
    }

    override func endGesture(with event: NSEvent) {
        guard !isTransparentAnnotationContent else { return }
        guard !isTextSelectionInteractionSuspended else { return }
        guard PinZoomInputPreferences.isMagnifyZoomEnabled else {
            super.endGesture(with: event)
            return
        }
        onZoomPhase?(screenPoint(forEvent: event), .ended)
    }

    @objc private func handleMagnificationGesture(_ recognizer: NSMagnificationGestureRecognizer) {
        guard !isTransparentAnnotationContent else { return }
        guard !isTextSelectionInteractionSuspended else { return }
        guard PinZoomInputPreferences.isMagnifyZoomEnabled else { return }
        let factor = max(0.2, min(5.0, 1.0 + recognizer.magnification))
        guard factor != 1 else { return }
        let loc = recognizer.location(in: self)
        guard containsOpaqueImagePoint(loc) else { return }
        let screenPoint = screenPoint(forViewPoint: loc)
        let phase: NSEvent.Phase
        switch recognizer.state {
        case .began: phase = .began
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: phase = []
        }
        onSelect?()
        onZoom?(factor, screenPoint, loc, true, phase)
        recognizer.magnification = 0
    }

    private func screenPoint(forEvent event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func screenPoint(forViewPoint viewPoint: NSPoint) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        let windowPoint = convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func updatePixelInspectorPanel(at point: NSPoint) {
        guard pixelInspectorActive,
              isSelected,
              imageRect.contains(point),
              isOpaqueAt(point)
        else {
            pixelInspectorPanel.hide()
            return
        }
        let inspectorImage = pixelInspectorImageCache ?? pixelInspectorImage()
        pixelInspectorImageCache = inspectorImage
        let screenFrame = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        pixelInspectorPanel.show(
            image: inspectorImage,
            viewPoint: point,
            imageRect: imageRect,
            screenPoint: screenPoint(forViewPoint: point),
            visibleFrame: screenFrame,
            displayMode: pixelInspectorMode
        )
    }

    func dismissPixelInspector() {
        pixelInspectorHoldPolicy.reset()
        deactivatePixelInspector()
    }

    func yieldPixelInspectorToShortcut(modifierFlags: NSEvent.ModifierFlags) {
        let modifierIsDown = InteractionShortcutManager.modifierIsHeld(
            modifierFlags, action: .togglePixelInspector)
        if pixelInspectorHoldPolicy.yieldToShortcut(modifierIsDown: modifierIsDown) == .deactivated {
            deactivatePixelInspector()
        }
    }

    private func deactivatePixelInspector() {
        pixelInspectorActive = false
        pixelInspectorShiftWasDown = false
        pixelInspectorPoint = .zero
        pixelInspectorImageCache = nil
        canvasView.setPinPixelInspectorActive(false)
        pixelInspectorPanel.hide()
    }

    private func pixelInspectorImage() -> NSImage {
        canvasView.pixelInspectorSourceImage()
    }

    private func mergedPhase(_ event: NSEvent) -> NSEvent.Phase {
        var phase = event.phase
        phase.formUnion(event.momentumPhase)
        return phase
    }

    func normalizedImagePoint(for point: NSPoint) -> NSPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return NSPoint(x: 0.5, y: 0.5) }
        return NSPoint(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }

    func imagePointOffset(for point: NSPoint) -> NSPoint {
        let rect = imageRect
        return NSPoint(
            x: min(rect.width, max(0, point.x - rect.minX)),
            y: min(rect.height, max(0, point.y - rect.minY))
        )
    }

    func containsOpaqueImagePoint(_ point: NSPoint) -> Bool {
        imageRect.contains(point) && isOpaqueAt(point)
    }

    /// Vector-only transparent Pins intentionally have a clear backing image.
    /// Their compact content rect still owns drag and edit input; ordinary Pins
    /// retain alpha-based pointer routing.
    func containsInteractiveImagePoint(_ point: NSPoint) -> Bool {
        imageRect.contains(point) && (isTransparentAnnotationContent || isOpaqueAt(point))
    }

    private func sourceRect() -> NSRect {
        if !isCompactMode || !showsPartialImage {
            return NSRect(origin: .zero, size: image.size)
        }
        let side = min(image.size.width, image.size.height, PinGeometry.defaultCompactSize.width)
        let center = NSPoint(x: compactCenter.x * image.size.width, y: compactCenter.y * image.size.height)
        var origin = NSPoint(x: center.x - side / 2, y: center.y - side / 2)
        origin.x = min(max(0, origin.x), max(0, image.size.width - side))
        origin.y = min(max(0, origin.y), max(0, image.size.height - side))
        return NSRect(origin: origin, size: NSSize(width: side, height: side))
    }

    func sourceRectForCompact() -> NSRect {
        sourceRect()
    }

    private func imagePoint(for point: NSPoint) -> NSPoint {
        let normalized = normalizedImagePoint(for: point)
        let source = sourceRect()
        return NSPoint(
            x: source.origin.x + normalized.x * source.width,
            y: source.origin.y + normalized.y * source.height
        )
    }

    private func isOpaqueAt(_ point: NSPoint) -> Bool {
        guard imageRect.contains(point) else { return false }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let imgPoint = imagePoint(for: point)
        let px = min(cgImage.width - 1, max(0, Int(imgPoint.x / max(image.size.width, 1) * CGFloat(cgImage.width))))
        let py = min(cgImage.height - 1, max(0, Int((1 - imgPoint.y / max(image.size.height, 1)) * CGFloat(cgImage.height))))
        guard let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data)
        else { return true }
        let bitsPerPixel = cgImage.bitsPerPixel
        guard bitsPerPixel == 32 else { return true }
        let offset = py * cgImage.bytesPerRow + px * 4
        guard offset + 3 < CFDataGetLength(data) else { return true }
        let alphaInfo = cgImage.alphaInfo
        let alpha: UInt8
        switch alphaInfo {
        case .premultipliedLast, .last:
            alpha = bytes[offset + 3]
        case .premultipliedFirst, .first:
            alpha = bytes[offset]
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        case .alphaOnly:
            alpha = bytes[offset]
        @unknown default:
            return true
        }
        return alpha > 8
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isTextSelectionInteractionSuspended {
            if event.keyCode == 53 { onExitTextSelection?() }
            return
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onConfirmAnnotation?()
        } else if pixelInspectorActive, event.keyCode == 8, !event.modifierFlags.contains(.command) {
            guard let value = pixelInspectorPanel.copyCurrentValue(displayMode: pixelInspectorMode) else { return }
            showStatusText(value)
        } else if pixelInspectorActive,
                  InteractionShortcutManager.matchesArrow(
                    event,
                    action: .nudgeInspectorCursor,
                    whileHolding: .togglePixelInspector
                  ) {
            let inspectorImage = pixelInspectorImageCache ?? pixelInspectorImage()
            pixelInspectorImageCache = inspectorImage
            pixelInspectorPoint = PixelInspector.nudgedViewPoint(
                from: pixelInspectorPoint,
                keyCode: event.keyCode,
                image: inspectorImage,
                imageRect: imageRect
            )
            updatePixelInspectorPanel(at: pixelInspectorPoint)
            PixelInspector.warpMouse(toScreenPoint: screenPoint(forViewPoint: pixelInspectorPoint))
        } else if InteractionShortcutManager.matchesArrow(event, action: .nudgeSelection) {
            let delta: NSPoint
            switch event.keyCode {
            case 123: delta = NSPoint(x: -1, y: 0)
            case 124: delta = NSPoint(x: 1, y: 0)
            case 125: delta = NSPoint(x: 0, y: -1)
            default: delta = NSPoint(x: 0, y: 1)
            }
            onNudge?(delta)
        } else if event.keyCode == 53 {
            dismissPixelInspector()
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}
