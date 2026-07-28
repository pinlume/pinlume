import Cocoa

/// Transparent selection and drawing surface for the P3 workflows. It reuses
/// OverlayView's annotation/TextKit state machine without ever receiving pixels.
@MainActor
final class TransparentAnnotationCanvasView: OverlayView, AnnotationSourceImageProviding {

    var onSelectionReady: ((NSRect) -> Void)?
    /// Fired after an already-completed selection is moved or resized. The
    /// session owns its toolbar separately, so it must relayout immediately
    /// instead of waiting for a later canvas click.
    var onSelectionChanged: ((NSRect) -> Void)?
    var onSelectionReset: (() -> Void)?
    /// This is intentionally true: the final Pin clips against `selectionRect`,
    /// while the live canvas remains a free transparent drawing surface.
    let allowsAnnotationsOutsideSelection = true
    /// The session toolbar is hosted as a direct sibling. Keep its tracking
    /// area out of OverlayView's drawing-cursor engine.
    var externalChromeContains: ((NSPoint) -> Bool)?
    /// The session toolbar is a direct child rather than one of OverlayView's
    /// pooled capture strips. Route it before OverlayView considers text or
    /// annotation input so every real button keeps its AppKit click target.
    weak var externalToolbarView: NSView?
    private(set) var isSelectionReady = false
    private var selectionGestureStart: NSPoint?
    private var didDragSelection = false
    private var lastReportedSelectionRect: NSRect?

