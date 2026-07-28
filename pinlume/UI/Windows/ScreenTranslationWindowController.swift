import AppKit

@MainActor
private final class RepositionableImageView: NSImageView {
    var onPointerDown: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    private var dragStart = NSPoint.zero
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        didDrag = false
        onPointerDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let delta = NSPoint(x: mouse.x - dragStart.x, y: mouse.y - dragStart.y)
        if abs(delta.x) > 1 || abs(delta.y) > 1 { didDrag = true }
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?(didDrag)
    }
}

@MainActor
final class ScreenTranslationWindowController: NSObject, NSWindowDelegate {
    private var primary: NSPanel?
    private var toolbarPanel: NSPanel?
    private var comparison: NSPanel?
    private let imageView = RepositionableImageView()
    private var session: ScreenTranslationSession
    private var showingOriginal = false
    private var comparing = false
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let toolbarActions = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var toolbarContent: NSStackView?
    private var escapeMonitor: Any?
    var onOpenTranslation: ((ScreenTranslationSession) -> Void)?
    var onPin: ((ScreenTranslationSession) -> Void)?
    var onRetranslate: ((ScreenTranslationSession, String, String) -> Void)?
    var onRepositionRequested: ((ScreenTranslationSession, NSRect) -> Void)?
    var onClose: (() -> Void)?

    init(session: ScreenTranslationSession) { self.session = session; super.init() }

