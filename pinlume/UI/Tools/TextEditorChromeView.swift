import AppKit

/// A text editor clip whose presentation origin never follows transient IME
/// caret scrolling. The chrome itself always grows to the current TextKit
/// measurement, so scrolling inside this private viewport is unnecessary.
@MainActor
private final class TextEditorClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        drawsBackground = false
        backgroundColor = .clear
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin = .zero
        return constrained
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: .zero)
    }
}

@MainActor
private protocol TextEditorTextViewScrollDelegate: AnyObject {
    func textEditorTextViewDidScrollWheel(_ event: NSEvent)
}

@MainActor
private final class TextEditorTextView: NSTextView {
    weak var scrollDelegate: TextEditorTextViewScrollDelegate?

    override func scrollWheel(with event: NSEvent) {
        scrollDelegate?.textEditorTextViewDidScrollWheel(event)
    }
}

struct TextFontSizeScrollAccumulator {
    private var accumulatedDelta: CGFloat = 0

    mutating func consume(delta: CGFloat, hasPreciseDeltas: Bool) -> Int {
        guard abs(delta) > 0.01 else { return 0 }
        accumulatedDelta += delta
        let threshold: CGFloat = hasPreciseDeltas ? 18 : 0.5
        guard abs(accumulatedDelta) >= threshold else { return 0 }
        let step = accumulatedDelta > 0 ? 1 : -1
        accumulatedDelta = 0
        return step
    }
}

@MainActor
protocol TextEditorChromeViewDelegate: AnyObject {
    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didBegin target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    )
    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didContinue target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    )
    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didEnd target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    )
    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didRequestFontSizeStep step: Int
    )
}

