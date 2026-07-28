import Cocoa

/// Protocol for the minimal canvas state that TextEditingController needs for commit/show.
@MainActor
protocol TextEditingCanvas: AnyObject {
    func viewToCanvas(_ p: NSPoint) -> NSPoint
    func canvasToView(_ p: NSPoint) -> NSPoint
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor
    var currentStrokeWidth: CGFloat { get }
    var annotations: [Annotation] { get set }
    var undoStack: [UndoEntry] { get set }
    var redoStack: [UndoEntry] { get set }
    var currentColor: NSColor { get }
    func textEditingStrokeColor(at canvasPoint: NSPoint) -> NSColor
    func annotationDidCommit(_ annotation: Annotation)
}

@MainActor
protocol TextEditingControllerDelegate: AnyObject {
    func textEditingControllerDidChangeGeometry(_ controller: TextEditingController)
    func textEditingController(
        _ controller: TextEditingController,
        didChangeFontSize fontSize: CGFloat
    )
}

/// Live annotation text uses the same editing commands as a standard
/// NSTextView. Canvas-level copy/paste is considered only when no live editor
/// consumes the event.
@MainActor
enum NativeTextCommandRouter {
    static func handle(_ event: NSEvent, in textView: NSTextView) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }

        switch event.keyCode {
        case 0 where modifiers == .command:
            textView.selectAll(nil)
        case 7 where modifiers == .command:
            textView.cut(nil)
        case 8 where modifiers == .command:
            textView.copy(nil)
        case 9 where modifiers == .command:
            textView.paste(nil)
        case 6:
            if modifiers.contains(.shift) {
                textView.undoManager?.redo()
            } else {
                textView.undoManager?.undo()
            }
        default:
            return false
        }
        return true
    }
}

/// Manages inline text editing for the text annotation tool.
/// Owns ALL text state: style, NSTextView lifecycle, formatting, commit, cancel.
@MainActor
class TextEditingController: NSObject {

    weak var delegate: TextEditingControllerDelegate?

    // MARK: - Text style state

    var fontSize: CGFloat = UserDefaults.standard.object(forKey: "textFontSize") as? CGFloat ?? 20
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var alignment: NSTextAlignment = .left
    var fontFamily: String = UserDefaults.standard.string(forKey: "textFontFamily") ?? "System"
    var bgEnabled: Bool = UserDefaults.standard.bool(forKey: "textBgEnabled") {
        didSet { refreshChromeStyle() }
    }
    var outlineEnabled: Bool = UserDefaults.standard.bool(forKey: "textOutlineEnabled") {
        didSet { refreshChromeStyle() }
    }
    var glyphStrokeEnabled: Bool = UserDefaults.standard.bool(forKey: "textGlyphStrokeEnabled")

