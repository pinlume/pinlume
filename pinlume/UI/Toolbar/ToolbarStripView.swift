import Cocoa

/// Real NSView container for a row (horizontal) or column (vertical) of ToolbarButtonViews.
/// Dark rounded background matching the existing toolbar look.
class ToolbarStripView: NSView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    private(set) var buttonViews: [ToolbarButtonView] = []
    /// Set to true in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false
    /// Pin owns a custom tooltip panel; ordinary overlay strips keep AppKit's
    /// native tooltip behavior. The strip owns this so state-only button
    /// updates cannot accidentally re-enable a second tooltip source.
    var showsNativeTooltips = true {
        didSet {
            guard oldValue != showsNativeTooltips else { return }
            buttonViews.forEach { button in
                button.toolTip = nativeTooltip(for: button)
            }
        }
    }
    /// Suppress hover visuals/callbacks while a toolbar-initiated drag is moving
    /// the whole toolbar panel under the cursor.
    var suppressesHover = false {
        didSet {
            if suppressesHover {
                for bv in buttonViews { bv.setHovered(false) }
            }
        }
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?

    private let padding: CGFloat = 4
    private let spacing: CGFloat = 2

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Strip-level tracking area: clears all button hovers when the cursor leaves
    /// the whole strip (covers the case where AppKit drops the last button's
    /// mouseExited in a non-activating panel).
    private var stripTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = stripTracking { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        stripTracking = ta
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {
        clearInteractionState(clearPressed: !suppressesHover)
    }

    /// Rebuild buttons from ToolbarButton data.
    func setButtons(_ buttons: [ToolbarButton]) {
        for bv in buttonViews { bv.removeFromSuperview() }
        buttonViews.removeAll()

        for data in buttons {
            let bv = ToolbarButtonView(
                action: data.action,
                sfSymbol: data.sfSymbol,
                tooltip: data.tooltip,
                shortcutAction: data.shortcutAction
            )
            bv.isOn = data.isSelected
            bv.isEnabled = data.isEnabled
            bv.tintColor = data.tintColor
            bv.swatchColor = data.bgColor
            bv.hasContextMenu = data.hasContextMenu
            bv.isSeparator = data.isSeparator
            bv.toolTip = nativeTooltip(for: bv)
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            addSubview(bv)
            buttonViews.append(bv)
        }
        layoutButtons()
    }

    /// Clear hover on every button except `keep`. Called when a button is
    /// entered, to defensively reset any sibling AppKit failed to send
    /// mouseExited to (happens in non-activating glass chrome panels).
    func clearHover(except keep: ToolbarButtonView) {
        if suppressesHover { return }
        for bv in buttonViews where bv !== keep { bv.setHovered(false) }
    }

    func clearInteractionState(
        suppressHoverUntilMouseMoved suppress: Bool = false,
        clearPressed: Bool = true
    ) {
        for bv in buttonViews {
            bv.clearInteractionState(
                suppressHoverUntilMouseMoved: suppress,
                clearPressed: clearPressed)
        }
    }

    /// Update button state without rebuilding views.
    func updateState(from buttons: [ToolbarButton]) {
        for (i, data) in buttons.enumerated() where i < buttonViews.count {
            buttonViews[i].configure(with: data)
            buttonViews[i].toolTip = nativeTooltip(for: buttonViews[i])
        }
    }

    private func nativeTooltip(for button: ToolbarButtonView) -> String? {
        guard showsNativeTooltips, !button.tooltipText.isEmpty else { return nil }
        return ToolShortcutManager.tooltipText(
            base: button.tooltipText,
            toolbarAction: button.action,
            shortcutOwner: button.shortcutAction,
            showConfiguredShortcut: UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips")
        )
    }

    private func layoutButtons() {
        let count = CGFloat(buttonViews.count)
        guard count > 0 else {
            frame.size = .zero
            return
        }

        switch orientation {
        case .horizontal:
            let widths = buttonViews.map { $0.isSeparator ? ToolbarButtonView.separatorWidth : ToolbarButtonView.size }
            let w = widths.reduce(0, +) + max(0, count - 1) * spacing + padding * 2
            let btnSize = ToolbarButtonView.size
            let h = btnSize + padding * 2
            frame.size = NSSize(width: w, height: h)
            // Left-align buttons
            var x = padding
            for (i, bv) in buttonViews.enumerated() {
                let width = widths[i]
                bv.frame = NSRect(x: x, y: padding, width: width, height: btnSize)
                x += width + spacing
            }
        case .vertical:
            let btnSize = ToolbarButtonView.size
            let w = btnSize + padding * 2
            let h = count * btnSize + max(0, count - 1) * spacing + padding * 2
            frame.size = NSSize(width: w, height: h)
            for (i, bv) in buttonViews.enumerated() {
                // First button at top
                bv.frame.origin = NSPoint(x: padding, y: h - padding - btnSize - CGFloat(i) * (btnSize + spacing))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // Consume clicks on gaps between buttons so they don't fall through to OverlayView.
    // In editor mode (passesThrough), let gap clicks pass through so drawing works
    // over the toolbar area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if passesThrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