/// Native text editing surface plus the minimal text-only editing chrome.
/// NSTextView owns insertion, selection, clipboard, undo and IME behavior;
/// this view owns only the frame line, movement, rotation and font-size handles.
@MainActor
final class TextEditorChromeView: NSView, TextEditorTextViewScrollDelegate {
    static let chromePadding = TextAnnotationInteraction.requiredChromePadding
    private static let controlClearance = TextAnnotationInteraction.controlVisualSize / 2 + 1
    private static let rotationSymbol = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(
        pointSize: TextAnnotationInteraction.controlVisualSize,
        weight: .medium
    ))
    private static let fontSizeSymbol = NSImage(
        systemSymbolName: "arrow.down.right.and.arrow.up.left",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(
        pointSize: TextAnnotationInteraction.controlVisualSize,
        weight: .medium
    ))

    let scrollView = NSScrollView()
    let textView: NSTextView = TextEditorTextView()
    let rotationImageView = NSImageView()
    let fontSizeImageView = NSImageView()

    weak var interactionDelegate: TextEditorChromeViewDelegate?

    var controlStrokeColor: NSColor = ToolbarLayout.accentColor {
        didSet {
            rotationImageView.contentTintColor = controlStrokeColor
            fontSizeImageView.contentTintColor = controlStrokeColor
            needsDisplay = true
        }
    }
    var textBackgroundColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var textOutlineColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var rotationRadians: CGFloat = 0 {
        didSet { frameCenterRotation = rotationRadians * 180 / .pi }
    }
    var isManipulating = false {
        didSet {
            updateControlVisibility()
            needsDisplay = true
        }
    }

    private var currentInteraction: TextAnnotationHitTarget = .outside
    private var pointerInsideHoverRegion = false
    private var pointerTrackingArea: NSTrackingArea?
    private var documentExtent: NSSize = .zero
    private var fontSizeScrollAccumulator = TextFontSizeScrollAccumulator()

    init(contentFrame: NSRect) {
        let padding = Self.chromePadding
        super.init(frame: contentFrame.insetBy(dx: -padding, dy: -padding))

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView = TextEditorClipView(frame: .zero)
        scrollView.documentView = textView
        (textView as? TextEditorTextView)?.scrollDelegate = self
        addSubview(scrollView)
        configureControlImageView(rotationImageView, image: Self.rotationSymbol)
        configureControlImageView(fontSizeImageView, image: Self.fontSizeSymbol)
        updateContentLayout()
        updateControlVisibility()
    }

    required init?(coder: NSCoder) { nil }

    var contentRect: NSRect {
        bounds.insetBy(dx: Self.chromePadding, dy: Self.chromePadding)
    }

    var contentSize: NSSize { contentRect.size }

    var contentFrameInSuperview: NSRect {
        guard let superview else { return .zero }
        let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: superview)
        return NSRect(
            x: center.x - contentSize.width / 2,
            y: center.y - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    var contentTopLeftInSuperview: NSPoint {
        guard let superview else { return .zero }
        return convert(
            NSPoint(x: contentRect.minX, y: contentRect.maxY),
            to: superview
        )
    }

    func setContentSize(_ size: NSSize, preservingTopLeft: Bool) {
        let oldTopLeft = preservingTopLeft ? contentTopLeftInSuperview : .zero
        setFrameSize(
            NSSize(
                width: size.width + Self.chromePadding * 2,
                height: size.height + Self.chromePadding * 2
            )
        )
        updateContentLayout()

        if preservingTopLeft, superview != nil {
            let newTopLeft = contentTopLeftInSuperview
            setFrameOrigin(
                NSPoint(
                    x: frame.origin.x + oldTopLeft.x - newTopLeft.x,
                    y: frame.origin.y + oldTopLeft.y - newTopLeft.y
                )
            )
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setPointerLocation(_ point: NSPoint) {
        let isInside = TextAnnotationInteraction.hoverContains(
            point,
            rect: contentRect,
            rotation: 0
        )
        guard isInside != pointerInsideHoverRegion else { return }
        pointerInsideHoverRegion = isInside
        updateControlVisibility()
        needsDisplay = true
    }

    func cursor(atSuperviewPoint point: NSPoint) -> NSCursor? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        setPointerLocation(localPoint)
        switch interactionTarget(at: localPoint) {
        case .rotate:
            return AppCursor.rotation
        case .fontSize:
            return AppCursor.diagonalNWSE
        case .border:
            return AppCursor.move
        case .interior:
            return .iBeam
        case .outside:
            return nil
        }
    }

    /// AppKit clips ordinary child hit testing to a rotated view's unrotated
    /// frame. The overlay asks this method first so corner controls that are
    /// visibly outside that frame still receive their event.
    func routedHitTest(atSuperviewPoint point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        switch interactionTarget(at: localPoint) {
        case .rotate, .fontSize, .border:
            return self
        case .interior:
            return textView
        case .outside:
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch interactionTarget(at: point) {
        case .rotate, .fontSize, .border:
            return self
        case .interior:
            return super.hitTest(point)
        case .outside:
            return nil
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = contentRect
        let inner = TextAnnotationInteraction.borderInnerHitWidth
        let outer = TextAnnotationInteraction.borderOuterHitWidth
        let bandThickness = inner + outer
        addCursorRect(rect.insetBy(dx: inner, dy: inner), cursor: .iBeam)
        addCursorRect(
            NSRect(
                x: rect.minX - outer,
                y: rect.minY - outer,
                width: rect.width + outer * 2,
                height: bandThickness
            ),
            cursor: AppCursor.move
        )
        addCursorRect(
            NSRect(
                x: rect.minX - outer,
                y: rect.maxY - inner,
                width: rect.width + outer * 2,
                height: bandThickness
            ),
            cursor: AppCursor.move
        )
        addCursorRect(
            NSRect(
                x: rect.minX - outer,
                y: rect.minY + inner,
                width: bandThickness,
                height: max(0, rect.height - inner * 2)
            ),
            cursor: AppCursor.move
        )
        addCursorRect(
            NSRect(
                x: rect.maxX - inner,
                y: rect.minY + inner,
                width: bandThickness,
                height: max(0, rect.height - inner * 2)
            ),
            cursor: AppCursor.move
        )
        let controls = TextAnnotationInteraction.controlRects(for: rect, rotation: 0)
        addCursorRect(
            controls.rotate.insetBy(dx: -TextAnnotationInteraction.controlHitSlop,
                                    dy: -TextAnnotationInteraction.controlHitSlop),
            cursor: AppCursor.rotation
        )
        addCursorRect(
            controls.fontSize.insetBy(dx: -TextAnnotationInteraction.controlHitSlop,
                                      dy: -TextAnnotationInteraction.controlHitSlop),
            cursor: AppCursor.diagonalNWSE
        )
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerAndCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerAndCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointerInsideHoverRegion = false
        updateControlVisibility()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let target = interactionTarget(at: convert(event.locationInWindow, from: nil))
        guard target == .border || target == .rotate || target == .fontSize else { return }
        currentInteraction = target
        interactionDelegate?.textEditorChromeView(
            self,
            didBegin: target,
            at: pointInSuperview(for: event)
        )
        cursor(for: target).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard currentInteraction != .outside else { return }
        interactionDelegate?.textEditorChromeView(
            self,
            didContinue: currentInteraction,
            at: pointInSuperview(for: event)
        )
        cursor(for: currentInteraction).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard currentInteraction != .outside else { return }
        let finished = currentInteraction
        interactionDelegate?.textEditorChromeView(
            self,
            didEnd: finished,
            at: pointInSuperview(for: event)
        )
        currentInteraction = .outside
        updatePointerAndCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        handleFontSizeScroll(event)
    }

    fileprivate func textEditorTextViewDidScrollWheel(_ event: NSEvent) {
        handleFontSizeScroll(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = contentRect
        let pillRect = rect.insetBy(dx: -4, dy: -4)

        if let textBackgroundColor {
            textBackgroundColor.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()
        }
        if let textOutlineColor {
            textOutlineColor.setStroke()
            let outline = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            outline.lineWidth = 2
            outline.stroke()
        }

        guard !isManipulating else { return }

        controlStrokeColor.setStroke()
        if pointerInsideHoverRegion {
            let path = NSBezierPath()
            for segment in TextAnnotationInteraction.frameSegments(
                for: rect,
                controlClearance: Self.controlClearance
            ) {
                path.move(to: segment.start)
                path.line(to: segment.end)
            }
            path.lineWidth = 1
            path.stroke()
        } else {
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func updateContentLayout() {
        let rect = contentRect
        scrollView.frame = rect
        documentExtent = NSSize(
            width: max(documentExtent.width, rect.width),
            height: max(documentExtent.height, rect.height)
        )
        textView.frame = NSRect(origin: .zero, size: documentExtent)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let visualSize = TextAnnotationInteraction.controlVisualSize
        rotationImageView.frame = NSRect(
            x: rect.maxX - visualSize / 2,
            y: rect.maxY - visualSize / 2,
            width: visualSize,
            height: visualSize
        )
        fontSizeImageView.frame = NSRect(
            x: rect.maxX - visualSize / 2,
            y: rect.minY - visualSize / 2,
            width: visualSize,
            height: visualSize
        )
    }

    private func handleFontSizeScroll(_ event: NSEvent) {
        let step = fontSizeScrollAccumulator.consume(
            delta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard step != 0 else { return }
        interactionDelegate?.textEditorChromeView(self, didRequestFontSizeStep: step)
    }

    private func configureControlImageView(_ imageView: NSImageView, image: NSImage?) {
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = controlStrokeColor
        imageView.isHidden = true
        addSubview(imageView, positioned: .above, relativeTo: scrollView)
    }

    private func updateControlVisibility() {
        let hidden = isManipulating || !pointerInsideHoverRegion
        rotationImageView.isHidden = hidden
        fontSizeImageView.isHidden = hidden
    }

    private func updatePointerAndCursor(at localPoint: NSPoint) {
        setPointerLocation(localPoint)
        let target = currentInteraction == .outside
            ? interactionTarget(at: localPoint)
            : currentInteraction
        cursor(for: target).set()
    }

    private func interactionTarget(at point: NSPoint) -> TextAnnotationHitTarget {
        TextAnnotationInteraction.target(at: point, rect: contentRect, rotation: 0)
    }

    private func pointInSuperview(for event: NSEvent) -> NSPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? .zero
    }

    private func cursor(for target: TextAnnotationHitTarget) -> NSCursor {
        switch target {
        case .rotate: return AppCursor.rotation
        case .fontSize: return AppCursor.diagonalNWSE
        case .border: return AppCursor.move
        case .interior: return .iBeam
        case .outside: return .arrow
        }
    }
}
