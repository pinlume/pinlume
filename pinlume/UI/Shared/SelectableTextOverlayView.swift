import AppKit

@MainActor
final class SelectableTextOverlayView: NSView {
    enum CopyCommandBehavior {
        case selection
        case allRecognizedText
    }

    private var selectionModel = OCRTextSelectionModel()
    private var isDraggingSelection = false
    private var selectionVisible = true
    var copyCommandBehavior: CopyCommandBehavior = .selection
    var onExit: (() -> Void)?
    var onConfirm: (() -> Bool)?
    var onCopyAllRecognizedText: (() -> Bool)?
    var onCopyRequested: ((String) -> Bool)?
    var onInteractionBegan: (() -> Void)?

    var hasSelection: Bool { selectionModel.hasSelection }
    var selectedText: String { selectionModel.selectedText }
    var fullText: String { selectionModel.fullText }
    var hasRecognizedText: Bool { !fullText.isEmpty }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityLabel() -> String? { L("Recognized Text") }

    override func accessibilityValue() -> Any? {
        hasSelection ? selectedText : fullText
    }

    override func isAccessibilityEnabled() -> Bool { hasRecognizedText }

    override func isAccessibilitySelected() -> Bool { hasSelection }

    override func accessibilityPerformPress() -> Bool {
        guard hasRecognizedText else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        window?.firstResponder === self
    }

    func configure(blocks: [RecognizedTextBlock], in imageRect: NSRect) {
        selectionModel.configure(blocks: blocks, imageRect: imageRect)
        selectionVisible = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func clear() {
        selectionModel.configure(blocks: [], imageRect: .zero)
        isDraggingSelection = false
        selectionVisible = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func selectAllText() {
        selectionModel.selectAll()
        selectionVisible = true
        needsDisplay = true
    }

    func clearSelectionHighlights() {
        selectionModel.clearSelection()
        selectionVisible = true
        needsDisplay = true
    }

    @discardableResult
    func copyAllText() -> Bool {
        let text = fullText
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    func copySelection() -> Bool {
        let text = selectedText
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return selectionModel.containsText(at: point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selectionVisible, hasSelection else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.32).setFill()
        for rect in selectionModel.selectionRects where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard selectionModel.beginSelection(at: point) else { return }
        onInteractionBegan?()
        window?.makeFirstResponder(self)
        selectionVisible = true
        isDraggingSelection = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection else { return }
        selectionModel.extendSelection(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingSelection else { return }
        selectionModel.extendSelection(to: convert(event.locationInWindow, from: nil))
        isDraggingSelection = false
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func resetCursorRects() {
        for rect in selectionModel.textRects {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            onExit?()
            return true
        case 36, 76:
            return onConfirm?() ?? false
        default:
            return false
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }

        switch event.keyCode {
        case 0: // A
            selectAllText()
            return hasRecognizedText
        case 8: // C
            let text = hasSelection ? selectedText : fullText
            guard !text.isEmpty else { return false }
            if let onCopyRequested { return onCopyRequested(text) }
            if hasSelection { return copySelection() }
            switch copyCommandBehavior {
            case .selection:
                return copyAllText()
            case .allRecognizedText:
                return onCopyAllRecognizedText?() ?? copyAllText()
            }
        default:
            return false
        }
    }
}