    var bgColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return color }
        return NSColor.black.withAlphaComponent(0.5)
    }() {
        didSet { refreshChromeStyle() }
    }

    var outlineColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textOutlineColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return color }
        return NSColor.white
    }() {
        didSet { refreshChromeStyle() }
    }

    var glyphStrokeColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textGlyphStrokeColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return color }
        return NSColor.white
    }()

    // MARK: - NSTextView

    private(set) var chromeView: TextEditorChromeView?

    var textView: NSTextView? { chromeView?.textView }
    var scrollView: NSScrollView? { chromeView?.scrollView }

    var isEditing: Bool { textView != nil }

    /// The annotation being re-edited (removed from canvas, restored on cancel).
    private(set) var editingAnnotation: Annotation?
    private var editingAnnotationIndex: Int?
    private weak var activeCanvas: TextEditingCanvas?

    private(set) var rotation: CGFloat = 0
    private var activeTextColor: NSColor?
    private var interactionStartPoint: NSPoint = .zero
    private var interactionStartFrameOrigin: NSPoint = .zero
    private var interactionStartRotation: CGFloat = 0
    private var interactionStartAngle: CGFloat = 0
    private var interactionCenter: NSPoint = .zero
    private var interactionStartFontSize: CGFloat = 20
    private var interactionStartDistance: CGFloat = 1
    private var interactionFontAnchor: NSPoint = .zero
    private var externalInteraction: TextAnnotationHitTarget = .outside
    private let layoutRequestGate = TextLayoutRequestGate()
    private var layoutSessionID: UInt?
    private var lineMetricsDelegate: TextAnnotationLineMetricsDelegate?

    var hasExternalInteraction: Bool { externalInteraction != .outside }

    // MARK: - Font construction

    func currentFont() -> NSFont {
        let fm = NSFontManager.shared
        let baseFont: NSFont
        if fontFamily == "System" {
            baseFont = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        } else if let font = NSFont(name: fontFamily, size: fontSize) {
            baseFont = bold ? fm.convert(font, toHaveTrait: .boldFontMask) : font
        } else {
            baseFont = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        }
        if italic {
            return fm.convert(baseFont, toHaveTrait: .italicFontMask)
        }
        return baseFont
    }

    /// Apply bold/italic to a font, handling system fonts that NSFontManager can't convert via traits.
    func applyBoldItalic(to font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let size = font.pointSize
        let familyName = font.familyName ?? "System"

        // System font: use NSFont.systemFont directly (NSFontManager can't convert SF traits)
        if familyName.hasPrefix(".") || familyName == "System" || fontFamily == "System" {
            var base: NSFont
            if bold && italic {
                base = NSFont.systemFont(ofSize: size, weight: .bold)
                let desc = base.fontDescriptor.withSymbolicTraits(.italic)
                base = NSFont(descriptor: desc, size: size) ?? base
            } else if bold {
                base = NSFont.systemFont(ofSize: size, weight: .bold)
            } else if italic {
                let regular = NSFont.systemFont(ofSize: size, weight: .regular)
                let desc = regular.fontDescriptor.withSymbolicTraits(.italic)
                base = NSFont(descriptor: desc, size: size) ?? regular
            } else {
                base = NSFont.systemFont(ofSize: size, weight: .regular)
            }
            return base
        }

        // Non-system fonts: use NSFontManager trait conversion
        let fm = NSFontManager.shared
        var result = font
        if bold {
            result = fm.convert(result, toHaveTrait: .boldFontMask)
        } else {
            result = fm.convert(result, toNotHaveTrait: .boldFontMask)
        }
        if italic {
            result = fm.convert(result, toHaveTrait: .italicFontMask)
        } else {
            result = fm.convert(result, toNotHaveTrait: .italicFontMask)
        }
        return result
    }

    // MARK: - Style toggles

    private func selectedOrAllRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        return NSRange(location: 0, length: tv.textStorage?.length ?? 0)
    }

    func toggleBold() {
        guard let tv = textView, let ts = tv.textStorage else {
            bold.toggle()
            return
        }
        bold.toggle()
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = self.applyBoldItalic(to: font, bold: self.bold, italic: self.italic)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentFont()
        tv.window?.makeFirstResponder(tv)
    }

    func toggleItalic() {
        guard let tv = textView, let ts = tv.textStorage else {
            italic.toggle()
            return
        }
        italic.toggle()
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = self.applyBoldItalic(to: font, bold: self.bold, italic: self.italic)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentFont()
        tv.window?.makeFirstResponder(tv)
    }

    func toggleUnderline() {
        guard let tv = textView, let ts = tv.textStorage else {
            underline.toggle()
            return
        }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.underlineStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.underlineStyle, range: attrRange)
                } else {
                    ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        underline.toggle()
        if underline {
            tv.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .underlineStyle)
        }
        tv.window?.makeFirstResponder(tv)
    }

    func toggleStrikethrough() {
        guard let tv = textView, let ts = tv.textStorage else {
            strikethrough.toggle()
            return
        }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.strikethroughStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.strikethroughStyle, range: attrRange)
                } else {
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        strikethrough.toggle()
        if strikethrough {
            tv.typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .strikethroughStyle)
        }
        tv.window?.makeFirstResponder(tv)
    }

    func applyAlignment() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = NSRange(location: 0, length: ts.length)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = alignment
        ts.beginEditing()
        ts.addAttribute(.paragraphStyle, value: paraStyle, range: range)
        ts.endEditing()
        tv.alignment = alignment
        tv.typingAttributes[.paragraphStyle] = paraStyle
        tv.window?.makeFirstResponder(tv)
    }

    func applyFontSizeChange() {
        guard let tv = textView else { return }
        let font = currentFont()
        lineMetricsDelegate?.fallbackFont = font
        let range = selectedOrAllRange()
        tv.textStorage?.addAttribute(.font, value: font, range: range)
        tv.typingAttributes[.font] = font
    }

    private func applyUniformFontSizeChange() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let font = currentFont()
        lineMetricsDelegate?.fallbackFont = font
        let range = NSRange(location: 0, length: storage.length)
        if range.length > 0 {
            storage.addAttribute(.font, value: font, range: range)
        }
        tv.font = font
        tv.typingAttributes[.font] = font
    }

    func setUniformFontSize(_ requestedSize: CGFloat) {
        let nextSize = min(200, max(8, requestedSize.rounded()))
        guard nextSize != fontSize else { return }
        fontSize = nextSize
        UserDefaults.standard.set(Double(fontSize), forKey: "textFontSize")
        applyUniformFontSizeChange()
        resizeToFit()
        delegate?.textEditingController(self, didChangeFontSize: fontSize)
    }

    func applyColorToLiveText(color: NSColor) {
        guard let tv = textView else { return }
        activeTextColor = color
        let range = selectedOrAllRange()
        if range.length > 0 {
            tv.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
        }
        tv.insertionPointColor = color
        tv.typingAttributes[.foregroundColor] = color
    }

    // MARK: - Show / Create text view

    func beginEditing(_ annotation: Annotation, at index: Int) {
        editingAnnotation = annotation
        editingAnnotationIndex = index
        restoreState(from: annotation)
    }

    func show(
        in parentView: NSView,
        at canvasPoint: NSPoint,
        color: NSColor,
        existingText: NSAttributedString? = nil,
        existingFrame: NSRect = .zero,
        existingRotation: CGFloat = 0,
        insertionCanvasPoint: NSPoint? = nil,
        canvas: TextEditingCanvas
    ) {
        removeChromeView()
        layoutSessionID = layoutRequestGate.beginSession()
        activeCanvas = canvas
        rotation = existingRotation
        activeTextColor = color

        let font = currentFont()
        let minimumSize = TextAnnotationLayout.measure(
            existingText ?? NSAttributedString(string: ""),
            fallbackFont: font
        )
        let viewFrame: NSRect
        if existingFrame != .zero {
            let start = canvas.canvasToView(existingFrame.origin)
            let end = canvas.canvasToView(
                NSPoint(x: existingFrame.maxX, y: existingFrame.maxY)
            )
            viewFrame = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        } else {
            let viewPoint = canvas.canvasToView(canvasPoint)
            viewFrame = TextAnnotationLayout.initialFrame(
                caretCenter: viewPoint,
                size: minimumSize,
                inset: TextAnnotationLayout.textInset
            )
        }

        let chrome = TextEditorChromeView(contentFrame: viewFrame)
        chrome.interactionDelegate = self
        chrome.rotationRadians = existingRotation
        let textView = chrome.textView
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = TextAnnotationLayout.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        let lineMetrics = TextAnnotationLineMetricsDelegate(fallbackFont: font)
        textView.layoutManager?.delegate = lineMetrics
        lineMetricsDelegate = lineMetrics
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        if let existingText {
            textView.textStorage?.setAttributedString(existingText)
        }

        var typingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
        if underline {
            typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if strikethrough {
            typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if glyphStrokeEnabled {
            typingAttributes[.strokeColor] = glyphStrokeColor
            typingAttributes[.strokeWidth] = -6.0
        }
        textView.typingAttributes = typingAttributes
        textView.alignment = alignment

        let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        if range.length > 0 {
            textView.textStorage?.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
            if glyphStrokeEnabled {
                textView.textStorage?.addAttribute(.strokeColor, value: glyphStrokeColor, range: range)
                textView.textStorage?.addAttribute(.strokeWidth, value: -6.0, range: range)
            } else {
                textView.textStorage?.removeAttribute(.strokeColor, range: range)
                textView.textStorage?.removeAttribute(.strokeWidth, range: range)
            }
        }
        textView.textStorage?.delegate = self

        parentView.addSubview(chrome)
        chromeView = chrome
        refreshChromeStyle()
        resizeToFit()
        refreshChromeStrokeColor()
        parentView.window?.makeFirstResponder(textView)
        if let window = parentView.window {
            chrome.setPointerLocation(
                chrome.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            )
        }

        if let insertionCanvasPoint, textView.string.isEmpty == false {
            let viewPoint = canvas.canvasToView(insertionCanvasPoint)
            let textPoint = textView.convert(viewPoint, from: parentView)
            let insertionIndex = min(
                textView.string.utf16.count,
                textView.characterIndexForInsertion(at: textPoint)
            )
            textView.setSelectedRange(NSRange(location: insertionIndex, length: 0))
        }
    }

    // MARK: - Commit / Cancel

    func commit(canvas: TextEditingCanvas) {
        guard let textView, let chromeView else { return }
        resizeToFit()

        let original = editingAnnotation
        let originalIndex = editingAnnotationIndex ?? canvas.annotations.count
        let text = textView.string
        if text.isEmpty {
            if let original {
                canvas.undoStack.append(.deleted(original, originalIndex))
                canvas.redoStack.removeAll()
            }
            clearEditingSession()
            return
        }

        guard let storage = textView.textStorage else {
            clearEditingSession()
            return
        }
        let attributedText = NSAttributedString(attributedString: storage)
        let viewFrame = chromeView.contentFrameInSuperview
        let canvasStart = canvas.viewToCanvas(viewFrame.origin)
        let canvasEnd = canvas.viewToCanvas(NSPoint(x: viewFrame.maxX, y: viewFrame.maxY))
        let canvasFrame = NSRect(
            x: min(canvasStart.x, canvasEnd.x),
            y: min(canvasStart.y, canvasEnd.y),
            width: abs(canvasEnd.x - canvasStart.x),
            height: abs(canvasEnd.y - canvasStart.y)
        )

        let annotation = original ?? Annotation(
            tool: .text,
            startPoint: canvasFrame.origin,
            endPoint: NSPoint(x: canvasFrame.maxX, y: canvasFrame.maxY),
            color: canvas.opacityAppliedColor(for: .text),
            strokeWidth: canvas.currentStrokeWidth
        )
        let snapshot = original?.clone()
        applyCurrentState(
            to: annotation,
            text: text,
            attributedText: attributedText,
            frame: canvasFrame,
            image: TextAnnotationLayout.render(attributedText, size: canvasFrame.size),
            canvas: canvas
        )

        if original != nil {
            canvas.annotations.insert(annotation, at: min(originalIndex, canvas.annotations.count))
            if let snapshot, textAnnotationChanged(annotation, from: snapshot) {
                canvas.undoStack.append(.propertyChange(annotation: annotation, snapshot: snapshot))
                canvas.redoStack.removeAll()
            }
        } else {
            canvas.annotations.append(annotation)
            canvas.undoStack.append(.added(annotation))
            canvas.redoStack.removeAll()
        }
        canvas.annotationDidCommit(annotation)
        clearEditingSession()
    }

    func cancel(canvas: TextEditingCanvas) {
        if let annotation = editingAnnotation {
            let index = min(editingAnnotationIndex ?? canvas.annotations.count, canvas.annotations.count)
            canvas.annotations.insert(annotation, at: index)
        }
        clearEditingSession()
    }

    func dismiss() {
        clearEditingSession()
    }

    // MARK: - Resize

    func resizeToFit() {
        guard let textView,
              let chromeView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let measured = TextAnnotationLayout.intrinsicSize(
            usedRect: layoutManager.usedRect(for: textContainer),
            extraLineFragmentRect: layoutManager.extraLineFragmentRect,
            inset: textView.textContainerInset,
            lineHeight: layoutManager.defaultLineHeight(for: currentFont())
        )
        if abs(measured.width - chromeView.contentSize.width) > 0.01
            || abs(measured.height - chromeView.contentSize.height) > 0.01 {
            chromeView.setContentSize(measured, preservingTopLeft: true)
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            delegate?.textEditingControllerDidChangeGeometry(self)
        }
        refreshChromeStrokeColor()
    }

    /// NSTextStorage calls its delegate while TextKit is still mutating marked
    /// text and glyph state. Defer the forced layout to the next main-loop turn
    /// and coalesce repeated pinyin updates so the frame still follows every
    /// visible input state without re-entering NSLayoutManager.
    private func requestResizeToFit() {
        guard let layoutSessionID else { return }
        layoutRequestGate.request(in: layoutSessionID) { [weak self] in
            self?.resizeToFit()
        }
    }

    func beginExternalInteraction(target: TextAnnotationHitTarget, at parentPoint: NSPoint) {
        guard let chromeView,
              target == .border || target == .rotate || target == .fontSize else { return }
        externalInteraction = target
        textEditorChromeView(chromeView, didBegin: target, at: parentPoint)
    }

    func continueExternalInteraction(at parentPoint: NSPoint) {
        guard let chromeView, externalInteraction != .outside else { return }
        textEditorChromeView(chromeView, didContinue: externalInteraction, at: parentPoint)
    }

    func endExternalInteraction(at parentPoint: NSPoint) {
        guard let chromeView, externalInteraction != .outside else { return }
        let target = externalInteraction
        externalInteraction = .outside
        textEditorChromeView(chromeView, didEnd: target, at: parentPoint)
    }

    func routedHitTest(viewPoint: NSPoint) -> NSView? {
        chromeView?.routedHitTest(atSuperviewPoint: viewPoint)
    }

    func cursor(at viewPoint: NSPoint) -> NSCursor? {
        chromeView?.cursor(atSuperviewPoint: viewPoint)
    }

    private func applyCurrentState(
        to annotation: Annotation,
        text: String,
        attributedText: NSAttributedString,
        frame: NSRect,
        image: NSImage,
        canvas: TextEditingCanvas
    ) {
        annotation.startPoint = frame.origin
        annotation.endPoint = NSPoint(x: frame.maxX, y: frame.maxY)
        annotation.color = activeTextColor ?? canvas.opacityAppliedColor(for: .text)
        annotation.strokeWidth = canvas.currentStrokeWidth
        annotation.attributedText = attributedText
        annotation.text = text
        annotation.fontSize = fontSize
        annotation.isBold = bold
        annotation.isItalic = italic
        annotation.isUnderline = underline
        annotation.isStrikethrough = strikethrough
        annotation.fontFamilyName = fontFamily == "System" ? nil : fontFamily
        annotation.textBgColor = bgEnabled ? bgColor : nil
        annotation.textOutlineColor = outlineEnabled ? outlineColor : nil
        annotation.textGlyphStrokeColor = glyphStrokeEnabled ? glyphStrokeColor : nil
        annotation.textAlignment = alignment
        annotation.textImage = image
        annotation.textDrawRect = frame
        annotation.rotation = rotation
    }

    private func textAnnotationChanged(_ annotation: Annotation, from snapshot: Annotation) -> Bool {
        if annotation.text != snapshot.text
            || annotation.color != snapshot.color
            || annotation.textDrawRect != snapshot.textDrawRect
            || abs(annotation.rotation - snapshot.rotation) > 0.0001
            || annotation.fontSize != snapshot.fontSize
            || annotation.isBold != snapshot.isBold
            || annotation.isItalic != snapshot.isItalic
            || annotation.isUnderline != snapshot.isUnderline
            || annotation.isStrikethrough != snapshot.isStrikethrough
            || annotation.fontFamilyName != snapshot.fontFamilyName
            || annotation.textAlignment != snapshot.textAlignment
            || annotation.textBgColor != snapshot.textBgColor
            || annotation.textOutlineColor != snapshot.textOutlineColor
            || annotation.textGlyphStrokeColor != snapshot.textGlyphStrokeColor {
            return true
        }
        switch (annotation.attributedText, snapshot.attributedText) {
        case let (lhs?, rhs?): return !lhs.isEqual(to: rhs)
        case (nil, nil): return false
        default: return true
        }
    }

    private func refreshChromeStyle() {
        chromeView?.textBackgroundColor = bgEnabled ? bgColor : nil
        chromeView?.textOutlineColor = outlineEnabled ? outlineColor : nil
    }

    private func refreshChromeStrokeColor() {
        guard let chromeView, let activeCanvas else { return }
        let frame = chromeView.contentFrameInSuperview
        let canvasCenter = activeCanvas.viewToCanvas(NSPoint(x: frame.midX, y: frame.midY))
        chromeView.controlStrokeColor = activeCanvas.textEditingStrokeColor(at: canvasCenter)
    }

    func refreshChromeAccentColor() {
        refreshChromeStrokeColor()
    }

    private func removeChromeView() {
        chromeView?.textView.textStorage?.delegate = nil
        chromeView?.textView.layoutManager?.delegate = nil
        chromeView?.removeFromSuperview()
        chromeView = nil
        lineMetricsDelegate = nil
    }

    private func clearEditingSession() {
        layoutRequestGate.invalidate()
        layoutSessionID = nil
        removeChromeView()
        editingAnnotation = nil
        editingAnnotationIndex = nil
        activeCanvas = nil
        activeTextColor = nil
        rotation = 0
        externalInteraction = .outside
    }

    /// Restore formatting state from an existing annotation for re-editing.
    func restoreState(from annotation: Annotation) {
        fontSize = annotation.fontSize
        bold = annotation.isBold
        italic = annotation.isItalic
        underline = annotation.isUnderline
        strikethrough = annotation.isStrikethrough
        fontFamily = annotation.fontFamilyName ?? "System"
        alignment = annotation.textAlignment
        bgEnabled = annotation.textBgColor != nil
        if let bg = annotation.textBgColor { bgColor = bg }
        outlineEnabled = annotation.textOutlineColor != nil
        if let ol = annotation.textOutlineColor { outlineColor = ol }
        glyphStrokeEnabled = annotation.textGlyphStrokeColor != nil
        if let gs = annotation.textGlyphStrokeColor { glyphStrokeColor = gs }
    }

}

extension TextEditingController: TextEditorChromeViewDelegate {
    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didBegin target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    ) {
        view.isManipulating = target == .border
        interactionStartPoint = parentPoint
        interactionStartFrameOrigin = view.frame.origin
        interactionStartRotation = rotation
        interactionCenter = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: view.superview
        )
        interactionStartAngle = TextAnnotationInteraction.angle(
            from: interactionCenter,
            to: parentPoint
        )
        interactionStartFontSize = fontSize
        interactionFontAnchor = view.contentTopLeftInSuperview
        interactionStartDistance = max(
            1,
            TextAnnotationInteraction.distance(from: interactionFontAnchor, to: parentPoint)
        )
    }

    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didContinue target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    ) {
        switch target {
        case .border:
            view.setFrameOrigin(
                NSPoint(
                    x: interactionStartFrameOrigin.x + parentPoint.x - interactionStartPoint.x,
                    y: interactionStartFrameOrigin.y + parentPoint.y - interactionStartPoint.y
                )
            )
            refreshChromeStrokeColor()
            delegate?.textEditingControllerDidChangeGeometry(self)

        case .rotate:
            let currentAngle = TextAnnotationInteraction.angle(
                from: interactionCenter,
                to: parentPoint
            )
            rotation = TextAnnotationInteraction.adjustedRotation(
                original: interactionStartRotation,
                startAngle: interactionStartAngle,
                currentAngle: currentAngle
            )
            view.rotationRadians = rotation
            refreshChromeStrokeColor()
            delegate?.textEditingControllerDidChangeGeometry(self)

        case .fontSize:
            let distance = TextAnnotationInteraction.distance(
                from: interactionFontAnchor,
                to: parentPoint
            )
            let nextSize = TextAnnotationInteraction.scaledFontSize(
                original: interactionStartFontSize,
                startDistance: interactionStartDistance,
                currentDistance: distance
            )
            setUniformFontSize(nextSize)

        case .interior, .outside:
            break
        }
    }

    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didEnd target: TextAnnotationHitTarget,
        at parentPoint: NSPoint
    ) {
        view.isManipulating = false
        if let superview = view.superview {
            view.setPointerLocation(view.convert(parentPoint, from: superview))
        }
        refreshChromeStrokeColor()
        textView?.window?.makeFirstResponder(textView)
        delegate?.textEditingControllerDidChangeGeometry(self)
    }

    func textEditorChromeView(
        _ view: TextEditorChromeView,
        didRequestFontSizeStep step: Int
    ) {
        setUniformFontSize(fontSize + CGFloat(step))
    }
}

extension TextEditingController: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters)
                || editedMask.contains(.editedAttributes) else { return }
        requestResizeToFit()
    }
}