    init(size: NSSize, startsWithSelection: Bool) {
        super.init(frame: NSRect(origin: .zero, size: size))
        screenshotImage = nil
        captureSourceImage = nil
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        showToolbars = false
        // Unlike an image-backed overlay, a transparent canvas has no visual
        // backing under a hidden cursor. Keep the system cursor visible after
        // the first pencil stroke.
        hidesDrawingCursorPreview = false
        if startsWithSelection {
            applySelection(bounds)
            showToolbars = false
            isSelectionReady = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override func shouldClipSelectionImage() -> Bool { false }
    override func shouldShowResolutionBox() -> Bool { false }

    func setTransparentTool(_ tool: AnnotationTool) {
        if currentTool == .text, tool != .text, textEditor.isEditing {
            confirmAnnotationEditing()
        }
        if tool != .select {
            clearAnnotationSelectionForExternalToolbar()
        }
        currentTool = tool
        showToolbars = false
        needsDisplay = true
    }

    func clearTransparentAnnotations() {
        confirmAnnotationEditing()
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        needsDisplay = true
    }

    func restartTransparentSelection() {
        confirmAnnotationEditing()
        clearSelection()
        isSelectionReady = false
        selectionGestureStart = nil
        didDragSelection = false
        lastReportedSelectionRect = nil
        onSelectionReset?()
    }

    /// Rehydrates a compact transparent Pin in source-screen coordinates.
    /// Keeping this state here means a Pin never has to grow or edit its own
    /// translated preview canvas just to let the user adjust the crop again.
    func restoreTransparentPayload(_ payload: TransparentAnnotationPinPayload) {
        confirmAnnotationEditing()
        annotations = payload.annotations.map { $0.clone() }
        undoStack.removeAll()
        redoStack.removeAll()
        applySelection(payload.cropRect)
        refreshRestoredTransparentLoupeSources()
        isSelectionReady = true
        selectionGestureStart = nil
        didDragSelection = false
        lastReportedSelectionRect = selectionRect
        showToolbars = false
        needsDisplay = true
    }

    func transparentPinPayload(for screen: NSScreen) -> TransparentAnnotationPinPayload? {
        guard isSelectionReady, !selectionRect.isEmpty else { return nil }
        let visibleAnnotations = TransparentAnnotationGeometry.retainedAnnotations(
            annotations,
            cropRect: selectionRect
        )
        guard !visibleAnnotations.isEmpty else { return nil }
        return TransparentAnnotationPinPayload(
            screen: screen,
            cropRect: selectionRect,
            annotations: visibleAnnotations.map { $0.clone() }
        )
    }

    func transparentOutputImage() -> NSImage? {
        confirmAnnotationEditing()
        return TransparentAnnotationGeometry.renderOutputImage(
            annotations: annotations,
            cropRect: selectionRect
        )
    }

    /// A loupe only samples a small region around its initial press point. Do
    /// not synchronously rasterize the entire transparent screen on that click.
    private func loupeSourceSnapshotRect(around point: NSPoint) -> NSRect {
        let side = max(512, currentLoupeSize * 4)
        return NSRect(
            x: point.x - side / 2,
            y: point.y - side / 2,
            width: side,
            height: side
        ).intersection(bounds)
    }

    func annotationSourceImageForLoupe(at point: NSPoint) -> (image: NSImage, bounds: NSRect)? {
        let cropRect = loupeSourceSnapshotRect(around: point)
        guard !cropRect.isEmpty,
              let image = TransparentAnnotationGeometry.renderOutputImage(
                annotations: annotations,
                cropRect: cropRect
              )
        else { return nil }
        return (image, cropRect)
    }

    /// Annotation clones deliberately omit their transient loupe source image.
    /// A compact Pin rebuilds that source before previewing; do the same when
    /// reopening its source-space editor so the loupe remains visible there.
    private func refreshRestoredTransparentLoupeSources() {
        let sourceAnnotations = annotations.filter { $0.tool != .loupe }
        guard !sourceAnnotations.isEmpty else { return }

        for annotation in annotations where annotation.tool == .loupe {
            let sourcePoint: NSPoint
            if let sourceRect = annotation.loupeSourceRect {
                sourcePoint = NSPoint(x: sourceRect.midX, y: sourceRect.midY)
            } else {
                sourcePoint = NSPoint(x: annotation.boundingRect.midX, y: annotation.boundingRect.midY)
            }
            let cropRect = loupeSourceSnapshotRect(around: sourcePoint)
            guard !cropRect.isEmpty,
                  let source = TransparentAnnotationGeometry.renderOutputImage(
                    annotations: sourceAnnotations,
                    cropRect: cropRect
                  )
            else { continue }
            annotation.sourceImage = source
            annotation.sourceImageBounds = cropRect
            annotation.bakedBlurNSImage = nil
            annotation.bakeLoupe()
        }
    }

    func undoTransparentAnnotation() {
        undo()
        showToolbars = false
    }

    func redoTransparentAnnotation() {
        redo()
        showToolbars = false
    }

    func showTransparentColorPicker(anchorView: NSView?, onChange: @escaping () -> Void) {
        let picker = ColorPickerView()
        picker.setColor(currentColor, opacity: currentColorOpacity)
        picker.onColorChanged = { [weak self] color in
            guard let self else { return }
            self.currentColor = color
            self.textEditor.applyColorToLiveText(color: color)
            self.needsDisplay = true
            onChange()
        }
        picker.onOpacityChanged = { [weak self] opacity in
            guard let self else { return }
            self.currentColorOpacity = opacity
            UserDefaults.standard.set(Double(opacity), forKey: "lastUsedColorOpacity")
            self.needsDisplay = true
            onChange()
        }
        let size = picker.preferredSize
        if let anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker,
                size: size,
                at: NSPoint(x: bounds.midX, y: bounds.midY),
                in: self,
                preferredEdge: .maxY
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if shouldIgnoreOutsideSelectionClick(at: point) {
            return
        }
        if !isSelectionReady {
            selectionGestureStart = point
            didDragSelection = false
        }
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if let toolbar = externalToolbarView,
           !toolbar.isHidden,
           toolbar.frame.contains(localPoint) {
            // ToolbarStripView's established contract accepts the parent
            // canvas coordinate and performs its own child conversion.
            return toolbar.hitTest(localPoint)
        }
        return super.hitTest(point)
    }

    /// Ordinary capture expands a committed crop after an outside click. In a
    /// transparent session that makes a missed toolbar/blank click mutate the
    /// product boundary, so only its visible resize handles may begin there.
    private func shouldIgnoreOutsideSelectionClick(at point: NSPoint) -> Bool {
        guard isSelectionReady,
              currentTool == .select,
              !pointIsInSelection(point)
        else { return false }
        return !isSelectionResizeTarget(point)
    }

    private func isSelectionResizeTarget(_ point: NSPoint) -> Bool {
        let rect = selectionRect
        let handleSize: CGFloat = 12
        let half = handleSize / 2
        let centers = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.midX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.maxX, y: rect.midY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        return centers.contains {
            NSRect(x: $0.x - half, y: $0.y - half, width: handleSize, height: handleSize).contains(point)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard externalChromeContains?(point) != true else {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if externalChromeContains?(point) == true {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !isSelectionReady,
           let selectionGestureStart {
            let point = convert(event.locationInWindow, from: nil)
            didDragSelection = didDragSelection || hypot(
                point.x - selectionGestureStart.x,
                point.y - selectionGestureStart.y
            ) > 5
        }
        super.mouseDragged(with: event)
        notifySelectionChangedIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        let wasSelectionReady = isSelectionReady
        super.mouseUp(with: event)
        if wasSelectionReady {
            notifySelectionChangedIfNeeded()
            return
        }
        guard didDragSelection, selectionRect.width > 5, selectionRect.height > 5 else {
            clearSelection()
            return
        }
        isSelectionReady = true
        lastReportedSelectionRect = selectionRect
        showToolbars = false
        onSelectionReady?(selectionRect)
    }

    private func notifySelectionChangedIfNeeded() {
        guard isSelectionReady,
              selectionRect != lastReportedSelectionRect
        else { return }
        lastReportedSelectionRect = selectionRect
        onSelectionChanged?(selectionRect)
    }

}
