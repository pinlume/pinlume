import Cocoa
import os.log

enum TransparentSessionMode: Equatable {
    case annotation
    case presentation
}

private let transparentAnnotationLog = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "transparent-annotation"
)

/// A single-screen, screenshot-free annotation session. The desktop remains live behind
/// this panel; only annotation interaction is captured by Pinlume.
@MainActor
final class TransparentAnnotationSessionController {

    var onFinish: ((TransparentAnnotationPinPayload) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private let panel: OverlayWindow
    private let canvas: TransparentAnnotationCanvasView
    private let toolbar = ToolbarStripView(orientation: .horizontal)
    private let optionsRow = ToolOptionsRowView()
    private let mode: TransparentSessionMode
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var didFinish = false
    private var isMoreToolsExpanded = false
    private let tooltip = TransparentToolbarTooltipView(frame: .zero)
    private weak var tooltipAnchor: ToolbarButtonView?

    init(screen: NSScreen, mode: TransparentSessionMode = .annotation) {
        self.screen = screen
        self.mode = mode
        let panel = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.canvas = TransparentAnnotationCanvasView(
            size: screen.frame.size,
            startsWithSelection: mode == .presentation
        )

        panel.title = "Pinlume Transparent Annotation"
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true

        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        canvas.autoresizingMask = [.width, .height]
        canvas.onSelectionReady = { [weak self] _ in
            guard let self else { return }
            self.canvas.setTransparentTool(self.preferredInitialTool())
            transparentAnnotationLog.debug("selection ready screen=\(self.screen.localizedName, privacy: .public) rect=\(self.canvas.selectionRect.debugDescription, privacy: .public)")
            self.rebuildToolbar()
        }
        canvas.onSelectionReset = { [weak self] in
            self?.rebuildToolbar()
        }
        canvas.onSelectionChanged = { [weak self] rect in
            guard let self else { return }
            transparentAnnotationLog.debug("selection changed rect=\(rect.debugDescription, privacy: .public)")
            self.rebuildToolbar()
        }
        canvas.onContentChanged = { [weak self] in
            self?.rebuildToolbar()
        }
        canvas.onToolbarShortcut = { [weak self] action in
            self?.handleToolbarShortcut(action)
        }

        toolbar.showsNativeTooltips = false
        toolbar.onClick = { [weak self] action in
            self?.handleToolbarAction(action)
        }
        toolbar.onHover = { [weak self] action, hovered in
            self?.handleToolbarHover(action, hovered: hovered)
        }
        canvas.addSubview(toolbar)
        canvas.externalToolbarView = toolbar

        optionsRow.isHidden = true
        canvas.addSubview(optionsRow)
        tooltip.isHidden = true
        canvas.addSubview(tooltip)
        canvas.externalChromeContains = { [weak self] point in
            self?.containsToolbarChrome(at: point) ?? false
        }
        canvas.attachExternalToolOptionsRow(optionsRow)

        panel.contentView = canvas
        if mode == .presentation {
            canvas.setTransparentTool(preferredInitialTool())
        }
        transparentAnnotationLog.debug("session prepared mode=\(mode == .presentation ? "presentation" : "annotation", privacy: .public) screen=\(screen.localizedName, privacy: .public) scale=\(screen.backingScaleFactor, privacy: .public)")
        rebuildToolbar()
    }

    convenience init(editing: TransparentAnnotationPinPayload) {
        let payload = editing
        self.init(screen: payload.screen, mode: .annotation)
        canvas.restoreTransparentPayload(payload)
        // Re-entry begins in selection mode so the first operation can be
        // moving/resizing the crop, exactly like an ordinary selected region.
        canvas.setTransparentTool(.select)
        rebuildToolbar()
        transparentAnnotationLog.debug("reedit restored rect=\(payload.cropRect.debugDescription, privacy: .public) scale=\(payload.screen.backingScaleFactor, privacy: .public)")
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
        }
    }