    func show() {
        if primary == nil { build() }
        primary?.setFrame(session.globalFrame, display: true)
        positionToolbar()
        showingOriginal = session.displayMode == .original
        imageView.image = showingOriginal ? session.originalImage : session.translatedImage
        primary?.orderFrontRegardless()
        toolbarPanel?.orderFrontRegardless()
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53:
                    self?.close()
                    return nil
                case 36, 76:
                    guard let self else { return nil }
                    self.onPin?(self.session)
                    return nil
                default:
                    return event
                }
            }
        }
    }

    func update(session: ScreenTranslationSession) {
        comparison?.close()
        comparison = nil
        comparing = false
        self.session = session
        primary?.setFrame(session.globalFrame, display: true)
        showingOriginal = session.displayMode == .original
        imageView.image = showingOriginal ? session.originalImage : session.translatedImage
        selectLanguage(session.sourceLanguage, in: sourcePopup)
        selectLanguage(session.targetLanguage, in: targetPopup)
        statusLabel.stringValue = ""
        rebuildToolbarActions()
        positionToolbar()
        show()
    }

    func prepareForRecapture() {
        comparison?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        primary?.orderOut(nil)
    }

    func excludedWindowNumbersForRecapture() -> [CGWindowID] {
        [primary, toolbarPanel, comparison].compactMap { panel in
            guard let panel, panel.windowNumber != 0 else { return nil }
            return CGWindowID(panel.windowNumber)
        }
    }

    func showStatus(_ message: String) {
        statusLabel.stringValue = message
        toolbarContent?.layoutSubtreeIfNeeded()
        positionToolbar()
    }

    func close() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        primary?.close()
        toolbarPanel?.close()
        comparison?.close()
    }

    private func build() {
        let panel = NSPanel(
            contentRect: session.globalFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = session.translatedImage
        imageView.frame = NSRect(origin: .zero, size: session.globalFrame.size)
        imageView.autoresizingMask = [.width, .height]
        panel.contentView = imageView
        primary = panel

        imageView.onPointerDown = { [weak self] in self?.beginReposition() }
        imageView.onDrag = { [weak self] delta in self?.moveTranslation(to: delta) }
        imageView.onDragEnded = { [weak self] moved in self?.finishReposition(moved: moved) }

        configureLanguagePopup(sourcePopup, selected: session.sourceLanguage)
        configureLanguagePopup(targetPopup, selected: session.targetLanguage)
        sourcePopup.setAccessibilityLabel(L("Source Language"))
        targetPopup.setAccessibilityLabel(L("Target Language"))

        toolbarActions.orientation = .horizontal
        toolbarActions.alignment = .centerY
        toolbarActions.spacing = 2
        toolbarActions.setContentHuggingPriority(.required, for: .horizontal)
        toolbarActions.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusLabel.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.75)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true

        let swap = makeToolbarButton(
            .translationPinLanguage,
            symbol: "arrow.left.arrow.right",
            tooltip: L("Swap"),
            action: #selector(swap)
        )
        let toolbar = NSStackView(views: [sourcePopup, swap, targetPopup, toolbarActions, statusLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        toolbar.layer?.cornerRadius = 6
        toolbar.appearance = ToolbarLayout.appearance
        toolbarContent = toolbar
        rebuildToolbarActions()
        toolbar.layoutSubtreeIfNeeded()

        let tools = NSPanel(
            contentRect: NSRect(origin: .zero, size: toolbar.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tools.level = .floating
        tools.hidesOnDeactivate = false
        tools.contentView = toolbar
        toolbar.frame = NSRect(origin: .zero, size: toolbar.fittingSize)
        toolbarPanel = tools
        positionToolbar()
    }

    private func configureLanguagePopup(_ popup: NSPopUpButton, selected: String) {
        popup.removeAllItems()
        for language in TranslationService.availableLanguages {
            popup.addItem(withTitle: language.name)
            popup.lastItem?.representedObject = language.code
        }
        selectLanguage(selected, in: popup)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.appearance = ToolbarLayout.appearance
        popup.widthAnchor.constraint(equalToConstant: 108).isActive = true
    }

    private func rebuildToolbarActions() {
        toolbarActions.arrangedSubviews.forEach {
            toolbarActions.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        addToolbarButton(.translationPinToggle, symbol: "rectangle.split.2x1", tooltip: L("Compare"), action: #selector(toggleCompare), selected: comparing)
        addToolbarButton(
            .translate,
            symbol: "arrow.left.arrow.right.square",
            tooltip: L("Original / Translation"),
            action: #selector(toggleImage),
            dimmed: comparing
        )
        addToolbarButton(.copy, symbol: "doc.on.doc", tooltip: L("Copy Original"), action: #selector(copyOriginal))
        addToolbarButton(.copyText, symbol: "doc.on.doc.fill", tooltip: L("Copy Translation"), action: #selector(copyTranslated))
        addToolbarButton(.ocr, symbol: "character.book.closed", tooltip: L("Open Translation Window"), action: #selector(openTranslation))
        addToolbarButton(.pin, symbol: "pin.fill", tooltip: L("Pin"), action: #selector(pin))
        addToolbarButton(.cancel, symbol: "xmark", tooltip: L("Close"), action: #selector(closeAction))

        guard let toolbar = toolbarContent else { return }
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        toolbar.frame.size = size
        toolbarPanel?.setContentSize(size)
        positionToolbar()
    }

    private func addToolbarButton(
        _ toolbarAction: ToolbarButtonAction,
        symbol: String,
        tooltip: String,
        action: Selector,
        selected: Bool = false,
        dimmed: Bool = false
    ) {
        toolbarActions.addArrangedSubview(makeToolbarButton(
            toolbarAction,
            symbol: symbol,
            tooltip: tooltip,
            action: action,
            selected: selected,
            dimmed: dimmed
        ))
    }

    private func makeToolbarButton(
        _ toolbarAction: ToolbarButtonAction,
        symbol: String,
        tooltip: String,
        action: Selector,
        selected: Bool = false,
        dimmed: Bool = false
    ) -> ToolbarButtonView {
        let button = ToolbarButtonView(action: toolbarAction, sfSymbol: symbol, tooltip: tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: ToolbarButtonView.size).isActive = true
        button.heightAnchor.constraint(equalToConstant: ToolbarButtonView.size).isActive = true
        button.isOn = selected
        if dimmed { button.tintColor = ToolbarLayout.iconColor.withAlphaComponent(0.35) }
        button.onClick = { [weak self] _ in
            guard let self else { return }
            _ = self.perform(action)
        }
        return button
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let source = selectedLanguage(in: sourcePopup), let target = selectedLanguage(in: targetPopup) else { return }
        onRetranslate?(session, source, target)
    }

    @objc private func swap() {
        onRetranslate?(session, session.targetLanguage, session.sourceLanguage)
    }

    @objc private func toggleImage() {
        guard !comparing else { return }
        showingOriginal.toggle()
        session.displayMode = showingOriginal ? .original : .translated
        imageView.image = showingOriginal ? session.originalImage : session.translatedImage
    }

    @objc private func toggleCompare() {
        if comparing {
            comparison?.close()
            comparison = nil
            comparing = false
            showingOriginal = false
            session.displayMode = .translated
            imageView.image = session.translatedImage
            rebuildToolbarActions()
            return
        }
        guard let imageFrame = primary?.frame,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(imageFrame) }),
              let frame = ScreenTranslationGeometry.comparisonFrame(primary: imageFrame, visibleFrame: screen.visibleFrame)
        else {
            statusLabel.stringValue = L("Not enough space for comparison")
            NSSound.beep()
            return
        }
        imageView.image = session.originalImage
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        let image = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        image.image = session.translatedImage
        image.imageScaling = .scaleAxesIndependently
        panel.contentView = image
        panel.orderFrontRegardless()
        comparison = panel
        comparing = true
        statusLabel.stringValue = ""
        rebuildToolbarActions()
    }

    @objc private func copyOriginal() { copy(session.originalText) }
    @objc private func copyTranslated() { copy(session.translatedText) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openTranslation() { onOpenTranslation?(session) }
    @objc private func pin() { onPin?(session) }
    @objc private func closeAction() { close() }

    private func selectedLanguage(in popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func selectLanguage(_ code: String, in popup: NSPopUpButton) {
        guard let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == code }) else { return }
        popup.selectItem(at: index)
    }

    private func positionToolbar() {
        guard let imageFrame = primary?.frame, let toolbarPanel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(imageFrame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? imageFrame
        let size = toolbarPanel.frame.size
        let below = NSPoint(x: imageFrame.minX, y: imageFrame.minY - size.height - 4)
        let above = NSPoint(x: imageFrame.minX, y: imageFrame.maxY + 4)
        let preferred = visible.contains(NSRect(origin: below, size: size)) ? below : above
        toolbarPanel.setFrameOrigin(NSPoint(
            x: min(max(preferred.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(preferred.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        ))
    }

    func windowDidMove(_ notification: Notification) {
        positionToolbar()
    }

    private var repositionStartFrame = NSRect.zero

    private func beginReposition() {
        if comparing {
            comparison?.close()
            comparison = nil
            comparing = false
            rebuildToolbarActions()
        }
        showingOriginal = true
        session.displayMode = .original
        imageView.image = session.originalImage
        repositionStartFrame = primary?.frame ?? session.globalFrame
    }

    private func moveTranslation(to delta: NSPoint) {
        guard let primary else { return }
        primary.setFrameOrigin(NSPoint(
            x: repositionStartFrame.origin.x + delta.x,
            y: repositionStartFrame.origin.y + delta.y))
        positionToolbar()
    }

    private func finishReposition(moved: Bool) {
        guard moved, let primary else { return }
        let frame = primary.frame
        session = ScreenTranslationSession(
            originalImage: session.originalImage,
            translatedImage: session.translatedImage,
            translatedBlocks: session.translatedBlocks,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage,
            globalFrame: frame,
            originalBlocks: session.originalBlocks,
            translatedSelectionBlocks: session.translatedSelectionBlocks,
            displayMode: .original)
        onRepositionRequested?(session, frame)
    }

    func windowWillClose(_ notification: Notification) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        toolbarPanel?.orderOut(nil)
        comparison?.close()
        onClose?()
    }
}