    func show() {
        panel.ignoresMouseEvents = false
        panel.contentView?.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        canvas.refreshCursorAtPointerIfInside()
        installEscapeMonitor()
        transparentAnnotationLog.debug("session shown key=\(self.panel.isKeyWindow, privacy: .public) visible=\(self.panel.isVisible, privacy: .public)")
    }

    func focus() {
        guard panel.isVisible else { return }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(canvas)
        canvas.refreshCursorAtPointerIfInside()
    }

    func cancel() {
        guard panel.isVisible else { return }
        dismiss(notifyCancellation: true)
    }

    func finishForPin() {
        canvas.confirmAnnotationEditing()
        guard let payload = canvas.transparentPinPayload(for: screen) else {
            dismiss(notifyCancellation: true)
            return
        }
        didFinish = true
        onFinish?(payload)
        dismiss(notifyCancellation: false)
    }

    private func rebuildToolbar() {
        guard canvas.isSelectionReady else {
            toolbar.isHidden = true
            optionsRow.isHidden = true
            hideToolbarTooltip()
            return
        }
        hideToolbarTooltip()
        let primaryTools = ToolbarToolPreferences.transparentAnnotationTools(inPrimary: true)
        let secondaryTools = ToolbarToolPreferences.transparentAnnotationTools(inPrimary: false)
        var buttons = (primaryTools + (isMoreToolsExpanded ? secondaryTools : [])).compactMap { tool in
            return ToolbarLayout.annotationToolbarButton(for: tool, selectedTool: canvas.currentTool)
        }
        buttons += [
            ToolbarButton(
                action: .color,
                sfSymbol: "paintpalette",
                tooltip: L("Color"),
                bgColor: canvas.currentColor
            ),
            ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo"), isEnabled: canvas.canUndoHistory),
            ToolbarButton(action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo"), isEnabled: canvas.canRedoHistory),
        ]
        if !secondaryTools.isEmpty {
            var more = ToolbarButton(action: .moreTools, sfSymbol: "ellipsis", tooltip: L("More Tools"))
            more.isSelected = isMoreToolsExpanded
            buttons.append(more)
        }
        buttons.append(ToolbarButton(action: .separator, sfSymbol: nil, tooltip: "", isSeparator: true))
        buttons.append(ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
        if mode == .annotation {
            let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
            if ToolbarActionPreferences.isEnabled(.save, in: enabledActions) {
                buttons.append(ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down.fill", tooltip: saveTooltip))
            }
            if ToolbarActionPreferences.isEnabled(.copy, in: enabledActions) {
                buttons.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
            }
            buttons.append(ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin")))
        } else {
            buttons.append(ToolbarButton(action: .beautify, sfSymbol: "trash", tooltip: L("Clear")))
        }
        toolbar.setButtons(buttons)
        toolbar.isHidden = false

        if canvas.currentTool == .select {
            optionsRow.isHidden = true
        } else {
            canvas.configureExternalToolOptionsRow(optionsRow, fallbackTool: canvas.currentTool)
            optionsRow.isHidden = optionsRow.subviews.isEmpty
        }
        layoutToolbar()
    }

    private var saveTooltip: String {
        switch SaveActionPreference.current {
        case .saveToFolder:
            return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
        case .askWhereToSave:
            return L("Ask where to save")
        }
    }

    private func layoutToolbar() {
        let safeFrame = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let padding: CGFloat = 12
        if mode == .annotation, canvas.isSelectionReady {
            let frames = OverlayToolbarGeometry.frames(
                anchorRect: canvas.selectionRect,
                containerBounds: safeFrame,
                mainSize: toolbar.frame.size,
                optionsSize: optionsRow.isHidden ? nil : optionsRow.frame.size,
                gap: 10,
                rowGap: 8,
                inset: padding
            )
            toolbar.frame.origin = frames.mainFrame.origin
            if let optionsFrame = frames.optionsFrame, !optionsRow.isHidden {
                optionsRow.frame.origin = optionsFrame.origin
            }
            layoutToolbarTooltip()
            return
        }
        let optionsHeight = optionsRow.isHidden ? 0 : optionsRow.frame.height + 8
        let defaultOrigin: NSPoint
        if mode == .annotation, canvas.isSelectionReady {
            defaultOrigin = NSPoint(
                x: canvas.selectionRect.maxX - toolbar.frame.width,
                y: canvas.selectionRect.minY - toolbar.frame.height - 10
            )
        } else {
            defaultOrigin = NSPoint(
                x: safeFrame.maxX - toolbar.frame.width - padding,
                y: safeFrame.minY + padding
            )
        }
        var origin = defaultOrigin
        origin.x = min(max(origin.x, safeFrame.minX + padding), safeFrame.maxX - toolbar.frame.width - padding)
        origin.y = min(
            max(origin.y, safeFrame.minY + padding),
            safeFrame.maxY - toolbar.frame.height - optionsHeight - padding
        )
        toolbar.frame.origin = origin
        if !optionsRow.isHidden {
            let belowToolbar = NSPoint(
                x: min(
                    max(toolbar.frame.midX - optionsRow.frame.width / 2, safeFrame.minX + padding),
                    safeFrame.maxX - optionsRow.frame.width - padding
                ),
                y: toolbar.frame.minY - optionsRow.frame.height - 8
            )
            let preferredOrigin = belowToolbar.y >= safeFrame.minY + padding
                ? belowToolbar
                : NSPoint(x: belowToolbar.x, y: toolbar.frame.maxY + 8)
            optionsRow.frame.origin = NSPoint(
                x: preferredOrigin.x,
                y: min(preferredOrigin.y, safeFrame.maxY - optionsRow.frame.height - padding)
            )
        }
        layoutToolbarTooltip()
    }

    private func preferredInitialTool() -> AnnotationTool {
        ToolbarToolPreferences.isToolEnabled(.pencil) ? .pencil : .select
    }

    private func containsToolbarChrome(at point: NSPoint) -> Bool {
        (toolbar.isHidden == false && toolbar.frame.contains(point))
            || (optionsRow.isHidden == false && optionsRow.frame.contains(point))
            || (tooltip.isHidden == false && tooltip.frame.contains(point))
    }

    private func handleToolbarHover(_ action: ToolbarButtonAction, hovered: Bool) {
        guard hovered,
              let button = toolbar.buttonViews.first(where: { toolbarActionsMatch($0.action, action) }),
              !button.tooltipText.isEmpty,
              isPointerInside(button)
        else {
            if !hovered { hideToolbarTooltip() }
            return
        }
        tooltipAnchor = button
        tooltip.text = ToolShortcutManager.tooltipText(
            base: button.tooltipText,
            toolbarAction: button.action,
            shortcutOwner: button.shortcutAction,
            showConfiguredShortcut: UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips")
        )
        tooltip.isHidden = false
        layoutToolbarTooltip()
    }

    private func toolbarActionsMatch(_ lhs: ToolbarButtonAction, _ rhs: ToolbarButtonAction) -> Bool {
        switch (lhs, rhs) {
        case (.tool(let lhs), .tool(let rhs)): return lhs == rhs
        case (.color, .color), (.undo, .undo), (.redo, .redo), (.moreTools, .moreTools),
             (.pin, .pin), (.beautify, .beautify), (.cancel, .cancel), (.save, .save),
             (.copy, .copy):
            return true
        default: return false
        }
    }

    private func isPointerInside(_ button: ToolbarButtonView) -> Bool {
        guard let window = button.window else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return button.bounds.contains(button.convert(point, from: nil))
    }

    private func hideToolbarTooltip() {
        tooltipAnchor = nil
        tooltip.isHidden = true
    }

    private func layoutToolbarTooltip() {
        guard let tooltipAnchor, !tooltip.isHidden else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]
        let textSize = (tooltip.text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: textSize.width + 14, height: textSize.height + 8)
        let anchorRect = tooltipAnchor.convert(tooltipAnchor.bounds, to: canvas)
        var origin = NSPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.maxY + 6)
        if origin.y + size.height > canvas.bounds.maxY - 8 {
            origin.y = anchorRect.minY - size.height - 6
        }
        tooltip.frame = NSRect(origin: origin, size: size)
    }

    private func handleToolbarAction(_ action: ToolbarButtonAction) {
        let modeName = mode == .presentation ? "presentation" : "annotation"
        transparentAnnotationLog.debug("toolbar action mode=\(modeName, privacy: .public) action=\(String(describing: action), privacy: .public) tool=\(String(describing: self.canvas.currentTool), privacy: .public)")
        switch action {
        case .tool(let tool):
            canvas.setTransparentTool(canvas.currentTool == tool ? .select : tool)
            panel.makeFirstResponder(canvas)
            rebuildToolbar()
        case .color:
            let colorButton = toolbar.buttonViews.first {
                if case .color = $0.action { return true }
                return false
            }
            canvas.showTransparentColorPicker(anchorView: colorButton) { [weak self] in
                self?.rebuildToolbar()
            }
        case .undo:
            canvas.undoTransparentAnnotation()
            rebuildToolbar()
        case .redo:
            canvas.redoTransparentAnnotation()
            rebuildToolbar()
        case .moreTools:
            isMoreToolsExpanded.toggle()
            rebuildToolbar()
        case .copy:
            copyTransparentOutput()
        case .save:
            saveTransparentOutput()
        case .pin:
            finishForPin()
        case .beautify where mode == .presentation:
            canvas.clearTransparentAnnotations()
            rebuildToolbar()
        case .cancel:
            cancel()
        default:
            break
        }
    }

    private func handleToolbarShortcut(_ shortcutAction: ToolShortcutManager.Action) {
        guard let action = ToolShortcutManager.toolbarAction(for: shortcutAction),
              supportsToolbarShortcut(action)
        else { return }
        handleToolbarAction(action)
    }

    private func supportsToolbarShortcut(_ action: ToolbarButtonAction) -> Bool {
        switch action {
        case .tool(let tool):
            return ToolbarToolPreferences.transparentAnnotationTools(inPrimary: true).contains(tool)
                || ToolbarToolPreferences.transparentAnnotationTools(inPrimary: false).contains(tool)
        case .undo, .redo:
            return true
        case .save:
            return mode == .annotation
                && ToolbarActionPreferences.isEnabled(
                    .save,
                    in: ToolbarActionPreferences.enabledRawValuesAfterMigration())
        case .copy:
            return mode == .annotation
                && ToolbarActionPreferences.isEnabled(
                    .copy,
                    in: ToolbarActionPreferences.enabledRawValuesAfterMigration())
        case .pin:
            return mode == .annotation
        case .beautify:
            return mode == .presentation
        default:
            return false
        }
    }

    private func installEscapeMonitor() {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.cancel()
                    return nil
                }
                if (event.keyCode == 36 || event.keyCode == 76), self.canvas.textEditView == nil,
                   self.mode == .annotation {
                    self.finishForPin()
                    return nil
                }
                return event
            }
        }
        if globalEscapeMonitor == nil {
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                self?.cancel()
            }
        }
    }

    private func copyTransparentOutput() {
        guard let image = canvas.transparentOutputImage() else { return }
        ImageEncoder.copyToClipboard(image)
    }

    private func saveTransparentOutput() {
        guard canvas.transparentOutputImage() != nil else { return }
        ImageSaveService.showSavePanel(imageProvider: { [weak canvas] in
            canvas?.transparentOutputImage()
        })
    }

    private func dismiss(notifyCancellation: Bool) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        PopoverHelper.dismiss()
        panel.orderOut(nil)
        panel.close()
        transparentAnnotationLog.debug("session dismissed finished=\(self.didFinish, privacy: .public) cancelled=\(notifyCancellation, privacy: .public)")
        if notifyCancellation && !didFinish {
            onCancel?()
        }
    }
}

private final class TransparentToolbarTooltipView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }
}
