import Cocoa
import Carbon
import ServiceManagement
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Settings window that intercepts Cmd+Q to close itself instead of quitting the app.
private class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 12 || event.keyCode == 13 {  // Q / W
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A layer-backed settings card that resolves dynamic system colors against
/// its own effective appearance instead of freezing whichever appearance was
/// current while the settings controller was being constructed.
private final class AppearanceAwareSettingsCardView: NSView {
    private let fillAlpha: CGFloat
    private let cardCornerRadius: CGFloat
    private let cardBorderWidth: CGFloat

    init(fillAlpha: CGFloat = 0.5, cornerRadius: CGFloat = 6, borderWidth: CGFloat = 1) {
        self.fillAlpha = fillAlpha
        cardCornerRadius = cornerRadius
        cardBorderWidth = borderWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(fillAlpha)
                .cgColor
            layer?.cornerRadius = cardCornerRadius
            layer?.borderWidth = cardBorderWidth
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    // MARK: - Toolbar tab definitions
    private struct TabDef {
        let id: String
        let label: String
        let symbolName: String
        let legacyImageName: String  // fallback for older macOS if needed
    }
    private static var tabDefs: [TabDef] {
        var tabs: [TabDef] = [
            TabDef(id: "general",   label: "General",   symbolName: "gearshape",                 legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "capture",   label: "Capture",   symbolName: "camera.viewfinder",         legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "shortcuts", label: "Shortcuts", symbolName: "keyboard",                  legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "tools",     label: "Tools",     symbolName: "paintbrush",                legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "recording", label: "Recording", symbolName: "record.circle",             legacyImageName: NSImage.preferencesGeneralName),
        ]
        #if !OFFLINE
        tabs.append(TabDef(id: "uploads", label: "Uploads", symbolName: "icloud.and.arrow.up", legacyImageName: NSImage.preferencesGeneralName))
        #endif
        tabs.append(TabDef(id: "about", label: "About", symbolName: "info.circle", legacyImageName: NSImage.preferencesGeneralName))
        return tabs
    }

    private var tabContentContainer: NSView!
    private var tabContentViews: [String: NSView] = [:]
    private var currentTabID: String = "general"


    private var hotkeyFields: [HotkeyManager.HotkeySlot: NSTextField] = [:]
    private var hotkeyButtons: [HotkeyManager.HotkeySlot: NSButton] = [:]
    private var recordingSlot: HotkeyManager.HotkeySlot?
    private var toolShortcutFields: [ToolShortcutManager.Action: NSTextField] = [:]
    private var toolShortcutButtons: [ToolShortcutManager.Action: NSButton] = [:]
    private var showToolShortcutsInTooltipsCheckbox: NSButton!
    private var recordingToolAction: ToolShortcutManager.Action?
    private var interactionShortcutPopups: [InteractionShortcutManager.Action: NSPopUpButton] = [:]
    private var savePathField: NSTextField!
    private var saveActionPopup: NSPopUpButton!
    private var ocrActionPopup: NSPopUpButton!
    private var copySoundCheckbox: NSButton!
    // rememberSelectionCheckbox removed — selection is always saved for "Capture Last Area"
    private var thumbnailCheckbox: NSButton!
    private var thumbnailAutoDismissStepper: NSStepper!
    private var thumbnailAutoDismissField: NSTextField!
    private var thumbnailStackingPopup: NSPopUpButton!
    private var thumbnailCornerPopup: NSPopUpButton!
    private var pinCompactShowsPartialImageCheckbox: NSButton!
    private var pinZoomAnchorCheckbox: NSButton!
    private var pinWheelZoomCheckbox: NSButton!
    private var pinMagnifyZoomCheckbox: NSButton!
    private var pinSmoothZoomCheckbox: NSButton!
    private var historyUnlimitedCheckbox: NSButton!
    private var historyOrderByLastEditCheckbox: NSButton!
    private var thumbnailScaleLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var hideMenuBarIconCheckbox: NSButton!
    private var menuBarIconModePopup: NSPopUpButton!
    private var menuBarIconPresetPopup: NSPopUpButton!
    private var menuBarIconSymbolField: NSTextField!

    /// Curated SF Symbol quick-picks for the menu bar icon. Free text is still allowed.
    private static let menuBarIconPresetSymbols = [
        "camera.viewfinder", "camera", "camera.fill", "camera.aperture",
        "viewfinder", "crop", "crop.rotate", "scissors",
        "rectangle.dashed", "square.dashed", "photo", "record.circle",
    ]
    private var historySizeField: NSTextField!
    private var historySizeStepper: NSStepper!
    private var snapGuidesCheckbox: NSButton!
    private var boundarySnapCheckbox: NSButton!
    private var ignoreWindowOcclusionCheckbox: NSButton!
    private var captureCursorCheckbox: NSButton!
    private var doubleClickToCopyCheckbox: NSButton!
    private var hideCaptureInstructionsCheckbox: NSButton!
    private var disableSelectionShadowCheckbox: NSButton!
    private var translateSelectedTextCheckbox: NSButton!
    private var filenameTemplateField: NSTextField!
    private var filenameTemplatePreview: NSTextField!
    private var recordingFilenameTemplateField: NSTextField!
    private var recordingFilenameTemplatePreview: NSTextField!
    private var accentColorWell: NSColorWell!
    private var iconColorWell: NSColorWell!
    private var bgColorWell: NSColorWell!
    private var applicationAppearancePopup: NSPopUpButton!
    private var themePresetPopup: NSPopUpButton!
    private var settingsProfilePopup: NSPopUpButton!
    private var settingsProfileRenameButton: NSButton!
    private var settingsProfileCopyButton: NSButton!
    private var settingsProfileImportButton: NSButton!
    private var settingsProfileExportButton: NSButton!
    private var settingsProfileDeleteButton: NSButton!
    private let settingsProfileStore = SettingsProfileStore()
    private var settingsProfileDocument: SettingsProfileDocument?
    private var isApplyingSettingsProfile = false
    private var isLoadingSettings = false
    private var profileCaptureScheduled = false
    private var quickModePopup: NSPopUpButton!
    private var imageFormatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var qualityRowLabel: NSTextField!
    private var downscaleRetinaCheckbox: NSButton!
    private var captureMenuOrderRowsStack: NSStackView?
    private var captureMenuMoreRowsStack: NSStackView?
    private var primaryToolsRowsStack: NSStackView?
    private var secondaryToolsRowsStack: NSStackView?
    // embedColorProfileCheckbox removed — native color profile is always embedded
    private var localMonitor: Any?
    #if !OFFLINE
    private var imgbbKeyField: NSTextField!
    private weak var uploadsStack: NSStackView?
    private var providerPopup: NSPopUpButton!
    private var uploadConfirmCheckbox: NSButton!
    private var gdriveSignInBtn: NSButton!
    private var gdriveStatusLabel: NSTextField!
    // S3 tab controls
    private var s3EndpointField: NSTextField!
    private var s3RegionField: NSTextField!
    private var s3BucketField: NSTextField!
    private var s3AccessKeyField: NSTextField!
    private var s3SecretKeyField: NSSecureTextField!
    private var s3PublicURLField: NSTextField!
    private var s3PathPrefixField: NSTextField!
    private var s3TestBtn: NSButton!
    private var s3StatusLabel: NSTextField!
    #endif
    // Recording tab controls
    private var recordingFPSPopup: NSPopUpButton!
    private var recordingQualityPopup: NSPopUpButton!
    private var recordingOnStopPopup: NSPopUpButton!
    private var recSavePathField: NSTextField!
    // Webcam controls
    private var webcamPositionPopup: NSPopUpButton!
    private var webcamSizePopup: NSPopUpButton!
    private var webcamShapePopup: NSPopUpButton!
    // Scroll capture controls
    private var scrollAutoScrollCheckbox: NSButton!
    private var scrollSpeedPopup: NSPopUpButton!
    private var scrollMaxHeightField: NSTextField!
    private var scrollMaxHeightStepper: NSStepper!
    private var scrollFrozenDetectionCheckbox: NSButton!
    private var languagePopup: NSPopUpButton!
    private var translationProviderPopup: NSPopUpButton!
    private var googleTranslationAllowedCheckbox: NSButton!
    private var translationProviderStatusLabel: NSTextField!

    var onHotkeyChanged: (() -> Void)?
    var onStorageCleanup: ((AppStorageCleanupOptions, @escaping () -> Void) -> Void)?

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(BuildVariant.displayName) \(L("Settings"))"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 460)
        super.init(window: window)
        window.delegate = self
        setupUI()
        loadSettings()
        loadSettingsProfileDocument()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopShortcutRecording()
        stopToolShortcutRecording()
    }

    // MARK: - Top-level layout

    private func setupUI() {
        guard let window = window, let cv = window.contentView else { return }

        // Toolbar (preference style — icon + label, Shottr-like)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("general")
        // Re-apply content size after toolbar install, since NSToolbar can
        // resize the window to fit its items.
        //
        // Width went from 560 → 620 to accommodate longer translated
        // strings (issue #130 — Polish "Szybkie przechwycenie:" + the
        // "Automatycznie zamazuj dane wrażliwe" checkbox both overflowed
        // the old layout). The extra 60pt flows evenly across the two
        // toggle-grid columns so Polish/German/Dutch labels fit on one
        // line instead of wrapping.
        window.setContentSize(NSSize(width: 620, height: 520))
        window.minSize = NSSize(width: 620, height: 460)

        // Build all tab content views up front (preserves existing behavior — nothing lazy-created)
        tabContentViews["general"]   = makeGeneralTabView()
        tabContentViews["capture"]   = makeCaptureTabView()
        tabContentViews["shortcuts"] = makeShortcutsTabView()
        tabContentViews["tools"]     = makeToolsTabView()
        tabContentViews["recording"] = makeRecordingTabView()
        #if !OFFLINE
        tabContentViews["uploads"] = makeUploadsTabView()
        #endif
        tabContentViews["about"]     = makeAboutTabView()

        // Container that swaps content views
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tabContentContainer = container

        // Footer separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Footer labels
        let madeBy = NSTextField(
            labelWithString: "\(L("Made by")) \(AppIdentity.maintainerName)")
        madeBy.font = NSFont.systemFont(ofSize: 11)
        madeBy.textColor = .secondaryLabelColor
        madeBy.translatesAutoresizingMaskIntoConstraints = false

        let maintainerLinkTitle = AppIdentity.maintainerURL.absoluteString
            .replacingOccurrences(of: "https://", with: "")
        let linkBtn = NSButton(
            title: maintainerLinkTitle, target: self, action: #selector(openGitHub))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.font = NSFont.systemFont(ofSize: 11)
        linkBtn.attributedTitle = NSAttributedString(string: maintainerLinkTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        linkBtn.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [madeBy, NSView(), linkBtn])
        footerStack.orientation = .horizontal
        footerStack.spacing = 0
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(container)
        cv.addSubview(sep)
        cv.addSubview(footerStack)

        NSLayoutConstraint.activate([
            // Content container fills above the footer
            container.topAnchor.constraint(equalTo: cv.topAnchor),
            container.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: sep.topAnchor),

            // Footer separator
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -6),
            sep.heightAnchor.constraint(equalToConstant: 1),

            // Footer
            footerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            footerStack.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Show initial tab
        showTab(id: "general")
    }

    private func showTab(id: String, reloadDynamicTabs: Bool = true) {
        guard let container = tabContentContainer, let view = tabContentViews[id] else { return }
        for sub in container.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentTabID = id
        window?.title = "\(BuildVariant.displayName) \(L("Settings")) — \(L(Self.tabDefs.first(where: { $0.id == id })?.label ?? ""))"
        #if !OFFLINE
        if reloadDynamicTabs && id == "uploads" {
            reloadUploadsTab()
        }
        #endif
    }

    @objc private func toolbarTabSelected(_ sender: NSToolbarItem) {
        showTab(id: sender.itemIdentifier.rawValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.tabDefs.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let def = Self.tabDefs.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L(def.label)
        item.paletteLabel = L(def.label)
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: def.symbolName, accessibilityDescription: def.label)
        } else {
            item.image = NSImage(named: def.legacyImageName)
        }
        item.target = self
        item.action = #selector(toolbarTabSelected(_:))
        return item
    }

    // MARK: - General Tab

    /// NSStackView subclass with flipped coordinates so content pins to the top
    /// of its scroll view (default AppKit origin is bottom-left, which would
    /// push short content to the bottom of a tall clip view).
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// Small SF Symbol icon that reports hover enter/exit via callback. Used for
    /// hover-to-show info popovers next to settings controls.
    fileprivate final class HoverPopoverIconView: NSImageView {
        /// Called with (the view, true) on hover enter and (view, false) on exit.
        var onHover: ((NSView, Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        init(image: NSImage?, tintColor: NSColor, toolTip: String?) {
            super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            self.image = image
            self.contentTintColor = tintColor
            self.toolTip = toolTip
            self.imageScaling = .scaleProportionallyDown
            self.translatesAutoresizingMaskIntoConstraints = false
            self.widthAnchor.constraint(equalToConstant: 16).isActive = true
            self.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
        override func mouseExited(with event: NSEvent)  { onHover?(self, false) }
    }

    /// Creates a scrollable vertical stack matching the layout used by all settings tabs.
    private func makeSettingsScrollStack() -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return (scroll, stack)
    }

    /// Finalizes a settings tab by wiring the stack into the scroll view.
    private func finalizeSettingsStack(scroll: NSScrollView, stack: NSStackView) {
        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: clipView.widthAnchor),
            // no bottom constraint — stack grows to fit content, scroll handles overflow
        ])
    }

    private func makeGeneralTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Language ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Language")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        languagePopup = NSPopUpButton()
        for lang in LanguageManager.availableLanguages {
            languagePopup.addItem(withTitle: lang.code == "system" ? L("System Default") : lang.name)
        }
        let currentLang = LanguageManager.shared.currentLanguage
        if let idx = LanguageManager.availableLanguages.firstIndex(where: { $0.code == currentLang }) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Language:"), controls: [languagePopup]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let langNote = NSTextField(wrappingLabelWithString: L("Restart the app to fully apply the new language."))
        langNote.font = NSFont.systemFont(ofSize: 10)
        langNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(langNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Application ──────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Application")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: L("Launch at login"), target: self, action: #selector(launchAtLoginChanged(_:)))
        stack.addArrangedSubview(indented(launchAtLoginCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        hideMenuBarIconCheckbox = NSButton(checkboxWithTitle: L("Hide menu bar icon"), target: self, action: #selector(hideMenuBarIconChanged(_:)))
        stack.addArrangedSubview(indented(hideMenuBarIconCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let hideNote = NSTextField(wrappingLabelWithString: L("Hotkeys still work. To show the icon again, re-launch Pinlume."))
        hideNote.font = NSFont.systemFont(ofSize: 10)
        hideNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideNote))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Menu bar icon: keep the bundled icon or pick any SF Symbol.
        menuBarIconModePopup = NSPopUpButton()
        menuBarIconModePopup.addItem(withTitle: L("Default"))
        menuBarIconModePopup.addItem(withTitle: L("Custom symbol"))
        menuBarIconModePopup.target = self
        menuBarIconModePopup.action = #selector(menuBarIconModeChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Menu bar icon:"), controls: [menuBarIconModePopup]))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        menuBarIconSymbolField = NSTextField()
        menuBarIconSymbolField.placeholderString = "camera.viewfinder"
        menuBarIconSymbolField.translatesAutoresizingMaskIntoConstraints = false
        menuBarIconSymbolField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        menuBarIconSymbolField.target = self
        menuBarIconSymbolField.action = #selector(menuBarIconSymbolChanged(_:))
        menuBarIconSymbolField.delegate = self

        // Pull-down quick-picker: index 0 is the "Presets" label, symbols follow.
        menuBarIconPresetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        menuBarIconPresetPopup.addItem(withTitle: L("Presets"))
        for symbol in Self.menuBarIconPresetSymbols {
            menuBarIconPresetPopup.addItem(withTitle: symbol)
        }
        menuBarIconPresetPopup.target = self
        menuBarIconPresetPopup.action = #selector(menuBarIconPresetChanged(_:))

        let iconSymbolRow = NSStackView(views: [menuBarIconSymbolField, menuBarIconPresetPopup])
        iconSymbolRow.orientation = .horizontal
        iconSymbolRow.spacing = 8
        iconSymbolRow.alignment = .centerY
        stack.addArrangedSubview(indented(iconSymbolRow))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let iconNote = NSTextField(wrappingLabelWithString: L("Enter any SF Symbol name (e.g. camera.fill) or pick a preset. Browse names in Apple's SF Symbols app. Invalid names fall back to the default icon."))
        iconNote.font = NSFont.systemFont(ofSize: 10)
        iconNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(iconNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        let urlSchemeCheckbox = NSButton(checkboxWithTitle: String(format: L("Enable %@:// URL scheme"), BuildVariant.actionsURLScheme), target: self, action: #selector(urlSchemeChanged(_:)))
        urlSchemeCheckbox.state = (UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true) ? .on : .off

        let urlSchemeInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("URL scheme info")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show supported URL scheme commands")
        )
        urlSchemeInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showURLSchemeInfoPopover(near: sourceView) }
            // On exit, do nothing — the popover is .transient, so clicking
            // anywhere outside it closes it. This lets the user move into the
            // popover to read/copy without it vanishing.
        }

        let urlSchemeRow = NSStackView(views: [urlSchemeCheckbox, urlSchemeInfoIcon])
        urlSchemeRow.orientation = .horizontal
        urlSchemeRow.spacing = 4
        urlSchemeRow.alignment = .centerY
        stack.addArrangedSubview(indented(urlSchemeRow))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── Pin ──────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Pin")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        pinCompactShowsPartialImageCheckbox = NSButton(
            checkboxWithTitle: L("Show partial image in compact Pin"),
            target: self,
            action: #selector(pinCompactShowsPartialImageChanged(_:))
        )
        stack.addArrangedSubview(indented(pinCompactShowsPartialImageCheckbox))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── Storage and diagnostics ──────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Storage & Diagnostics")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let diagnosticLogging = NSButton(
            checkboxWithTitle: L("Enable diagnostic logging (status, timing, coordinates, and errors only)"),
            target: self,
            action: #selector(diagnosticLoggingChanged(_:))
        )
        diagnosticLogging.state = DiagnosticLogStore.isEnabled ? .on : .off
        stack.addArrangedSubview(indented(diagnosticLogging))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let diagnosticNote = NSTextField(wrappingLabelWithString: L("Disabled by default. Keeps up to 7 days or 2 MB; never writes screenshots, OCR text, clipboard contents, or keys."))
        diagnosticNote.font = NSFont.systemFont(ofSize: 10)
        diagnosticNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(diagnosticNote))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let clearStorageButton = NSButton(title: L("Clear Local Data…"), target: self, action: #selector(clearLocalStorage(_:)))
        clearStorageButton.bezelStyle = .rounded
        stack.addArrangedSubview(indented(clearStorageButton))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Appearance ───────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Appearance")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        applicationAppearancePopup = NSPopUpButton()
        for preference in ApplicationAppearancePreference.allCases {
            let title: String
            switch preference {
            case .system: title = L("System Default")
            case .light: title = L("Light")
            case .dark: title = L("Dark")
            }
            applicationAppearancePopup.addItem(withTitle: title)
            applicationAppearancePopup.lastItem?.representedObject = preference.rawValue
        }
        applicationAppearancePopup.target = self
        applicationAppearancePopup.action = #selector(applicationAppearanceChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Interface Theme:"), controls: [applicationAppearancePopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Toolbar color preset dropdown
        themePresetPopup = NSPopUpButton()
        for scheme in ToolbarColorScheme.all {
            themePresetPopup.addItem(withTitle: L(scheme.name))
            themePresetPopup.lastItem?.representedObject = scheme.id.rawValue
        }
        themePresetPopup.addItem(withTitle: L("Custom"))
        themePresetPopup.lastItem?.representedObject = ToolbarColorSchemeID.custom.rawValue
        themePresetPopup.target = self
        themePresetPopup.action = #selector(themePresetChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Color Scheme:"), controls: [themePresetPopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Three color wells in a single row with labels underneath
        accentColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        accentColorWell.color = ToolbarLayout.accentColor
        accentColorWell.target = self
        accentColorWell.action = #selector(accentColorChanged(_:))

        iconColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        iconColorWell.color = ToolbarLayout.iconColor
        iconColorWell.target = self
        iconColorWell.action = #selector(iconColorChanged(_:))

        bgColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        bgColorWell.color = ToolbarLayout.bgColor
        bgColorWell.target = self
        bgColorWell.action = #selector(bgColorChanged(_:))

        let accentCol = makeColorColumn(well: accentColorWell, caption: L("Accent"))
        let iconCol   = makeColorColumn(well: iconColorWell,   caption: L("Icon"))
        let bgCol     = makeColorColumn(well: bgColorWell,     caption: L("Background"))

        let colorsRow = NSStackView(views: [accentCol, iconCol, bgCol])
        colorsRow.orientation = .horizontal
        colorsRow.alignment = .top
        colorsRow.spacing = 20
        stack.addArrangedSubview(indented(colorsRow))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(sectionHeader(L("Configuration")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        settingsProfilePopup = NSPopUpButton()
        settingsProfilePopup.target = self
        settingsProfilePopup.action = #selector(settingsProfileChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Configuration:"), controls: [settingsProfilePopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        settingsProfileRenameButton = compactButton(L("Rename"), action: #selector(renameSettingsProfile(_:)), width: Self.settingsProfileActionButtonWidth)
        settingsProfileCopyButton = compactButton(L("Copy Configuration"), action: #selector(copySettingsProfile(_:)), width: Self.settingsProfileActionButtonWidth)
        settingsProfileImportButton = compactButton(L("Import"), action: #selector(importSettingsProfile(_:)), width: Self.settingsProfileActionButtonWidth)
        settingsProfileExportButton = compactButton(L("Export"), action: #selector(exportSettingsProfile(_:)), width: Self.settingsProfileActionButtonWidth)
        settingsProfileDeleteButton = compactButton(L("Delete"), action: #selector(deleteSettingsProfile(_:)), width: Self.settingsProfileActionButtonWidth)
        let profileActions = NSStackView(views: [settingsProfileRenameButton, settingsProfileCopyButton, settingsProfileImportButton, settingsProfileExportButton, settingsProfileDeleteButton])
        profileActions.orientation = .horizontal
        profileActions.alignment = .centerY
        profileActions.spacing = 8
        stack.addArrangedSubview(indented(profileActions))
        let profileNote = NSTextField(wrappingLabelWithString: L("Changes to the selected profile are saved automatically."))
        profileNote.font = NSFont.systemFont(ofSize: 10)
        profileNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(profileNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Sync preset popup to current colors
        updateThemePresetSelection()

        finalizeSettingsStack(scroll: scroll, stack: stack)
        return scroll
    }

    @objc private func diagnosticLoggingChanged(_ sender: NSButton) {
        DiagnosticLogStore.setEnabled(sender.state == .on)
    }

    @objc private func clearLocalStorage(_ sender: NSButton) {
        let history = NSButton(checkboxWithTitle: L("Screenshot history and editable annotations"), target: nil, action: nil)
        let clipboard = NSButton(checkboxWithTitle: L("Clipboard image backups"), target: nil, action: nil)
        let pins = NSButton(checkboxWithTitle: L("Restored pins (closes current pins immediately)"), target: nil, action: nil)
        let diagnostics = NSButton(checkboxWithTitle: L("Diagnostic logs"), target: nil, action: nil)

        let historyTitle = history.title
        let clipboardTitle = clipboard.title
        let pinsTitle = pins.title
        let diagnosticsTitle = diagnostics.title
        let calculating = L("Calculating…")
        history.title = "\(historyTitle) (\(calculating))"
        clipboard.title = "\(clipboardTitle) (\(calculating))"
        pins.title = "\(pinsTitle) (\(calculating))"
        diagnostics.title = "\(diagnosticsTitle) (\(calculating))"

        let note = NSTextField(wrappingLabelWithString: L("Images saved to a folder you choose will not be deleted."))
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 178))
        note.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(note)

        // Keep each category as the checkbox's own inline title. NSStackView's
        // width alignment centers short rows, which made this alert look like
        // two staggered columns as sizes arrived asynchronously.
        let rows = [history, clipboard, pins, diagnostics]
        rows.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview($0)
        }

        var constraints = [
            note.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -10),
        ]
        var previous: NSView = note
        for checkbox in rows {
            constraints.append(checkbox.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 10))
            constraints.append(checkbox.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 10))
            constraints.append(checkbox.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor, constant: -10))
            previous = checkbox
        }
        constraints.append(previous.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor, constant: -8))
        NSLayoutConstraint.activate(constraints)

        let alert = NSAlert()
        alert.messageText = L("Choose local data to clear")
        alert.informativeText = ""
        alert.accessoryView = accessory
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Clear Selected Data"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.isEnabled = false

        func updateSizes(_ snapshot: AppStorageUsageSnapshot) {
            history.title = "\(historyTitle) (\(snapshot.formattedSize(for: .history)))"
            clipboard.title = "\(clipboardTitle) (\(snapshot.formattedSize(for: .clipboard)))"
            pins.title = "\(pinsTitle) (\(snapshot.formattedSize(for: .pins)))"
            diagnostics.title = "\(diagnosticsTitle) (\(snapshot.formattedSize(for: .diagnostics)))"
        }

        AppStorageUsage.calculate { snapshot in
            updateSizes(snapshot)
            alert.buttons.first?.isEnabled = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var options: AppStorageCleanupOptions = []
        if history.state == .on { options.insert(.history) }
        if clipboard.state == .on { options.insert(.clipboard) }
        if pins.state == .on { options.insert(.pins) }
        if diagnostics.state == .on { options.insert(.diagnostics) }
        guard !options.isEmpty, let onStorageCleanup else { return }
        onStorageCleanup(options) {}
    }

    // MARK: - Capture Tab

    private func makeCaptureTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Capture ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Return and Quick Capture always share this output action.
        quickModePopup = NSPopUpButton()
        let outputActions: [(CaptureOutputAction, String)] = [
            (.pinToScreen, L("Pin to Screen")),
            (.saveToFolder, L("Save to file")),
            (.copyToClipboard, L("Copy to clipboard")),
            (.saveAndCopy, L("Save + copy to clipboard")),
            (.doNothing, L("Do nothing")),
        ]
        for (action, title) in outputActions {
            quickModePopup.addItem(withTitle: title)
            quickModePopup.lastItem?.representedObject = action.rawValue
        }
        quickModePopup.target = self
        quickModePopup.action = #selector(quickModeChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Enter / Quick Capture:"), controls: [quickModePopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // OCR & QR action dropdown
        ocrActionPopup = NSPopUpButton()
        ocrActionPopup.addItems(withTitles: [
            L("Show window + copy to clipboard"),
            L("Show window only"),
            L("Copy to clipboard only"),
        ])
        ocrActionPopup.target = self
        ocrActionPopup.action = #selector(ocrActionChanged(_:))

        stack.addArrangedSubview(labeledRow(L("OCR & QR Capture:"), controls: [ocrActionPopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Checkboxes
        copySoundCheckbox = NSButton(checkboxWithTitle: L("Play sound on capture"), target: self, action: #selector(copySoundChanged(_:)))
        thumbnailCheckbox = NSButton(checkboxWithTitle: L("Show floating window after Quick Capture"), target: self, action: #selector(thumbnailChanged(_:)))
        snapGuidesCheckbox = NSButton(checkboxWithTitle: L("Show snap alignment guides"), target: self, action: #selector(snapGuidesChanged(_:)))
        boundarySnapCheckbox = NSButton(checkboxWithTitle: L("Snap selection edges to image boundaries"), target: self, action: #selector(boundarySnapChanged(_:)))
        ignoreWindowOcclusionCheckbox = NSButton(checkboxWithTitle: L("Ignore window occlusion"), target: self, action: #selector(ignoreWindowOcclusionChanged(_:)))
        captureCursorCheckbox = NSButton(checkboxWithTitle: L("Capture mouse cursor in screenshot"), target: self, action: #selector(captureCursorChanged(_:)))
        doubleClickToCopyCheckbox = NSButton(checkboxWithTitle: L("Double-click selection to copy"), target: self, action: #selector(doubleClickToCopyChanged(_:)))
        hideCaptureInstructionsCheckbox = NSButton(checkboxWithTitle: L("Hide capture instructions"), target: self, action: #selector(hideCaptureInstructionsChanged(_:)))
        disableSelectionShadowCheckbox = NSButton(checkboxWithTitle: L("Disable shadow outside selection"), target: self, action: #selector(disableSelectionShadowChanged(_:)))
        translateSelectedTextCheckbox = NSButton(checkboxWithTitle: L("Translate selected text"), target: self, action: #selector(selectedTextTranslationChanged(_:)))
        filenameTemplateField = NSTextField()
        filenameTemplateField.placeholderString = FilenameFormatter.defaultTemplate
        filenameTemplateField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        filenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        filenameTemplateField.target = self
        filenameTemplateField.action = #selector(filenameTemplateCommitted(_:))
        filenameTemplateField.delegate = self
        filenameTemplateField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        filenameTemplatePreview = NSTextField(labelWithString: "")
        filenameTemplatePreview.font = NSFont.systemFont(ofSize: 10)
        filenameTemplatePreview.textColor = .secondaryLabelColor
        filenameTemplatePreview.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(indented(copySoundCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        pinZoomAnchorCheckbox = NSButton(
            checkboxWithTitle: L("Pin zoom anchors to mouse position"),
            target: self,
            action: #selector(pinZoomAnchorChanged(_:))
        )
        stack.addArrangedSubview(indented(pinZoomAnchorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        pinWheelZoomCheckbox = NSButton(checkboxWithTitle: L("Allow Scroll Zoom on Pins"), target: self, action: #selector(pinWheelZoomChanged(_:)))
        stack.addArrangedSubview(indented(pinWheelZoomCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        pinMagnifyZoomCheckbox = NSButton(checkboxWithTitle: L("Allow Trackpad Pinch Zoom on Pins"), target: self, action: #selector(pinMagnifyZoomChanged(_:)))
        stack.addArrangedSubview(indented(pinMagnifyZoomCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        pinSmoothZoomCheckbox = NSButton(checkboxWithTitle: L("Smooth Pin Zoom"), target: self, action: #selector(pinSmoothZoomChanged(_:)))
        stack.addArrangedSubview(indented(pinSmoothZoomCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // This switch owns the preview lifetime controls below it, so keep
        // the setting adjacent instead of mixing it into unrelated capture options.
        stack.addArrangedSubview(indented(thumbnailCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Thumbnail auto-dismiss stepper
        thumbnailAutoDismissField = NSTextField()
        thumbnailAutoDismissField.isEditable = false
        thumbnailAutoDismissField.isSelectable = false
        thumbnailAutoDismissField.alignment = .center
        thumbnailAutoDismissField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        thumbnailAutoDismissStepper = NSStepper()
        thumbnailAutoDismissStepper.minValue = 0
        thumbnailAutoDismissStepper.maxValue = 60
        thumbnailAutoDismissStepper.increment = 1
        thumbnailAutoDismissStepper.target = self
        thumbnailAutoDismissStepper.action = #selector(thumbnailAutoDismissChanged(_:))

        let dismissNote = NSTextField(labelWithString: L("sec (0 = never)"))
        dismissNote.font = NSFont.systemFont(ofSize: 11)
        dismissNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(indented(labeledRow(L("  Dismiss after:"), controls: [thumbnailAutoDismissField!, thumbnailAutoDismissStepper!, dismissNote])))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Thumbnail stacking popup
        thumbnailStackingPopup = NSPopUpButton()
        thumbnailStackingPopup.addItems(withTitles: [L("Stack (keep all)"), L("Replace (show only latest)")])
        thumbnailStackingPopup.target = self
        thumbnailStackingPopup.action = #selector(thumbnailStackingChanged(_:))

        stack.addArrangedSubview(indented(labeledRow(L("  Multiple previews:"), controls: [thumbnailStackingPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        thumbnailCornerPopup = NSPopUpButton()
        thumbnailCornerPopup.addItems(withTitles: [L("Bottom Right"), L("Bottom Left"), L("Top Right"), L("Top Left")])
        thumbnailCornerPopup.target = self
        thumbnailCornerPopup.action = #selector(thumbnailCornerChanged(_:))
        stack.addArrangedSubview(indented(labeledRow(L("  Position:"), controls: [thumbnailCornerPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let sizeSlider = NSSlider(value: UserDefaults.standard.object(forKey: "thumbnailScale") as? Double ?? 1.0,
                                   minValue: 0.5, maxValue: 2.0, target: self, action: #selector(thumbnailScaleChanged(_:)))
        sizeSlider.controlSize = .small
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        thumbnailScaleLabel = NSTextField(labelWithString: scalePercentString(sizeSlider.doubleValue))
        thumbnailScaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        thumbnailScaleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(labeledRow(L("  Preview size:"), controls: [sizeSlider, thumbnailScaleLabel])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(snapGuidesCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(boundarySnapCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(ignoreWindowOcclusionCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(captureCursorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(doubleClickToCopyCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(hideCaptureInstructionsCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(disableSelectionShadowCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(translateSelectedTextCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        appendScrollCaptureSettings(to: stack)

        // ── Output ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Output")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Default save action
        saveActionPopup = NSPopUpButton()
        for action in SaveActionPreference.allCases {
            saveActionPopup.addItem(withTitle: action.title)
            saveActionPopup.lastItem?.representedObject = action.rawValue
        }
        saveActionPopup.target = self
        saveActionPopup.action = #selector(saveActionChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Save action:"), controls: [saveActionPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Save folder
        savePathField = NSTextField()
        savePathField.isEditable = false
        savePathField.isSelectable = false
        savePathField.lineBreakMode = .byTruncatingMiddle

        let browseBtn = NSButton(title: L("Browse…"), target: self, action: #selector(browseSavePath(_:)))
        browseBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow(L("Save folder:"), controls: [savePathField, browseBtn]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Filename template
        let filenameResetBtn = NSButton(title: L("Reset"), target: self, action: #selector(filenameTemplateReset(_:)))
        filenameResetBtn.bezelStyle = .rounded

        let filenameInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("Filename tokens")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show available filename tokens")
        )
        filenameInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showFilenameTemplateInfoPopover(near: sourceView) }
        }

        stack.addArrangedSubview(labeledRow(L("Filename:"), controls: [filenameTemplateField, filenameInfoIcon, filenameResetBtn]))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(filenameTemplatePreview))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        updateFilenamePreview()

        // Image format
        imageFormatPopup = NSPopUpButton()
        for format in ImageEncoder.availableFormats {
            imageFormatPopup.addItem(withTitle: format.displayName)
            imageFormatPopup.lastItem?.representedObject = format.rawValue
        }
        imageFormatPopup.target = self
        imageFormatPopup.action = #selector(imageFormatChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Image format:"), controls: [imageFormatPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Quality (applies to lossy formats: JPEG, HEIC, WebP, AVIF)
        qualitySlider = NSSlider()
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        qualityLabel = NSTextField(labelWithString: String(format: L("%d%%"), 85))
        qualityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        qualityRowLabel = NSTextField(labelWithString: L("Quality:"))
        qualityRowLabel.font = NSFont.systemFont(ofSize: 13)
        qualityRowLabel.alignment = .right
        qualityRowLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityRowLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let qualityRow = NSStackView(views: [qualityRowLabel, qualitySlider, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualityRow.alignment = .centerY
        qualityRow.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(qualityRow)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Downscale Retina
        downscaleRetinaCheckbox = NSButton(checkboxWithTitle: L("Save at standard resolution (1x)"), target: self, action: #selector(downscaleRetinaChanged(_:)))
        stack.addArrangedSubview(indented(downscaleRetinaCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let downscaleNote = NSTextField(labelWithString: L("Halves dimensions on Retina displays, ~4x smaller files"))
        downscaleNote.font = NSFont.systemFont(ofSize: 10)
        downscaleNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(downscaleNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Color profile is always embedded (native display profile) — no toggle needed.

        // History size
        historySizeField = NSTextField()
        historySizeField.isEditable = false
        historySizeField.isSelectable = false
        historySizeField.alignment = .center
        historySizeField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        historySizeStepper = NSStepper()
        historySizeStepper.minValue = 0
        historySizeStepper.maxValue = 50
        historySizeStepper.increment = 1
        historySizeStepper.target = self
        historySizeStepper.action = #selector(historySizeChanged(_:))

        historyUnlimitedCheckbox = NSButton(checkboxWithTitle: L("Unlimited"), target: self, action: #selector(historyUnlimitedChanged(_:)))
        historyUnlimitedCheckbox.font = NSFont.systemFont(ofSize: 11)

        let histNote = NSTextField(labelWithString: L("(0 = off)"))
        histNote.font = NSFont.systemFont(ofSize: 11)
        histNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(labeledRow(L("History size:"), controls: [historySizeField, historySizeStepper, histNote, historyUnlimitedCheckbox]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        historyOrderByLastEditCheckbox = NSButton(
            checkboxWithTitle: L("Order history by last edit"),
            target: self, action: #selector(historyOrderByLastEditChanged(_:)))
        historyOrderByLastEditCheckbox.state = ScreenshotHistory.orderByLastEdit ? .on : .off
        stack.addArrangedSubview(indented(historyOrderByLastEditCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let orderNote = NSTextField(labelWithString: L("Edited screenshots move to the top. Off keeps them in capture order."))
        orderNote.font = NSFont.systemFont(ofSize: 10)
        orderNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(orderNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Menu Bar Menu ───────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Menu Bar Menu")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let menuOrderNote = NSTextField(wrappingLabelWithString: L("Choose which actions appear in the status bar menu and arrange the order of common and additional tools. Settings, version, and quit remain fixed."))
        menuOrderNote.font = NSFont.systemFont(ofSize: 10)
        menuOrderNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(menuOrderNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(makeCaptureMenuOrderView(isPrimary: true)))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let moreTitle = NSTextField(labelWithString: L("More Tools"))
        moreTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(indented(moreTitle))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(makeCaptureMenuOrderView(isPrimary: false)))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let resetMenuOrderButton = NSButton(title: L("Reset to default"), target: self, action: #selector(resetCaptureMenuOrder(_:)))
        resetMenuOrderButton.bezelStyle = .rounded
        stack.addArrangedSubview(indented(resetMenuOrderButton))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        finalizeSettingsStack(scroll: scroll, stack: stack)
        return scroll
    }

    private func makeCaptureMenuOrderView(isPrimary: Bool) -> NSView {
        let box = AppearanceAwareSettingsCardView(fillAlpha: 0.5, cornerRadius: 6, borderWidth: 1)
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rows)
        if isPrimary {
            captureMenuOrderRowsStack = rows
        } else {
            captureMenuMoreRowsStack = rows
        }

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            rows.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])

        rebuildCaptureMenuOrderRows(isPrimary: isPrimary)
        return box
    }

    private func rebuildCaptureMenuOrderRows(isPrimary: Bool? = nil) {
        if isPrimary == nil || isPrimary == true {
            rebuildCaptureMenuOrderRows(isPrimary: true, rows: captureMenuOrderRowsStack)
        }
        if isPrimary == nil || isPrimary == false {
            rebuildCaptureMenuOrderRows(isPrimary: false, rows: captureMenuMoreRowsStack)
        }
    }

    private func rebuildCaptureMenuOrderRows(isPrimary: Bool, rows: NSStackView?) {
        guard let rows else { return }
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let items = isPrimary ? CaptureMenuItemID.primaryItems() : CaptureMenuItemID.moreItems()
        if items.isEmpty {
            let empty = NSTextField(labelWithString: L("No items"))
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            rows.addArrangedSubview(empty)
            return
        }

        for (index, itemID) in items.enumerated() {
            let icon = NSImageView(image: NSImage(systemSymbolName: itemID.displaySymbolName, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let checkbox = NSButton(
                checkboxWithTitle: itemID.displayTitle,
                target: self,
                action: #selector(captureMenuItemEnabledChanged(_:))
            )
            checkbox.tag = itemID.tag
            checkbox.state = CaptureMenuItemID.isEnabled(itemID) ? .on : .off
            checkbox.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

            let spacer = NSView()

            let upButton = captureMenuOrderButton(
                symbolName: "chevron.up",
                action: #selector(moveCaptureMenuItemUp(_:)),
                tag: itemID.tag,
                identifier: isPrimary ? "primary" : "more",
                toolTip: L("Move up"))
            upButton.isEnabled = index > 0

            let downButton = captureMenuOrderButton(
                symbolName: "chevron.down",
                action: #selector(moveCaptureMenuItemDown(_:)),
                tag: itemID.tag,
                identifier: isPrimary ? "primary" : "more",
                toolTip: L("Move down"))
            downButton.isEnabled = index < items.count - 1

            let transferButton = NSButton(
                title: isPrimary ? L("Move to More Tools") : L("Make Common"),
                target: self,
                action: #selector(captureMenuItemTransfer(_:))
            )
            transferButton.bezelStyle = .rounded
            transferButton.controlSize = .small
            transferButton.font = NSFont.systemFont(ofSize: 11)
            transferButton.tag = itemID.tag
            transferButton.identifier = NSUserInterfaceItemIdentifier(isPrimary ? "primary" : "more")
            transferButton.widthAnchor.constraint(equalToConstant: 112).isActive = true

            let row = NSStackView(views: [icon, checkbox, spacer, upButton, downButton, transferButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true

            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func captureMenuOrderButton(symbolName: String, action: Selector, tag: Int, identifier: String, toolTip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.tag = tag
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func saveCaptureMenuOrderAndRefreshMenu() {
        onHotkeyChanged?()
    }

    @objc private func moveCaptureMenuItemUp(_ sender: NSButton) {
        guard let item = CaptureMenuItemID.fromTag(sender.tag) else { return }
        let isPrimary = sender.identifier?.rawValue == "primary"
        CaptureMenuItemID.move(item, inPrimary: isPrimary, offset: -1)
        rebuildCaptureMenuOrderRows(isPrimary: isPrimary)
        saveCaptureMenuOrderAndRefreshMenu()
    }

    @objc private func moveCaptureMenuItemDown(_ sender: NSButton) {
        guard let item = CaptureMenuItemID.fromTag(sender.tag) else { return }
        let isPrimary = sender.identifier?.rawValue == "primary"
        CaptureMenuItemID.move(item, inPrimary: isPrimary, offset: 1)
        rebuildCaptureMenuOrderRows(isPrimary: isPrimary)
        saveCaptureMenuOrderAndRefreshMenu()
    }

    @objc private func resetCaptureMenuOrder(_ sender: NSButton) {
        CaptureMenuItemID.resetOrder()
        rebuildCaptureMenuOrderRows()
        onHotkeyChanged?()
    }

    @objc private func captureMenuItemEnabledChanged(_ sender: NSButton) {
        guard let item = CaptureMenuItemID.fromTag(sender.tag) else { return }
        CaptureMenuItemID.setEnabled(item, enabled: sender.state == .on)
        onHotkeyChanged?()
    }

    @objc private func captureMenuItemTransfer(_ sender: NSButton) {
        guard let item = CaptureMenuItemID.fromTag(sender.tag) else { return }
        let isPrimary = sender.identifier?.rawValue == "primary"
        CaptureMenuItemID.move(item, toPrimary: !isPrimary)
        rebuildCaptureMenuOrderRows()
        saveCaptureMenuOrderAndRefreshMenu()
    }

    // MARK: - Shortcuts Tab

    private func makeShortcutsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(sectionHeader(L("Keyboard Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for slot in HotkeyManager.HotkeySlot.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = HotkeyManager.displayString(for: slot)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = slot.rawValue

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = slot.rawValue
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = slot.rawValue
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            hotkeyFields[slot] = field
            hotkeyButtons[slot] = btn

            stack.addArrangedSubview(labeledRow("\(slot.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let note = NSTextField(wrappingLabelWithString: L("Click \"Set\" and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧) to set a shortcut."))
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(note))

        // ── Overlay / Editor Tool Shortcuts ──────────────────
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader(L("Overlay / Editor Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        showToolShortcutsInTooltipsCheckbox = NSButton(
            checkboxWithTitle: L("Show shortcuts in tooltips"),
            target: self,
            action: #selector(showToolShortcutsInTooltipsChanged(_:)))
        stack.addArrangedSubview(indented(showToolShortcutsInTooltipsCheckbox))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        for action in ToolShortcutManager.Action.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = ToolShortcutManager.displayString(for: action)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordToolShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearToolShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetToolShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            toolShortcutFields[action] = field
            toolShortcutButtons[action] = btn

            stack.addArrangedSubview(labeledRow("\(action.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        let toolNote = NSTextField(wrappingLabelWithString: L("Press a single key to assign it as the shortcut for that tool. These work when the overlay or editor is active."))
        toolNote.font = NSFont.systemFont(ofSize: 10)
        toolNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(toolNote))
        let conflictNote = NSTextField(wrappingLabelWithString: L("When shortcuts conflict, the settings list is matched from top to bottom and the first entry takes priority."))
        conflictNote.font = NSFont.systemFont(ofSize: 10)
        conflictNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(conflictNote))

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader(L("Selection & Pin Interactions")))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        let interactionNote = NSTextField(wrappingLabelWithString: L("These shortcuts work only in a capture selection or selected pin; on-screen hints follow the current settings."))
        interactionNote.font = NSFont.systemFont(ofSize: 10)
        interactionNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(interactionNote))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        for action in InteractionShortcutManager.Action.allCases {
            let popup = NSPopUpButton()
            InteractionShortcutManager.Modifier.allCases.forEach { popup.addItem(withTitle: $0.label) }
            popup.selectItem(withTitle: InteractionShortcutManager.modifier(for: action).label)
            popup.target = self
            popup.action = #selector(interactionShortcutChanged(_:))
            popup.tag = InteractionShortcutManager.Action.allCases.firstIndex(of: action)!
            interactionShortcutPopups[action] = popup
            let directionSuffix: String = (action == .nudgeInspectorCursor || action == .nudgeSelection) ? " (\(L("Arrow Keys")))" : ""
            stack.addArrangedSubview(labeledRow(action.label + directionSuffix + "：", controls: [popup]))
            stack.setCustomSpacing(5, after: stack.arrangedSubviews.last!)
        }

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        let restoreAllButton = NSButton(
            title: L("Restore All Default Shortcuts"),
            target: self,
            action: #selector(restoreAllShortcutDefaults(_:))
        )
        restoreAllButton.bezelStyle = .rounded
        stack.addArrangedSubview(restoreAllButton)

        // Spacer to push content to top
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
        ])

        return scroll
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }

        // If already recording this slot, stop
        if recordingSlot == slot {
            stopShortcutRecording()
            return
        }
        // Stop any previous recording (global or tool)
        stopShortcutRecording()
        stopToolShortcutRecording()

        recordingSlot = slot
        sender.title = L("Press keys...")
        hotkeyFields[slot]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)
            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) { return nil }
            HotkeyManager.saveHotkey(for: slot, keyCode: keyCode, modifiers: carbonMods)
            self.hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
            self.stopShortcutRecording()
            self.onHotkeyChanged?()
            return nil
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.disableHotkey(for: slot)
        hotkeyFields[slot]?.stringValue = L("None")
        onHotkeyChanged?()
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.saveHotkey(for: slot, keyCode: slot.defaultKeyCode, modifiers: slot.defaultModifiers)
        hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        onHotkeyChanged?()
    }

    @objc private func restoreAllShortcutDefaults(_ sender: NSButton) {
        stopShortcutRecording()
        stopToolShortcutRecording()

        let alert = NSAlert()
        alert.messageText = L("Restore All Default Shortcuts?")
        alert.informativeText = L("This restores global, tool, selection, and pin interaction shortcuts. Other settings will not change.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Restore Defaults"))
        alert.addButton(withTitle: L("Cancel"))

        let restore = { [weak self] in
            guard let self else { return }
            if let document = self.settingsProfileDocument,
               let profile = document.profiles.first(where: { $0.id == document.activeProfileID }),
               profile.kind != .custom,
               let appDelegate = NSApp.delegate as? AppDelegate {
                self.isApplyingSettingsProfile = true
                defer { self.isApplyingSettingsProfile = false }
                do {
                    try appDelegate.applySettingsProfileShortcuts(profile)
                } catch {
                    self.showSettingsProfileError("Could not apply configuration profile.")
                    return
                }
            } else {
                HotkeyManager.resetAllToDefaults()
                ToolShortcutManager.resetAllToDefaults()
                InteractionShortcutManager.resetAllToDefaults()
                self.onHotkeyChanged?()
            }

            for slot in HotkeyManager.HotkeySlot.allCases {
                self.hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
            }
            for action in ToolShortcutManager.Action.allCases {
                self.toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            }
            for action in InteractionShortcutManager.Action.allCases {
                self.interactionShortcutPopups[action]?.selectItem(withTitle: InteractionShortcutManager.modifier(for: action).label)
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                restore()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            restore()
        }
    }

    private func stopShortcutRecording() {
        if let slot = recordingSlot {
            hotkeyButtons[slot]?.title = L("Set")
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Overlay Tool Shortcuts

    @objc private func recordToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]

        // If already recording this action, stop
        if recordingToolAction == action {
            stopToolShortcutRecording()
            return
        }
        // Stop any other recording (global or tool)
        stopShortcutRecording()
        stopToolShortcutRecording()

        recordingToolAction = action
        sender.title = L("Press...")
        toolShortcutFields[action]?.stringValue = "…"

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Only accept single keys without modifiers (or allow Escape to cancel)
            if event.keyCode == 53 { // Escape — cancel
                self.stopToolShortcutRecording()
                return nil
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  let char = event.charactersIgnoringModifiers?.lowercased(),
                  char.count == 1 else { return nil }

            ToolShortcutManager.setKey(char, for: action)
            self.toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            self.stopToolShortcutRecording()
            return nil
        }
    }

    @objc private func clearToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey("", for: action)
        toolShortcutFields[action]?.stringValue = L("None")
    }

    @objc private func resetToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey(action.defaultKey, for: action)
        toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
    }

    @objc private func showToolShortcutsInTooltipsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showToolShortcutsInTooltips")
    }

    private func stopToolShortcutRecording() {
        if let action = recordingToolAction {
            toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            toolShortcutButtons[action]?.title = L("Set")
        }
        recordingToolAction = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    @objc private func interactionShortcutChanged(_ sender: NSPopUpButton) {
        let actions = InteractionShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count,
              let title = sender.selectedItem?.title,
              let modifier = InteractionShortcutManager.Modifier.allCases.first(where: { $0.label == title })
        else { return }
        InteractionShortcutManager.setModifier(modifier, for: actions[sender.tag])
    }

    // MARK: - Tools Tab

    private func makeToolsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(sectionHeader(L("Toolbar Layout")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteA = NSTextField(wrappingLabelWithString: L("Common tools appear in the first row; additional tools move into the More menu. Actions unavailable for the current context do not appear."))
        noteA.font = NSFont.systemFont(ofSize: 11)
        noteA.textColor = .secondaryLabelColor
        noteA.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(noteA)
        noteA.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(sectionHeader(L("Common Tools")))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        primaryToolsRowsStack = makeToolbarToolOrderStack(isPrimary: true)
        let primaryBox = boxedView(primaryToolsRowsStack!)
        stack.addArrangedSubview(primaryBox)
        primaryBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(sectionHeader(L("More Tools")))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        secondaryToolsRowsStack = makeToolbarToolOrderStack(isPrimary: false)
        let secondaryBox = boxedView(secondaryToolsRowsStack!)
        stack.addArrangedSubview(secondaryBox)
        secondaryBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(sectionHeader(L("Non-Drawing Actions")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteB = NSTextField(wrappingLabelWithString: L("These are actions rather than drawing tools. Disabling one hides it wherever that action is available."))
        noteB.font = NSFont.systemFont(ofSize: 11)
        noteB.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteB)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let actionItems = ToolbarCustomAction.allKnownActions
            .filter {
                !$0.settingsLabel.isEmpty
                    && $0 != .pinShadow && $0 != .copyText && $0 != .selectText
                    && $0 != .screenTranslation
            }
            .map { (tag: $0.rawValue, label: $0.settingsLabel) }
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        let actionsGrid = makeToggleGrid(items: actionItems,
                                         defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(actionsGrid)
        actionsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        appendOCRAndTranslationSettings(to: stack)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        return scroll
    }

    private func appendOCRAndTranslationSettings(to stack: NSStackView) {
        stack.addArrangedSubview(sectionHeader(L("OCR & Translation")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let note = NSTextField(wrappingLabelWithString: L("Choose which dedicated OCR and translation tools are visible. Keyboard shortcuts are in Shortcuts."))
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for context in DedicatedToolbarContext.allCases {
            let section = makeDedicatedToolVisibilitySection(context)
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)
        }

        translationProviderPopup = NSPopUpButton()
        translationProviderPopup.addItems(withTitles: [L("Apple (on-device)"), L("Google Translate")])
        translationProviderPopup.item(at: 0)?.isEnabled = TranslationService.appleTranslationAvailable
        translationProviderPopup.selectItem(at: TranslationService.provider == .apple ? 0 : 1)
        translationProviderPopup.target = self
        translationProviderPopup.action = #selector(translationProviderChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Engine:"), controls: [translationProviderPopup]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let providerNote = NSTextField(wrappingLabelWithString: L("Apple translation is faster and works offline. Google Translate supports more languages."))
        providerNote.font = NSFont.systemFont(ofSize: 10)
        providerNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(providerNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        googleTranslationAllowedCheckbox = NSButton(
            checkboxWithTitle: L("Allow sending text to Google Translate"),
            target: self,
            action: #selector(googleTranslationAllowedChanged(_:))
        )
        googleTranslationAllowedCheckbox.state = TranslationService.googleTranslationAllowed ? .on : .off
        stack.addArrangedSubview(indented(googleTranslationAllowedCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let privacyNote = NSTextField(wrappingLabelWithString: L("Turn this off to keep translation text on this Mac. Google translation will be unavailable."))
        privacyNote.font = NSFont.systemFont(ofSize: 10)
        privacyNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(privacyNote))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        translationProviderStatusLabel = NSTextField(wrappingLabelWithString: "")
        translationProviderStatusLabel.font = NSFont.systemFont(ofSize: 10)
        stack.addArrangedSubview(indented(translationProviderStatusLabel))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
        updateTranslationProviderStatus()

        if TranslationService.appleTranslationAvailable {
            let downloadLink = NSButton(title: L("Download language packs in System Settings…"), target: self, action: #selector(openTranslationSettings))
            downloadLink.bezelStyle = .inline
            downloadLink.isBordered = false
            downloadLink.contentTintColor = .linkColor
            downloadLink.font = NSFont.systemFont(ofSize: 10)
            stack.addArrangedSubview(indented(downloadLink))
        }
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
    }

    private func makeDedicatedToolVisibilitySection(_ context: DedicatedToolbarContext) -> NSView {
        let title = NSTextField(labelWithString: L(context.settingsTitle))
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let checkboxes = DedicatedToolPreferences.tools(in: context).map { tool in
            let checkbox = NSButton(
                checkboxWithTitle: L(tool.settingsLabel),
                target: self,
                action: #selector(dedicatedToolVisibilityChanged(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(
                "\(context.rawValue).\(tool.rawValue)")
            checkbox.state = DedicatedToolPreferences.isVisible(tool, in: context) ? .on : .off
            return checkbox
        }
        let grid = makeTwoColumnCheckboxGrid(checkboxes)

        let group = NSStackView(views: [title, grid])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 5
        group.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func makeToolbarToolOrderStack(isPrimary: Bool) -> NSStackView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 6
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        rebuildToolbarToolOrderRows(isPrimary: isPrimary, in: rows)
        return rows
    }

    private func rebuildToolbarToolOrderRows(isPrimary: Bool, in rows: NSStackView? = nil) {
        let targetRows = rows ?? (isPrimary ? primaryToolsRowsStack : secondaryToolsRowsStack)
        guard let targetRows else { return }
        targetRows.arrangedSubviews.forEach {
            targetRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let items = PinToolbarLayoutPreferences.items(inPrimary: isPrimary)
        for (index, item) in items.enumerated() {
            switch item {
            case .tool(let tool):
                targetRows.addArrangedSubview(makeToolbarToolRow(
                    tool: tool,
                    isPrimary: isPrimary,
                    canMoveUp: index > 0,
                    canMoveDown: index < items.count - 1
                ))
            case .pinShadow, .selectText, .screenTranslation:
                targetRows.addArrangedSubview(makeSpecialPinToolbarItemRow(
                    item: item,
                    isPrimary: isPrimary,
                    canMoveUp: index > 0,
                    canMoveDown: index < items.count - 1
                ))
            }
        }
    }

    private func makeToolbarToolRow(
        tool: AnnotationTool,
        isPrimary: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> NSView {
        let checkbox = NSButton(
            checkboxWithTitle: ToolbarToolPreferences.displayName(for: tool),
            target: self,
            action: #selector(toolbarToolEnabledChanged(_:))
        )
        checkbox.tag = tool.rawValue
        checkbox.state = ToolbarToolPreferences.isToolEnabled(tool) ? .on : .off
        checkbox.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let identifier = "\(isPrimary ? "primary" : "secondary")|tool:\(tool.rawValue)"
        let upButton = compactButton(L("Move Up"), action: #selector(specialPinToolbarItemMoveUp(_:)))
        upButton.tag = tool.rawValue
        upButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        upButton.isEnabled = canMoveUp

        let downButton = compactButton(L("Move Down"), action: #selector(specialPinToolbarItemMoveDown(_:)))
        downButton.tag = tool.rawValue
        downButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        downButton.isEnabled = canMoveDown

        let transferButton = compactButton(
            isPrimary ? L("Move to More Tools") : L("Make Common"),
            action: #selector(specialPinToolbarItemTransfer(_:)),
            width: 112
        )
        transferButton.tag = tool.rawValue
        transferButton.identifier = NSUserInterfaceItemIdentifier(identifier)

        let row = NSStackView(views: [checkbox, upButton, downButton, transferButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func compactButton(_ title: String, action: Selector, width: CGFloat = 52) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func makeSpecialPinToolbarItemRow(
        item: PinToolbarLayoutItem,
        isPrimary: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> NSView {
        let action: ToolbarCustomAction
        let title: String
        switch item {
        case .pinShadow:
            action = .pinShadow
            title = L("Pin Shadow")
        case .selectText:
            action = .selectText
            title = L("Select Text")
        case .screenTranslation:
            action = .screenTranslation
            title = L("Screen Translation")
        case .tool:
            preconditionFailure("Drawing tools use makeToolbarToolRow")
        }
        let checkboxAction: Selector
        switch item {
        case .pinShadow:
            checkboxAction = #selector(pinShadowToolEnabledChanged(_:))
        case .selectText:
            checkboxAction = #selector(selectTextToolEnabledChanged(_:))
        case .screenTranslation:
            checkboxAction = #selector(screenTranslationToolEnabledChanged(_:))
        case .tool:
            preconditionFailure("Drawing tools use makeToolbarToolRow")
        }
        let checkbox = NSButton(
            checkboxWithTitle: title,
            target: self,
            action: checkboxAction
        )
        checkbox.tag = action.rawValue
        checkbox.state = ToolbarActionPreferences.isEnabled(
            action,
            in: ToolbarActionPreferences.enabledRawValuesAfterMigration()
        ) ? .on : .off
        checkbox.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let identifier = "\(isPrimary ? "primary" : "secondary")|\(item.storageValue)"
        let upButton = compactButton(L("Move Up"), action: #selector(specialPinToolbarItemMoveUp(_:)))
        upButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        upButton.isEnabled = canMoveUp
        let downButton = compactButton(L("Move Down"), action: #selector(specialPinToolbarItemMoveDown(_:)))
        downButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        downButton.isEnabled = canMoveDown

        let transferButton = compactButton(
            isPrimary ? L("Move to More Tools") : L("Make Common"),
            action: #selector(specialPinToolbarItemTransfer(_:)),
            width: 112
        )
        transferButton.identifier = NSUserInterfaceItemIdentifier(identifier)

        let row = NSStackView(views: [checkbox, upButton, downButton, transferButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }


    private func boxedView(_ content: NSView) -> NSView {
        let box = AppearanceAwareSettingsCardView(fillAlpha: 0.5, cornerRadius: 6, borderWidth: 1)
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }

    private func appendScrollCaptureSettings(to stack: NSStackView) {
        stack.addArrangedSubview(sectionHeader(L("Scroll Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        scrollAutoScrollCheckbox = NSButton(
            checkboxWithTitle: L("Auto-scroll (sends synthetic scroll events)"),
            target: self,
            action: #selector(scrollAutoScrollChanged(_:))
        )
        stack.addArrangedSubview(indented(scrollAutoScrollCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollSpeedPopup = NSPopUpButton()
        scrollSpeedPopup.addItems(withTitles: [L("Slow"), L("Medium"), L("Fast"), L("Very fast")])
        scrollSpeedPopup.target = self
        scrollSpeedPopup.action = #selector(scrollSpeedChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Scroll speed:"), controls: [scrollSpeedPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollMaxHeightField = NSTextField()
        scrollMaxHeightField.isEditable = false
        scrollMaxHeightField.isSelectable = false
        scrollMaxHeightField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scrollMaxHeightField.translatesAutoresizingMaskIntoConstraints = false
        scrollMaxHeightField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        scrollMaxHeightStepper = NSStepper()
        scrollMaxHeightStepper.minValue = 0
        scrollMaxHeightStepper.maxValue = 100000
        scrollMaxHeightStepper.increment = 5000
        scrollMaxHeightStepper.valueWraps = false
        scrollMaxHeightStepper.target = self
        scrollMaxHeightStepper.action = #selector(scrollMaxHeightChanged(_:))

        let maxHeightNote = NSTextField(labelWithString: L("px (0 = unlimited)"))
        maxHeightNote.font = .systemFont(ofSize: 11)
        maxHeightNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(labeledRow(
            L("Max height:"),
            controls: [scrollMaxHeightField, scrollMaxHeightStepper, maxHeightNote]
        ))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollFrozenDetectionCheckbox = NSButton(
            checkboxWithTitle: L("Detect fixed/sticky headers"),
            target: self,
            action: #selector(scrollFrozenDetectionChanged(_:))
        )
        stack.addArrangedSubview(indented(scrollFrozenDetectionCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
    }

    // MARK: - Recording Tab

    private func makeRecordingTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Output ────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Output")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingFPSPopup = NSPopUpButton()
        recordingFPSPopup.addItems(withTitles: [L("15 fps"), L("24 fps"), L("30 fps"), L("60 fps"), L("120 fps")])
        recordingFPSPopup.target = self
        recordingFPSPopup.action = #selector(recordingFPSChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Frame rate:"), controls: [recordingFPSPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        recordingQualityPopup = NSPopUpButton()
        for quality in [LiveRecordingQuality.automatic, .high, .medium, .low] {
            recordingQualityPopup.addItem(withTitle: quality == .automatic ? L("Automatic") : VideoQuality(rawValue: quality.rawValue)!.displayName)
            recordingQualityPopup.lastItem?.representedObject = quality.rawValue
        }
        recordingQualityPopup.target = self
        recordingQualityPopup.action = #selector(recordingQualityChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Quality:"), controls: [recordingQualityPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        recSavePathField = NSTextField()
        recSavePathField.isEditable = false
        recSavePathField.isSelectable = false
        recSavePathField.lineBreakMode = .byTruncatingMiddle

        let recBrowseBtn = NSButton(title: L("Browse…"), target: self, action: #selector(browseRecSavePath(_:)))
        recBrowseBtn.bezelStyle = .rounded
        let recClearBtn = NSButton(title: L("Clear"), target: self, action: #selector(clearRecSavePath(_:)))
        recClearBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow(L("Save folder:"), controls: [recSavePathField, recBrowseBtn, recClearBtn]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Recording filename template
        recordingFilenameTemplateField = NSTextField()
        recordingFilenameTemplateField.placeholderString = FilenameFormatter.defaultRecordingTemplate
        recordingFilenameTemplateField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        recordingFilenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.recordingUserDefaultsKey) ?? FilenameFormatter.defaultRecordingTemplate
        recordingFilenameTemplateField.target = self
        recordingFilenameTemplateField.action = #selector(recordingFilenameTemplateCommitted(_:))
        recordingFilenameTemplateField.delegate = self
        recordingFilenameTemplateField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        recordingFilenameTemplatePreview = NSTextField(labelWithString: "")
        recordingFilenameTemplatePreview.font = NSFont.systemFont(ofSize: 10)
        recordingFilenameTemplatePreview.textColor = .secondaryLabelColor
        recordingFilenameTemplatePreview.lineBreakMode = .byTruncatingMiddle

        let recFilenameResetBtn = NSButton(title: L("Reset"), target: self, action: #selector(recordingFilenameTemplateReset(_:)))
        recFilenameResetBtn.bezelStyle = .rounded

        let recFilenameInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("Filename tokens")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show available filename tokens")
        )
        recFilenameInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showFilenameTemplateInfoPopover(near: sourceView) }
        }

        stack.addArrangedSubview(labeledRow(L("Filename:"), controls: [recordingFilenameTemplateField, recFilenameInfoIcon, recFilenameResetBtn]))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(indented(recordingFilenameTemplatePreview))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        updateRecordingFilenamePreview()

        // ── Behavior ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Behavior")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingOnStopPopup = NSPopUpButton()
        recordingOnStopPopup.addItems(withTitles: [L("Open editor"), L("Show in Finder"), L("Copy to clipboard")])
        recordingOnStopPopup.target = self
        recordingOnStopPopup.action = #selector(recordingOnStopChanged(_:))
        stack.addArrangedSubview(labeledRow(L("When done:"), controls: [recordingOnStopPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let hideHUDCheckbox = NSButton(checkboxWithTitle: L("Hide recording controls"), target: self, action: #selector(hideRecordingHUDChanged(_:)))
        hideHUDCheckbox.state = UserDefaults.standard.bool(forKey: "hideRecordingHUD") ? .on : .off
        stack.addArrangedSubview(indented(hideHUDCheckbox))

        let hideHUDNote = NSTextField(labelWithString: L("Stop recording from the menu bar icon instead."))
        hideHUDNote.font = NSFont.systemFont(ofSize: 10)
        hideHUDNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideHUDNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Webcam ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Webcam")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        webcamPositionPopup = NSPopUpButton()
        webcamPositionPopup.addItems(withTitles: [L("Bottom Right"), L("Bottom Left"), L("Top Right"), L("Top Left")])
        webcamPositionPopup.target = self
        webcamPositionPopup.action = #selector(webcamPositionChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Position:"), controls: [webcamPositionPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        webcamSizePopup = NSPopUpButton()
        webcamSizePopup.addItems(withTitles: [L("Webcam Size Small"), L("Webcam Size Medium"), L("Webcam Size Large"), L("Webcam Size Extra Large")])
        webcamSizePopup.target = self
        webcamSizePopup.action = #selector(webcamSizeChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Size:"), controls: [webcamSizePopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        webcamShapePopup = NSPopUpButton()
        webcamShapePopup.addItems(withTitles: [L("Circle"), L("Rounded Rectangle")])
        webcamShapePopup.target = self
        webcamShapePopup.action = #selector(webcamShapeChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Shape:"), controls: [webcamShapePopup]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Spacer to absorb remaining height, keeping content pinned to top
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
        ])

        return scroll
    }

    #if !OFFLINE
    // MARK: - Uploads Tab

    private func makeUploadsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Upload Provider ──
        stack.addArrangedSubview(sectionHeader(L("Upload Provider")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: [L("imgbb (images only)"), L("Google Drive (images + videos)"), L("S3-Compatible (images + videos)")])
        let currentProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        switch currentProvider {
        case "gdrive": providerPopup.selectItem(at: 1)
        case "s3": providerPopup.selectItem(at: 2)
        default: providerPopup.selectItem(at: 0)
        }
        providerPopup.target = self
        providerPopup.action = #selector(uploadProviderChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Provider:"), controls: [providerPopup]))

        uploadConfirmCheckbox = NSButton(
            checkboxWithTitle: L("Confirm before upload"),
            target: self,
            action: #selector(uploadConfirmChanged(_:))
        )
        uploadConfirmCheckbox.state = UploadConfirmation.isEnabled ? .on : .off
        stack.addArrangedSubview(indented(uploadConfirmCheckbox))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── Google Drive ──
        stack.addArrangedSubview(sectionHeader(L("Google Drive")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        gdriveStatusLabel = NSTextField(labelWithString: "")
        gdriveStatusLabel.font = NSFont.systemFont(ofSize: 11)
        gdriveStatusLabel.textColor = .secondaryLabelColor
        updateGDriveStatus()

        gdriveSignInBtn = NSButton(title: L("Sign In with Google"), target: self, action: #selector(gdriveSignInTapped(_:)))
        gdriveSignInBtn.bezelStyle = .rounded
        updateGDriveButton()

        stack.addArrangedSubview(labeledRow(L("Account:"), controls: [gdriveStatusLabel]))
        stack.addArrangedSubview(indented(gdriveSignInBtn))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let gdriveNote = NSTextField(wrappingLabelWithString: L("Files are uploaded to a \"Pinlume\" folder in your Google Drive. Everything stays private — nothing is shared publicly."))
        gdriveNote.font = NSFont.systemFont(ofSize: 10)
        gdriveNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(gdriveNote))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── S3-Compatible ──
        stack.addArrangedSubview(sectionHeader(L("S3-Compatible Storage")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        s3EndpointField = NSTextField()
        s3EndpointField.placeholderString = "https://abc123.r2.cloudflarestorage.com"
        s3EndpointField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3EndpointField.stringValue = UserDefaults.standard.string(forKey: "s3Endpoint") ?? ""
        s3EndpointField.target = self
        s3EndpointField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Endpoint:"), controls: [s3EndpointField]))

        s3RegionField = NSTextField()
        s3RegionField.placeholderString = "auto"
        s3RegionField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3RegionField.stringValue = UserDefaults.standard.string(forKey: "s3Region") ?? "auto"
        s3RegionField.target = self
        s3RegionField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Region:"), controls: [s3RegionField]))

        s3BucketField = NSTextField()
        s3BucketField.placeholderString = "my-bucket"
        s3BucketField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3BucketField.stringValue = UserDefaults.standard.string(forKey: "s3Bucket") ?? ""
        s3BucketField.target = self
        s3BucketField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Bucket:"), controls: [s3BucketField]))

        s3AccessKeyField = NSTextField()
        s3AccessKeyField.placeholderString = "Example access key ID"
        s3AccessKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3AccessKeyField.stringValue = UserDefaults.standard.string(forKey: "s3AccessKeyID") ?? ""
        s3AccessKeyField.target = self
        s3AccessKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Access Key:"), controls: [s3AccessKeyField]))

        s3SecretKeyField = NSSecureTextField()
        s3SecretKeyField.placeholderString = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        s3SecretKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3SecretKeyField.stringValue = UserDefaults.standard.string(forKey: "s3SecretAccessKey") ?? ""
        s3SecretKeyField.target = self
        s3SecretKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Secret Key:"), controls: [s3SecretKeyField]))

        s3PublicURLField = NSTextField()
        s3PublicURLField.placeholderString = "https://cdn.example.com"
        s3PublicURLField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PublicURLField.stringValue = UserDefaults.standard.string(forKey: "s3PublicURLBase") ?? ""
        s3PublicURLField.target = self
        s3PublicURLField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Public URL:"), controls: [s3PublicURLField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let publicURLNote = NSTextField(wrappingLabelWithString: L("Base URL for public access. If empty, the S3 endpoint URL is used (may not be publicly accessible)."))
        publicURLNote.font = NSFont.systemFont(ofSize: 10)
        publicURLNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(publicURLNote))

        s3PathPrefixField = NSTextField()
        s3PathPrefixField.placeholderString = "screenshots/"
        s3PathPrefixField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PathPrefixField.stringValue = UserDefaults.standard.string(forKey: "s3PathPrefix") ?? ""
        s3PathPrefixField.target = self
        s3PathPrefixField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Path Prefix:"), controls: [s3PathPrefixField]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        s3TestBtn = NSButton(title: L("Test Connection"), target: self, action: #selector(s3TestTapped(_:)))
        s3TestBtn.bezelStyle = .rounded

        s3StatusLabel = NSTextField(labelWithString: "")
        s3StatusLabel.font = NSFont.systemFont(ofSize: 11)
        s3StatusLabel.textColor = .secondaryLabelColor
        s3StatusLabel.lineBreakMode = .byTruncatingTail

        let testRow = NSStackView(views: [s3TestBtn, s3StatusLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 8
        stack.addArrangedSubview(indented(testRow))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let s3Note = NSTextField(wrappingLabelWithString: L("Works with AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, Backblaze B2, and other S3-compatible services. Supports images and videos."))
        s3Note.font = NSFont.systemFont(ofSize: 10)
        s3Note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(s3Note))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── imgbb ──
        stack.addArrangedSubview(sectionHeader("imgbb"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        imgbbKeyField = NSTextField()
        imgbbKeyField.placeholderString = L("Leave empty to use default")
        imgbbKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        imgbbKeyField.target = self
        imgbbKeyField.action = #selector(imgbbKeyChanged(_:))
        if let key = UserDefaults.standard.string(forKey: "imgbbAPIKey") {
            imgbbKeyField.stringValue = key
        }

        stack.addArrangedSubview(labeledRow(L("API key:"), controls: [imgbbKeyField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let imgbbNote = NSTextField(wrappingLabelWithString: L("A shared key is included — get your own free key at imgbb.com/api if you hit rate limits. Images only (no video support)."))
        imgbbNote.font = NSFont.systemFont(ofSize: 10)
        imgbbNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(imgbbNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Upload History ──
        stack.addArrangedSubview(sectionHeader(L("Upload History")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Placeholder for upload history rows
        let historyContainer = NSStackView()
        historyContainer.orientation = .vertical
        historyContainer.alignment = .width
        historyContainer.spacing = 6
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(historyContainer)
        // Stretch to full stack width
        historyContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        self.uploadsStack = historyContainer

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        return scroll
    }
    #endif

    // MARK: - About Tab

    private func makeAboutTabView() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        // App icon
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(12, after: icon)

        // App name
        let name = NSTextField(labelWithString: BuildVariant.displayName)
        name.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        name.textColor = .labelColor
        stack.addArrangedSubview(name)

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: String(format: L("Version %@ (%@)"), version, build))
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(20, after: versionLabel)

        // Description
        let desc = NSTextField(wrappingLabelWithString: L("A free, open-source screenshot & screen recording tool for macOS.\nFully native — built with Swift and AppKit."))
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.textColor = .labelColor
        desc.alignment = .center
        stack.addArrangedSubview(desc)
        stack.setCustomSpacing(20, after: desc)

        #if OFFLINE
        let offlineNote = NSTextField(wrappingLabelWithString: L("Offline build: upload and cloud storage integrations are removed. Update checks may still connect to Pinlume's update server. Screenshots and recordings stay local unless you share or save them yourself."))
        offlineNote.font = NSFont.systemFont(ofSize: 12)
        offlineNote.textColor = .secondaryLabelColor
        offlineNote.alignment = .center
        stack.addArrangedSubview(offlineNote)
        stack.setCustomSpacing(20, after: offlineNote)
        #endif

        // License
        let license = NSTextField(labelWithString: L("Licensed under the GPLv3"))
        license.font = NSFont.systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(license)
        stack.setCustomSpacing(20, after: license)

        // Screen Info (debug) — gathers display & capture metadata, copies to clipboard
        let screenInfoBtn = NSButton(title: L("Copy Screen Info"), target: self, action: #selector(copyScreenInfo))
        screenInfoBtn.bezelStyle = .rounded
        screenInfoBtn.font = NSFont.systemFont(ofSize: 11)
        screenInfoBtn.tag = 9999  // tag for lookup in action handler
        stack.addArrangedSubview(screenInfoBtn)

        let screenInfoHint = NSTextField(labelWithString: L("Copies display and capture diagnostics to clipboard"))
        screenInfoHint.font = NSFont.systemFont(ofSize: 10)
        screenInfoHint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(screenInfoHint)

        return container
    }

    @objc private func copyScreenInfo() {
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                var lines: [String] = []
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                lines.append("Pinlume \(version) (\(build))")
                lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                lines.append("")
                lines.append("=== NSScreen Info ===")
                for (i, screen) in NSScreen.screens.enumerated() {
                    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    let cs = screen.colorSpace?.cgColorSpace
                    // CGDisplayCopyColorSpace reads the display ICC profile directly,
                    // bypassing NSScreen — helps diagnose DisplayLink/driver issues.
                    let cgCS = CGDisplayCopyColorSpace(id)
                    lines.append("Screen \(i): \(screen.localizedName) (ID: \(id))")
                    lines.append("  frame: \(screen.frame)")
                    lines.append("  backingScale: \(screen.backingScaleFactor)")
                    lines.append("  NSScreen.colorSpace: \(cs?.name as String? ?? "nil")")
                    lines.append("  CGDisplayCopyColorSpace: \(cgCS.name as String? ?? "nil")")
                    lines.append("  cs model: \(cs?.model.rawValue ?? -1)")
                    lines.append("")
                }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    lines.append("=== ScreenCaptureKit Capture Info ===")
                    for display in content.displays {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width
                        config.height = display.height
                        config.captureResolution = .best
                        config.colorSpaceName = CGColorSpace.sRGB as CFString
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            lines.append("Display \(display.displayID) (\(display.width)x\(display.height)):")
                            lines.append("  CGImage size: \(img.width)x\(img.height)")
                            lines.append("  bitsPerComponent: \(img.bitsPerComponent)")
                            lines.append("  bitsPerPixel: \(img.bitsPerPixel)")
                            lines.append("  bytesPerRow: \(img.bytesPerRow)")
                            lines.append("  bitmapInfo: \(img.bitmapInfo.rawValue)")
                            lines.append("  alphaInfo: \(img.alphaInfo.rawValue)")
                            lines.append("  colorSpace: \(img.colorSpace?.name as String? ?? "nil")")
                            lines.append("  cs model: \(img.colorSpace?.model.rawValue ?? -1)")
                            lines.append("")
                        }
                    }
                } catch {
                    lines.append("Capture error: \(error.localizedDescription)")
                }
                let result = lines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                // Flash the button title to confirm
                if let btn = self.window?.contentView?.viewWithTag(9999) as? NSButton {
                    btn.title = L("Copied!")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { btn.title = L("Copy Screen Info") }
                }
            }
        }
    }

    #if !OFFLINE
    private func updateGDriveStatus() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveStatusLabel?.stringValue = GoogleDriveUploader.shared.userEmail ?? L("Signed in")
            gdriveStatusLabel?.textColor = .labelColor
        } else {
            gdriveStatusLabel?.stringValue = L("Not signed in")
            gdriveStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    private func updateGDriveButton() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveSignInBtn?.title = L("Sign Out")
        } else {
            gdriveSignInBtn?.title = L("Sign In with Google")
        }
    }

    @objc private func uploadConfirmChanged(_ sender: NSButton) {
        UploadConfirmation.isEnabled = sender.state == .on
    }

    @objc private func uploadProviderChanged(_ sender: NSPopUpButton) {
        let provider: String
        switch sender.indexOfSelectedItem {
        case 1: provider = "gdrive"
        case 2: provider = "s3"
        default: provider = "imgbb"
        }
        UserDefaults.standard.set(provider, forKey: "uploadProvider")
    }

    @objc private func gdriveSignInTapped(_ sender: NSButton) {
        if GoogleDriveUploader.shared.isSignedIn {
            GoogleDriveUploader.shared.signOut()
            updateGDriveStatus()
            updateGDriveButton()
        } else {
            GoogleDriveUploader.shared.signIn(from: window) { [weak self] success in
                guard let self = self, success else {
                    self?.updateGDriveStatus()
                    self?.updateGDriveButton()
                    return
                }
                self.window?.makeKeyAndOrderFront(nil)
                self.updateGDriveButton()
                // Fetch email then update status label
                GoogleDriveUploader.shared.fetchUserEmail { [weak self] in
                    self?.updateGDriveStatus()
                }
            }
        }
    }

    @objc private func s3FieldChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(s3EndpointField.stringValue, forKey: "s3Endpoint")
        UserDefaults.standard.set(s3RegionField.stringValue, forKey: "s3Region")
        UserDefaults.standard.set(s3BucketField.stringValue, forKey: "s3Bucket")
        UserDefaults.standard.set(s3AccessKeyField.stringValue, forKey: "s3AccessKeyID")
        UserDefaults.standard.set(s3SecretKeyField.stringValue, forKey: "s3SecretAccessKey")
        UserDefaults.standard.set(s3PublicURLField.stringValue, forKey: "s3PublicURLBase")
        UserDefaults.standard.set(s3PathPrefixField.stringValue, forKey: "s3PathPrefix")
    }

    @objc private func s3TestTapped(_ sender: NSButton) {
        // Save current field values first
        s3FieldChanged(s3EndpointField)

        guard S3Uploader.shared.isConfigured else {
            s3StatusLabel.stringValue = L("Fill in endpoint, bucket, and credentials first")
            s3StatusLabel.textColor = .systemOrange
            return
        }

        s3TestBtn.isEnabled = false
        s3StatusLabel.stringValue = L("Testing...")
        s3StatusLabel.textColor = .secondaryLabelColor

        // Upload a tiny test file
        let testData = Data("Pinlume connection test".utf8)
        let testKey = ".pinlume_test_\(UUID().uuidString.prefix(8)).txt"
        S3Uploader.shared.upload(data: testData, filename: testKey, contentType: "text/plain") { [weak self] result in
            guard let self = self else { return }
            self.s3TestBtn.isEnabled = true
            switch result {
            case .success:
                self.s3StatusLabel.stringValue = L("Connection successful!")
                self.s3StatusLabel.textColor = .systemGreen
            case .failure(let error):
                self.s3StatusLabel.stringValue = error.localizedDescription
                self.s3StatusLabel.textColor = .systemRed
            }
        }
    }

    private func reloadUploadsTab() {
        guard let stack = uploadsStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        let uploads = ((UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]]) ?? [])
            .reversed() as [[String: String]]

        if uploads.isEmpty {
            let lbl = NSTextField(labelWithString: L("No uploads yet."))
            lbl.font = NSFont.systemFont(ofSize: 13)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .center
            lbl.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(lbl)
        } else {
            for (i, upload) in uploads.enumerated() {
                let row = makeUploadRow(index: uploads.count - i,
                                        link: upload["link"] ?? "",
                                        deleteURL: upload["deleteURL"] ?? "")
                stack.addArrangedSubview(row)
            }
        }
    }

    private func makeUploadRow(index: Int, link: String, deleteURL: String) -> NSView {
        let box = AppearanceAwareSettingsCardView(fillAlpha: 0.5, cornerRadius: 6, borderWidth: 0.5)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        box.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        inner.addArrangedSubview(urlRow(tag: "URL", value: link, copyKey: "link::\(link)"))
        inner.addArrangedSubview(urlRow(tag: "DEL", value: deleteURL, copyKey: "link::\(deleteURL)"))

        return box
    }

    private func urlRow(tag: String, value: String, copyKey: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let tagLbl = NSTextField(labelWithString: tag)
        tagLbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        tagLbl.textColor = .secondaryLabelColor
        tagLbl.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(labelWithString: value)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = tag == "URL" ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let btn = NSButton(title: L("Copy"), target: self, action: #selector(copyUploadURL(_:)))
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 11)
        btn.identifier = NSUserInterfaceItemIdentifier(copyKey)
        btn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(tagLbl)
        row.addSubview(field)
        row.addSubview(btn)

        NSLayoutConstraint.activate([
            tagLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tagLbl.widthAnchor.constraint(equalToConstant: 34),
            tagLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            btn.widthAnchor.constraint(equalToConstant: 52),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: tagLbl.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }
    #endif

    // MARK: - Layout helpers

    private func sectionHeader(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    /// Width of the right-aligned label column for `labeledRow`. Wide
    /// enough to fit the longest localized string in practice — Polish's
    /// "Szybkie przechwycenie:" (issue #130) used to get clipped at the
    /// old 140pt column. 180pt covers every shipping locale with a bit
    /// of headroom.
    private static let labelColumnWidth: CGFloat = 180
    private static let settingsProfileActionButtonWidth: CGFloat = 72

    /// A horizontal row: right-aligned label on the left, controls on the right.
    private func labeledRow(_ labelText: String, controls: [NSView]) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let row = NSStackView(views: [lbl] + controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Indents a view to align with the control column.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Label column + row spacing (8pt).
        spacer.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth + 8).isActive = true

        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static let settingsGridColumnCount = 2
    private static let settingsGridRowMinimumHeight: CGFloat = 28
    private static let settingsGridPadding: CGFloat = 8

    /// Shared two-column checkbox layout for non-drawing and dedicated tools.
    private func makeTwoColumnCheckboxGrid(_ checkboxes: [NSButton]) -> NSView {
        let box = AppearanceAwareSettingsCardView(fillAlpha: 0.5, cornerRadius: 6, borderWidth: 1)

        // Build rows of 2 columns using horizontal stack views inside a vertical stack
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.settingsGridPadding),
            vStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.settingsGridPadding),
            vStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.settingsGridPadding),
            vStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.settingsGridPadding),
        ])

        let rows = (checkboxes.count + Self.settingsGridColumnCount - 1)
            / Self.settingsGridColumnCount

        for rowIndex in 0..<rows {
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            hStack.distribution = .fillEqually
            hStack.spacing = 0
            hStack.translatesAutoresizingMaskIntoConstraints = false
            // Row must be AT LEAST 28pt so single-line checkboxes still look
            // consistent, but can grow if a translated label wraps to two
            // lines. Without this relaxation, long locale strings get
            // horizontally clipped (issue #130).
            hStack.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Self.settingsGridRowMinimumHeight).isActive = true

            for columnIndex in 0..<Self.settingsGridColumnCount {
                let index = rowIndex * Self.settingsGridColumnCount + columnIndex
                if index < checkboxes.count {
                    let checkbox = checkboxes[index]
                    checkbox.translatesAutoresizingMaskIntoConstraints = false
                    // Let the title wrap when it doesn't fit the column —
                    // the native NSButton checkbox truncates by default.
                    // Word-wrap is graceful; the cell takes a second line
                    // of text when needed instead of swallowing characters.
                    checkbox.cell?.wraps = true
                    checkbox.cell?.isScrollable = false
                    checkbox.cell?.lineBreakMode = .byWordWrapping
                    if let cell = checkbox.cell as? NSButtonCell {
                        cell.usesSingleLineMode = false
                    }
                    hStack.addArrangedSubview(checkbox)
                } else {
                    let filler = NSView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    hStack.addArrangedSubview(filler)
                }
            }
            vStack.addArrangedSubview(hStack)
            // Stretch row to fill the vStack's width (must be after addArrangedSubview
            // so both views share a common ancestor)
            hStack.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        }

        return box
    }

    /// Two-column grid of non-drawing action toggles, fills parent width.
    private func makeToggleGrid(items: [(tag: Int, label: String)],
                                defaultsKey: String,
                                enabledValues: [Int]?) -> NSView {
        let checkboxes = items.map { item in
            let checkbox = NSButton(
                checkboxWithTitle: item.label,
                target: self,
                action: #selector(toggleItemChanged(_:)))
            let isEnabled = enabledValues.map { $0.contains(item.tag) } ?? true
            checkbox.state = isEnabled ? .on : .off
            checkbox.tag = item.tag
            checkbox.identifier = NSUserInterfaceItemIdentifier(defaultsKey)
            return checkbox
        }
        return makeTwoColumnCheckboxGrid(checkboxes)
    }

    // MARK: - Settings profiles

    private func loadSettingsProfileDocument() {
        do {
            let payload = try SettingsProfilePreferenceBridge().snapshotCurrentPreferences().payload
            let document = try settingsProfileStore.loadOrCreate(
                from: .standard,
                currentPayload: payload
            )
            try applyActiveBuiltinProfileIfNeeded(document)
            settingsProfileDocument = document
            refreshSettingsProfilePopup()
        } catch {
            settingsProfilePopup.isEnabled = false
            settingsProfileRenameButton.isEnabled = false
            settingsProfileCopyButton.isEnabled = false
            settingsProfileImportButton.isEnabled = false
            settingsProfileExportButton.isEnabled = false
            settingsProfileDeleteButton.isEnabled = false
        }
    }

    /// Schema migrations can change a protected built-in profile while the
    /// already-running app still has the old UserDefaults value. Apply only
    /// the migrated built-in once so opening Settings cannot mistake that
    /// migration gap for a user edit and create a custom copy.
    private func applyActiveBuiltinProfileIfNeeded(_ document: SettingsProfileDocument) throws {
        let profile = document.activeProfile
        guard profile.kind != .custom,
              CaptureOutputAction.current() != .copyToClipboard,
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }
        isApplyingSettingsProfile = true
        defer { isApplyingSettingsProfile = false }
        try appDelegate.applySettingsProfile(profile)
    }

    private func refreshSettingsProfilePopup() {
        guard let document = settingsProfileDocument else { return }
        settingsProfilePopup.removeAllItems()
        for profile in document.profiles {
            settingsProfilePopup.addItem(withTitle: settingsProfileDisplayName(profile))
            settingsProfilePopup.lastItem?.representedObject = profile.id.uuidString
        }
        if let index = document.profiles.firstIndex(where: { $0.id == document.activeProfileID }) {
            settingsProfilePopup.selectItem(at: index)
        }
        refreshSettingsProfileActionAvailability()
    }

    @objc private func settingsProfileChanged(_ sender: NSPopUpButton) {
        guard let idString = sender.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: idString),
              let document = settingsProfileDocument,
              let profile = document.profiles.first(where: { $0.id == id }),
              profile.id != document.activeProfileID,
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }
        var updatedDocument = document
        updatedDocument.activeProfileID = profile.id
        isApplyingSettingsProfile = true
        defer { isApplyingSettingsProfile = false }
        do {
            try applySettingsProfile(profile, storing: updatedDocument, restoring: document, appDelegate: appDelegate)
            loadSettings()
            refreshSettingsProfilePopup()
        } catch {
            refreshSettingsProfilePopup()
            let alert = NSAlert()
            alert.messageText = L("Could not apply configuration profile.")
            alert.informativeText = L("The current settings were kept unchanged.")
            alert.runModal()
        }
    }

    private func refreshSettingsProfileActionAvailability() {
        guard let document = settingsProfileDocument else { return }
        let canEditName = document.activeProfile.kind == .custom
        settingsProfileRenameButton.isEnabled = canEditName
        settingsProfileCopyButton.isEnabled = true
        settingsProfileDeleteButton.isEnabled = canEditName
        settingsProfileImportButton.isEnabled = true
        settingsProfileExportButton.isEnabled = true
    }

    private func applySettingsProfile(
        _ profile: SettingsProfile,
        storing updatedDocument: SettingsProfileDocument,
        restoring previousDocument: SettingsProfileDocument,
        appDelegate: AppDelegate
    ) throws {
        guard let previousProfile = previousDocument.profiles.first(where: { $0.id == previousDocument.activeProfileID }) else {
            throw SettingsProfileStoreError.missingActiveProfile
        }
        try appDelegate.applySettingsProfile(profile)
        do {
            try settingsProfileStore.save(updatedDocument, to: .standard)
        } catch {
            try? appDelegate.applySettingsProfile(previousProfile)
            throw error
        }
        settingsProfileDocument = updatedDocument
    }

    @objc private func renameSettingsProfile(_ sender: NSButton) {
        guard let document = settingsProfileDocument,
              let profile = document.profiles.first(where: { $0.id == document.activeProfileID }),
              profile.kind == .custom,
              let window
        else { return }
        let nameField = NSTextField(string: profile.name)
        nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = L("Rename Configuration")
        alert.informativeText = L("Enter a new name for this custom configuration.")
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = nameField
        alert.beginSheetModal(for: window) { [weak self, weak nameField] response in
            guard response == .alertFirstButtonReturn, let self, let name = nameField?.stringValue else { return }
            do {
                try self.renameSettingsProfile(profile, in: document, to: name)
            } catch {
                self.showSettingsProfileError("Could not rename configuration.")
            }
        }
    }

    private func renameSettingsProfile(
        _ profile: SettingsProfile,
        in document: SettingsProfileDocument,
        to name: String
    ) throws {
        let updatedDocument = try settingsProfileStore.renamingCustomProfile(profile.id, in: document, to: name)
        isApplyingSettingsProfile = true
        defer { isApplyingSettingsProfile = false }
        try settingsProfileStore.save(updatedDocument, to: .standard)
        settingsProfileDocument = updatedDocument
        refreshSettingsProfilePopup()
    }

    @objc private func copySettingsProfile(_ sender: NSButton) {
        guard let document = settingsProfileDocument,
              let profile = document.profiles.first(where: { $0.id == document.activeProfileID }),
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }
        do {
            let updatedDocument = try settingsProfileStore.duplicatingProfile(
                profile.id,
                in: document,
                named: copiedSettingsProfileName(for: profile)
            )
            let copiedProfile = updatedDocument.activeProfile
            isApplyingSettingsProfile = true
            defer { isApplyingSettingsProfile = false }
            try applySettingsProfile(copiedProfile, storing: updatedDocument, restoring: document, appDelegate: appDelegate)
            loadSettings()
            refreshSettingsProfilePopup()
        } catch {
            showSettingsProfileError("Could not copy configuration.")
        }
    }

    @objc private func importSettingsProfile(_ sender: NSButton) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.importSettingsProfile(from: url)
            } catch {
                self.showSettingsProfileError("Could not import configuration.")
            }
        }
    }

    private func importSettingsProfile(from url: URL) throws {
        guard let document = settingsProfileDocument,
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }
        let imported = try settingsProfileStore.importedProfile(from: url, into: document)
        var updatedDocument = document
        updatedDocument.profiles.append(imported)
        updatedDocument.activeProfileID = imported.id
        isApplyingSettingsProfile = true
        defer { isApplyingSettingsProfile = false }
        try applySettingsProfile(imported, storing: updatedDocument, restoring: document, appDelegate: appDelegate)
        loadSettings()
        refreshSettingsProfilePopup()
    }

    @objc private func exportSettingsProfile(_ sender: NSButton) {
        captureCurrentSettingsProfileIfNeeded()
        guard let document = settingsProfileDocument,
              let profile = document.profiles.first(where: { $0.id == document.activeProfileID }),
              let window
        else { return }
        do {
            let data = try settingsProfileStore.exportData(
                for: profile,
                name: settingsProfileDisplayName(profile)
            )
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(safeSettingsProfileFileName(for: profile)).json"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let self, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self.showSettingsProfileError("Could not export configuration.")
                }
            }
        } catch {
            showSettingsProfileError("Could not export configuration.")
        }
    }

    @objc private func deleteSettingsProfile(_ sender: NSButton) {
        guard let document = settingsProfileDocument,
              let profile = document.profiles.first(where: { $0.id == document.activeProfileID }),
              profile.kind == .custom,
              let window
        else { return }
        let alert = NSAlert()
        alert.messageText = L("Delete Configuration?")
        alert.informativeText = String(format: L("The configuration “%@” will be deleted and Basic will be applied."), profile.name)
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.deleteSettingsProfile(profile, from: document)
            } catch {
                self.showSettingsProfileError("Could not delete configuration.")
            }
        }
    }

    private func deleteSettingsProfile(_ profile: SettingsProfile, from document: SettingsProfileDocument) throws {
        guard let basic = document.profiles.first(where: { $0.kind == .systemBasic }),
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return }
        let updatedDocument = try settingsProfileStore.deletingActiveCustomProfile(
            profile.id,
            from: document,
            activating: basic.id
        )
        isApplyingSettingsProfile = true
        defer { isApplyingSettingsProfile = false }
        try applySettingsProfile(basic, storing: updatedDocument, restoring: document, appDelegate: appDelegate)
        loadSettings()
        refreshSettingsProfilePopup()
    }

    private func safeSettingsProfileFileName(for profile: SettingsProfile) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
        let fileName = settingsProfileDisplayName(profile)
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
        return fileName.isEmpty ? L("Configuration") : fileName
    }

    private func settingsProfileDisplayName(_ profile: SettingsProfile) -> String {
        switch profile.kind {
        case .systemBasic: return L("Slim")
        case .systemFull: return L("Professional")
        case .custom:
            return profile.name == SettingsProfile.currentConfigurationName
                ? L("Current Configuration") : profile.name
        }
    }

    private func copiedSettingsProfileName(for profile: SettingsProfile) -> String {
        String(format: L("Copy of %@"), settingsProfileDisplayName(profile))
    }

    private func showSettingsProfileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L(message)
        alert.informativeText = L("The current settings were kept unchanged.")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func settingsDefaultsDidChange(_ notification: Notification) {
        guard !isApplyingSettingsProfile, !isLoadingSettings, settingsProfileDocument != nil, !profileCaptureScheduled else { return }
        profileCaptureScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.captureCurrentSettingsProfileIfNeeded()
        }
    }

    private func captureCurrentSettingsProfileIfNeeded() {
        profileCaptureScheduled = false
        guard !isApplyingSettingsProfile,
              var document = settingsProfileDocument,
              let index = document.profiles.firstIndex(where: { $0.id == document.activeProfileID }),
              let payload = try? SettingsProfilePreferenceBridge().snapshotCurrentPreferences().payload,
              !SettingsProfileSchema.semanticallyEqual(document.profiles[index].payload, payload)
        else { return }
        let profile = document.profiles[index]
        guard profile.kind == .custom else {
            guard var copiedDocument = try? settingsProfileStore.duplicatingProfile(
                profile.id,
                in: document,
                named: copiedSettingsProfileName(for: profile)
            ), let copiedIndex = copiedDocument.profiles.firstIndex(where: { $0.id == copiedDocument.activeProfileID })
            else { return }
            copiedDocument.profiles[copiedIndex].payload = payload
            guard (try? settingsProfileStore.save(copiedDocument, to: .standard)) != nil else { return }
            settingsProfileDocument = copiedDocument
            refreshSettingsProfilePopup()
            return
        }
        document.profiles[index].payload = payload
        guard (try? settingsProfileStore.save(document, to: .standard)) != nil else { return }
        settingsProfileDocument = document
    }

    // MARK: - Load settings

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        // Load shortcut fields
        for slot in HotkeyManager.HotkeySlot.allCases {
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        refreshHotkeyRegistrationStatus()

        savePathField.stringValue = SaveDirectoryAccess.displayPath
        selectSaveAction(SaveActionPreference.current)

        // Migrate legacy bool to new int setting
        if UserDefaults.standard.object(forKey: "ocrAction") == nil {
            let legacyAutoCopy = UserDefaults.standard.object(forKey: "autoCopyOCRText") as? Bool ?? true
            UserDefaults.standard.set(legacyAutoCopy ? 0 : 1, forKey: "ocrAction")
        }
        ocrActionPopup.selectItem(at: UserDefaults.standard.integer(forKey: "ocrAction"))
        rebuildCaptureMenuOrderRows()

        let copySound = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        copySoundCheckbox.state = copySound ? .on : .off

        // rememberSelectionCheckbox removed

        let thumbnail = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        thumbnailCheckbox.state = thumbnail ? .on : .off

        let autoDismiss = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        thumbnailAutoDismissField.integerValue = autoDismiss
        thumbnailAutoDismissStepper.integerValue = autoDismiss

        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        thumbnailStackingPopup.selectItem(at: stacking ? 0 : 1)

        let thumbnailCorner = UserDefaults.standard.string(forKey: "thumbnailCorner") ?? "bottomRight"
        switch thumbnailCorner {
        case "bottomLeft": thumbnailCornerPopup.selectItem(at: 1)
        case "topRight": thumbnailCornerPopup.selectItem(at: 2)
        case "topLeft": thumbnailCornerPopup.selectItem(at: 3)
        default: thumbnailCornerPopup.selectItem(at: 0)
        }

        let pinZoomAnchor = UserDefaults.standard.string(forKey: PinZoomAnchorMode.userDefaultsKey)
        let anchorMode = PinZoomAnchorMode(rawValue: pinZoomAnchor ?? "") ?? .mouse
        pinZoomAnchorCheckbox.state = anchorMode == .mouse ? .on : .off
        pinWheelZoomCheckbox.state = PinZoomInputPreferences.isWheelZoomEnabled ? .on : .off
        pinMagnifyZoomCheckbox.state = PinZoomInputPreferences.isMagnifyZoomEnabled ? .on : .off
        pinSmoothZoomCheckbox.state = PinZoomInputPreferences.isSmoothZoomEnabled ? .on : .off
        pinCompactShowsPartialImageCheckbox.state = PinCompactDisplayPreference.showsPartialImage ? .on : .off
        let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off

        hideMenuBarIconCheckbox.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off

        let iconMode = UserDefaults.standard.string(forKey: AppDelegate.statusBarIconModeKey) ?? "default"
        menuBarIconModePopup.selectItem(at: iconMode == "symbol" ? 1 : 0)
        menuBarIconSymbolField.stringValue = UserDefaults.standard.string(forKey: AppDelegate.statusBarIconSymbolNameKey) ?? ""
        updateMenuBarIconControlsEnabled()

        translationProviderPopup?.selectItem(at: TranslationService.provider == .apple ? 0 : 1)
        googleTranslationAllowedCheckbox?.state = TranslationService.googleTranslationAllowed ? .on : .off
        updateTranslationProviderStatus()

        let snapGuides = UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
        snapGuidesCheckbox.state = snapGuides ? .on : .off
        let boundarySnap = UserDefaults.standard.object(forKey: "boundarySnapEnabled") as? Bool ?? true
        boundarySnapCheckbox.state = boundarySnap ? .on : .off
        ignoreWindowOcclusionCheckbox.state = UserDefaults.standard.bool(
            forKey: "ignoreWindowOcclusionForSnaps") ? .on : .off
        showToolShortcutsInTooltipsCheckbox.state = UserDefaults.standard.bool(forKey: "showToolShortcutsInTooltips") ? .on : .off

        captureCursorCheckbox.state = UserDefaults.standard.bool(forKey: "captureCursor") ? .on : .off
        doubleClickToCopyCheckbox.state = (UserDefaults.standard.object(forKey: "doubleClickToCopy") as? Bool ?? true) ? .on : .off
        hideCaptureInstructionsCheckbox.state = UserDefaults.standard.bool(forKey: "hideCaptureInstructions") ? .on : .off
        disableSelectionShadowCheckbox.state = UserDefaults.standard.bool(forKey: "disableSelectionOutsideShadow") ? .on : .off
        translateSelectedTextCheckbox.state = SelectedTextTranslationPreference.isEnabled ? .on : .off
        filenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        updateFilenamePreview()
        recordingFilenameTemplateField.stringValue = UserDefaults.standard.string(forKey: FilenameFormatter.recordingUserDefaultsKey) ?? FilenameFormatter.defaultRecordingTemplate
        updateRecordingFilenamePreview()

        accentColorWell.color = ToolbarLayout.accentColor
        iconColorWell.color = ToolbarLayout.iconColor
        bgColorWell.color = ToolbarLayout.bgColor
        updateThemePresetSelection()
        let applicationAppearance = ApplicationAppearancePreference.current().rawValue
        if let index = applicationAppearancePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == applicationAppearance
        }) {
            applicationAppearancePopup.selectItem(at: index)
        }

        let historySize = UserDefaults.standard.object(forKey: "historySize") as? Int ?? 10
        historySizeField.integerValue = historySize
        historySizeStepper.integerValue = historySize
        historyUnlimitedCheckbox.state = UserDefaults.standard.bool(forKey: "historyUnlimited") ? .on : .off
        updateHistoryControlsEnabled()

        // Migrate old bool setting to new int: 0=save, 1=copy, 2=both
        if let oldBool = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool {
            let mode = oldBool ? 1 : 0
            // If old autoCopy was on + save mode, migrate to "both"
            let hadAutoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
            let migratedMode = (!oldBool && hadAutoCopy) ? 2 : mode
            UserDefaults.standard.set(migratedMode, forKey: "quickCaptureMode")
            UserDefaults.standard.removeObject(forKey: "quickModeCopyToClipboard")
            UserDefaults.standard.removeObject(forKey: "autoCopyToClipboard")
        }
        let quickMode = CaptureOutputAction.current()
        if let index = quickModePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == quickMode.rawValue
        }) {
            quickModePopup.selectItem(at: index)
        }

        selectImageFormat(ImageEncoder.format)

        let quality = Int(ImageEncoder.quality * 100)
        qualitySlider.integerValue = quality
        qualityLabel.stringValue = String(format: L("%d%%"), quality)

        downscaleRetinaCheckbox.state = ImageEncoder.downscaleRetina ? .on : .off
        updateQualityVisibility()

        #if !OFFLINE
        imgbbKeyField.stringValue = UserDefaults.standard.string(forKey: "imgbbAPIKey") ?? ""
        #endif

        // Recording
        let recFPS = UserDefaults.standard.integer(forKey: "recordingFPS")
        let mp4Options = [15, 24, 30, 60, 120]
        let fpsIdx = mp4Options.firstIndex(of: recFPS) ?? 2
        recordingFPSPopup.selectItem(at: fpsIdx)
        let recordingQuality = UserDefaults.standard.string(forKey: "recordingQuality") ?? LiveRecordingQuality.automatic.rawValue
        if let index = recordingQualityPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == recordingQuality }) {
            recordingQualityPopup.selectItem(at: index)
        } else {
            recordingQualityPopup.selectItem(at: 0)
        }

        let onStop = UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
        switch onStop {
        case "finder": recordingOnStopPopup.selectItem(at: 1)
        case "clipboard": recordingOnStopPopup.selectItem(at: 2)
        default: recordingOnStopPopup.selectItem(at: 0)
        }

        recSavePathField.stringValue = SaveDirectoryAccess.recordingDisplayPath

        // Webcam
        let webcamPos = UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight"
        switch webcamPos {
        case "bottomRight": webcamPositionPopup.selectItem(at: 0)
        case "bottomLeft": webcamPositionPopup.selectItem(at: 1)
        case "topRight": webcamPositionPopup.selectItem(at: 2)
        case "topLeft": webcamPositionPopup.selectItem(at: 3)
        default: webcamPositionPopup.selectItem(at: 0)
        }

        let webcamSize = UserDefaults.standard.string(forKey: "webcamSize") ?? "medium"
        switch webcamSize {
        case "small": webcamSizePopup.selectItem(at: 0)
        case "medium": webcamSizePopup.selectItem(at: 1)
        case "large": webcamSizePopup.selectItem(at: 2)
        case "xlarge": webcamSizePopup.selectItem(at: 3)
        default: webcamSizePopup.selectItem(at: 1)
        }

        webcamShapePopup.selectItem(at: (UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") == "roundedRect" ? 1 : 0)

        // Scroll Capture
        let autoScroll = UserDefaults.standard.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        scrollAutoScrollCheckbox.state = autoScroll ? .on : .off
        let speed = UserDefaults.standard.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        scrollSpeedPopup.selectItem(at: max(0, min(3, speed - 1)))
        scrollSpeedPopup.isEnabled = autoScroll
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        scrollMaxHeightField.integerValue = maxH
        scrollMaxHeightStepper.integerValue = maxH
        let frozenDetect = UserDefaults.standard.object(forKey: "scrollFrozenDetection") as? Bool ?? true
        scrollFrozenDetectionCheckbox.state = frozenDetect ? .on : .off
    }

    func refreshHotkeyRegistrationStatus() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            guard let field = hotkeyFields[slot] else { continue }
            let status = HotkeyManager.shared.registrationStatus(for: slot) ?? noErr
            if status == noErr {
                field.textColor = .labelColor
                field.toolTip = nil
            } else {
                field.textColor = .systemRed
                field.toolTip = String(format: L("Shortcut unavailable (error %d)"), status)
            }
        }
    }

    /// Profile application currently changes global shortcut status before the
    /// profile picker UI is added; keep this semantic refresh point centralized
    /// for that later settings section.
    func refreshAfterSettingsProfileApply() {
        refreshHotkeyRegistrationStatus()
    }

    private func updateQualityVisibility() {
        let raw = imageFormatPopup.selectedItem?.representedObject as? String
        let hasQuality = raw.flatMap(ImageEncoder.Format.init(rawValue:))?.hasQuality ?? false
        qualitySlider.isEnabled = hasQuality
        qualityLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
        qualityRowLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
    }

    private func selectImageFormat(_ format: ImageEncoder.Format) {
        for item in imageFormatPopup.itemArray {
            if item.representedObject as? String == format.rawValue {
                imageFormatPopup.select(item)
                return
            }
        }
        imageFormatPopup.selectItem(at: 0)
    }

    private func selectSaveAction(_ action: SaveActionPreference) {
        for item in saveActionPopup.itemArray {
            if item.representedObject as? Int == action.rawValue {
                saveActionPopup.select(item)
                return
            }
        }
        saveActionPopup.selectItem(at: 0)
    }

    // MARK: - Actions

    @objc private func browseSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.save(url: url)
            self?.savePathField.stringValue = url.path
        }
    }

    @objc private func ocrActionChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "ocrAction")
    }
    @objc private func saveActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? Int,
              let action = SaveActionPreference(rawValue: raw) else { return }
        SaveActionPreference.current = action
    }
    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
    }
    @objc private func thumbnailChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showFloatingThumbnail")
    }
    @objc private func thumbnailAutoDismissChanged(_ sender: NSStepper) {
        thumbnailAutoDismissField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "thumbnailAutoDismiss")
    }
    @objc private func thumbnailScaleChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "thumbnailScale")
        thumbnailScaleLabel?.stringValue = scalePercentString(sender.doubleValue)
    }

    private func scalePercentString(_ scale: Double) -> String {
        "\(Int(round(scale * 100)))%"
    }

    @objc private func thumbnailStackingChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0, forKey: "thumbnailStacking")
    }
    @objc private func thumbnailCornerChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "thumbnailCorner")
    }
    @objc private func pinZoomAnchorChanged(_ sender: NSButton) {
        let mode: PinZoomAnchorMode = sender.state == .on ? .mouse : .topLeft
        UserDefaults.standard.set(mode.rawValue, forKey: PinZoomAnchorMode.userDefaultsKey)
    }
    @objc private func pinWheelZoomChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: PinZoomInputPreferences.wheelEnabledKey)
    }
    @objc private func pinMagnifyZoomChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: PinZoomInputPreferences.magnifyEnabledKey)
    }
    @objc private func pinSmoothZoomChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: PinZoomInputPreferences.smoothEnabledKey)
    }
    @objc private func pinCompactShowsPartialImageChanged(_ sender: NSButton) {
        PinCompactDisplayPreference.setShowsPartialImage(sender.state == .on)
    }
    @objc private func quickModeChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? Int,
              CaptureOutputAction(rawValue: rawValue) != nil
        else { return }
        UserDefaults.standard.set(rawValue, forKey: CaptureOutputAction.userDefaultsKey)
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let languages = LanguageManager.availableLanguages
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < languages.count else { return }
        LanguageManager.shared.currentLanguage = languages[idx].code
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(AppIdentity.maintainerURL)
    }
    @objc private func imageFormatChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let format = ImageEncoder.Format(rawValue: raw),
              ImageEncoder.isFormatAvailable(format)
        else { return }
        UserDefaults.standard.set(raw, forKey: "imageFormat")
        updateQualityVisibility()
    }
    @objc private func qualityChanged(_ sender: NSSlider) {
        qualityLabel.stringValue = String(format: L("%d%%"), sender.integerValue)
        UserDefaults.standard.set(Double(sender.integerValue) / 100.0, forKey: "imageQuality")
    }
    @objc private func downscaleRetinaChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "downscaleRetina")
    }
    #if !OFFLINE
    @objc private func imgbbKeyChanged(_ sender: NSTextField) {
        let key = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { UserDefaults.standard.removeObject(forKey: "imgbbAPIKey") }
        else { UserDefaults.standard.set(key, forKey: "imgbbAPIKey") }
    }
    #endif
    @objc private func historySizeChanged(_ sender: NSStepper) {
        historySizeField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "historySize")
        UserDefaults.standard.set(false, forKey: "historyUnlimited")
        historyUnlimitedCheckbox.state = .off
        updateHistoryControlsEnabled()
        ScreenshotHistory.shared.pruneToMax()
    }

    @objc private func historyUnlimitedChanged(_ sender: NSButton) {
        let unlimited = sender.state == .on
        UserDefaults.standard.set(unlimited, forKey: "historyUnlimited")
        updateHistoryControlsEnabled()
    }

    @objc private func historyOrderByLastEditChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "historyOrderByLastEdit")
        // Re-sort existing entries to reflect the new preference immediately and
        // persist the new order so it survives a restart.
        ScreenshotHistory.shared.applyHistoryOrderPreference(persist: true)
    }

    private func updateHistoryControlsEnabled() {
        let unlimited = UserDefaults.standard.bool(forKey: "historyUnlimited")
        historySizeField.alphaValue = unlimited ? 0.35 : 1.0
        historySizeStepper.isEnabled = !unlimited
    }
    @objc private func recordingFPSChanged(_ sender: NSPopUpButton) {
        let fpsOptions = [15, 24, 30, 60, 120]
        let fps = fpsOptions[min(sender.indexOfSelectedItem, fpsOptions.count - 1)]
        UserDefaults.standard.set(fps, forKey: "recordingFPS")
    }
    @objc private func recordingQualityChanged(_ sender: NSPopUpButton) {
        guard let quality = sender.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(quality, forKey: "recordingQuality")
    }
    @objc private func recordingOnStopChanged(_ sender: NSPopUpButton) {
        let values = ["editor", "finder", "clipboard"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "recordingOnStop")
    }
    @objc private func hideRecordingHUDChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideRecordingHUD")
    }

    @objc private func webcamPositionChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamPosition")
    }

    @objc private func webcamSizeChanged(_ sender: NSPopUpButton) {
        let values = ["small", "medium", "large", "xlarge"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamSize")
    }

    @objc private func webcamShapeChanged(_ sender: NSPopUpButton) {
        let values = ["circle", "roundedRect"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamShape")
    }

    @objc private func browseRecSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.saveRecordingDirectory(url: url)
            self?.recSavePathField.stringValue = url.path
        }
    }
    @objc private func clearRecSavePath(_ sender: NSButton) {
        SaveDirectoryAccess.clearRecordingDirectory()
        recSavePathField.stringValue = SaveDirectoryAccess.recordingDisplayPath
    }
    // MARK: - Scroll Capture actions
    @objc private func scrollAutoScrollChanged(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "scrollAutoScrollEnabled")
        scrollSpeedPopup.isEnabled = on
    }
    @objc private func scrollSpeedChanged(_ sender: NSPopUpButton) {
        // 0=Slow(1), 1=Medium(2), 2=Fast(3), 3=VeryFast(4)
        UserDefaults.standard.set(sender.indexOfSelectedItem + 1, forKey: "scrollAutoScrollSpeed")
    }
    @objc private func scrollMaxHeightChanged(_ sender: NSStepper) {
        scrollMaxHeightField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "scrollMaxHeight")
    }
    @objc private func scrollFrozenDetectionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "scrollFrozenDetection")
    }
    @objc private func toggleItemChanged(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? "enabledTools"
        let defaultValues: [Int] = key == "enabledTools"
            ? ToolbarToolPreferences.allConfigurableTools.map { $0.rawValue }
            : ToolbarActionPreferences.defaultEnabledRawValues
        var enabled = UserDefaults.standard.array(forKey: key) as? [Int] ?? defaultValues
        if sender.state == .on { if !enabled.contains(sender.tag) { enabled.append(sender.tag) } }
        else { enabled.removeAll { $0 == sender.tag } }
        UserDefaults.standard.set(enabled, forKey: key)
    }
    @objc private func toolbarToolEnabledChanged(_ sender: NSButton) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        ToolbarToolPreferences.setTool(tool, enabled: sender.state == .on)
    }
    @objc private func pinShadowToolEnabledChanged(_ sender: NSButton) {
        var enabled = UserDefaults.standard.array(forKey: ToolbarActionPreferences.enabledDefaultsKey) as? [Int]
            ?? ToolbarActionPreferences.defaultEnabledRawValues
        if sender.state == .on {
            if !enabled.contains(ToolbarCustomAction.pinShadow.rawValue) {
                enabled.append(ToolbarCustomAction.pinShadow.rawValue)
            }
        } else {
            enabled.removeAll { $0 == ToolbarCustomAction.pinShadow.rawValue }
        }
        UserDefaults.standard.set(enabled, forKey: ToolbarActionPreferences.enabledDefaultsKey)
        UserDefaults.standard.set(ToolbarActionPreferences.allKnownRawValues, forKey: ToolbarActionPreferences.knownDefaultsKey)
    }
    @objc private func selectTextToolEnabledChanged(_ sender: NSButton) {
        var enabled = UserDefaults.standard.array(forKey: ToolbarActionPreferences.enabledDefaultsKey) as? [Int]
            ?? ToolbarActionPreferences.defaultEnabledRawValues
        if sender.state == .on {
            if !enabled.contains(ToolbarCustomAction.selectText.rawValue) {
                enabled.append(ToolbarCustomAction.selectText.rawValue)
            }
        } else {
            enabled.removeAll { $0 == ToolbarCustomAction.selectText.rawValue }
        }
        UserDefaults.standard.set(enabled, forKey: ToolbarActionPreferences.enabledDefaultsKey)
        UserDefaults.standard.set(ToolbarActionPreferences.allKnownRawValues, forKey: ToolbarActionPreferences.knownDefaultsKey)
    }
    @objc private func screenTranslationToolEnabledChanged(_ sender: NSButton) {
        var enabled = UserDefaults.standard.array(forKey: ToolbarActionPreferences.enabledDefaultsKey) as? [Int]
            ?? ToolbarActionPreferences.defaultEnabledRawValues
        if sender.state == .on {
            if !enabled.contains(ToolbarCustomAction.screenTranslation.rawValue) {
                enabled.append(ToolbarCustomAction.screenTranslation.rawValue)
            }
        } else {
            enabled.removeAll { $0 == ToolbarCustomAction.screenTranslation.rawValue }
        }
        UserDefaults.standard.set(enabled, forKey: ToolbarActionPreferences.enabledDefaultsKey)
        UserDefaults.standard.set(ToolbarActionPreferences.allKnownRawValues, forKey: ToolbarActionPreferences.knownDefaultsKey)
    }
    @objc private func specialPinToolbarItemMoveUp(_ sender: NSButton) {
        moveSpecialPinToolbarItem(sender, offset: -1)
    }

    @objc private func specialPinToolbarItemMoveDown(_ sender: NSButton) {
        moveSpecialPinToolbarItem(sender, offset: 1)
    }

    @objc private func specialPinToolbarItemTransfer(_ sender: NSButton) {
        guard let (isPrimary, item) = specialPinToolbarItem(from: sender) else { return }
        PinToolbarLayoutPreferences.transfer(item, toPrimary: !isPrimary)
        rebuildToolbarToolOrderRows(isPrimary: true)
        rebuildToolbarToolOrderRows(isPrimary: false)
    }

    private func moveSpecialPinToolbarItem(_ sender: NSButton, offset: Int) {
        guard let (isPrimary, item) = specialPinToolbarItem(from: sender) else { return }
        PinToolbarLayoutPreferences.move(item, inPrimary: isPrimary, offset: offset)
        rebuildToolbarToolOrderRows(isPrimary: isPrimary)
    }

    private func specialPinToolbarItem(from sender: NSButton) -> (Bool, PinToolbarLayoutItem)? {
        guard let value = sender.identifier?.rawValue,
              let separator = value.firstIndex(of: "|")
        else { return nil }
        let group = String(value[..<separator])
        let storageValue = String(value[value.index(after: separator)...])
        guard let item = PinToolbarLayoutItem(storageValue: storageValue) else { return nil }
        return (group == "primary", item)
    }

    @objc private func dedicatedToolVisibilityChanged(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: ".", maxSplits: 1),
              parts.count == 2,
              let context = DedicatedToolbarContext(rawValue: String(parts[0])),
              let tool = DedicatedToolbarTool(rawValue: String(parts[1])) else { return }
        DedicatedToolPreferences.setVisible(sender.state == .on, tool: tool, in: context)
    }

    @objc private func accentColorChanged(_ sender: NSColorWell) {
        ToolbarColorScheme.selectCustom()
        ToolbarLayout.saveAccentColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func iconColorChanged(_ sender: NSColorWell) {
        ToolbarColorScheme.selectCustom()
        ToolbarLayout.saveIconColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func bgColorChanged(_ sender: NSColorWell) {
        ToolbarColorScheme.selectCustom()
        ToolbarLayout.saveBgColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }

    @objc private func applicationAppearanceChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let preference = ApplicationAppearancePreference(rawValue: rawValue)
        else { return }
        preference.save()
        ApplicationAppearancePreference.applyCurrent()
        ToolbarColorScheme.applyCurrentAppearance(appearance: NSApp.effectiveAppearance)
        refreshToolbarColorWells()
    }

    private func makeColorColumn(well: NSColorWell, caption: String) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let col = NSStackView(views: [well, label])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    @objc private func themePresetChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let id = ToolbarColorSchemeID(rawValue: rawValue),
              id != .custom
        else { return }
        ToolbarColorScheme.select(id, appearance: NSApp.effectiveAppearance)
        refreshToolbarColorWells()
        updateThemePresetSelection()
    }

    private func updateThemePresetSelection() {
        guard let popup = themePresetPopup else { return }
        let id = ToolbarColorScheme.currentID()
        if let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == id.rawValue
        }) {
            popup.selectItem(at: index)
        }
    }

    private func refreshToolbarColorWells() {
        accentColorWell.color = ToolbarLayout.accentColor
        iconColorWell.color = ToolbarLayout.iconColor
        bgColorWell.color = ToolbarLayout.bgColor
    }
    private func notifyToolbarColorChange() {
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }
    @objc private func copyUploadURL(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("link::") else { return }
        let url = String(id.dropFirst(6))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        let orig = sender.title
        sender.title = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sender.title = orig }
    }
    @objc private func snapGuidesChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "snapGuidesEnabled")
    }
    @objc private func boundarySnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "boundarySnapEnabled")
    }
    @objc private func ignoreWindowOcclusionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ignoreWindowOcclusionForSnaps")
    }
    @objc private func captureCursorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "captureCursor")
    }
    @objc private func doubleClickToCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "doubleClickToCopy")
    }
    @objc private func hideCaptureInstructionsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideCaptureInstructions")
    }
    @objc private func disableSelectionShadowChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "disableSelectionOutsideShadow")
    }
    @objc private func selectedTextTranslationChanged(_ sender: NSButton) {
        guard sender.state == .on else {
            SelectedTextTranslationPreference.wantsEnabled = false
            return
        }

        guard SelectedTextTranslationPreference.settingsEnableAction()
                == .requestSystemPermission
        else {
            sender.state = .on
            return
        }

        if !SelectedTextReader.hasAccessibilityPermission {
            sender.state = .off
            SelectedTextReader.requestAccessibilityPermission()

            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required")
            alert.informativeText = L("Pinlume needs Accessibility permission to translate selected text. Open System Settings to grant access. If Pinlume is not listed, click the + button and choose the running Pinlume app.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Open Settings"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            } else {
                SelectedTextTranslationPreference.wantsEnabled = false
            }
            return
        }

        sender.state = .on
    }

    func refreshSelectedTextTranslationPermissionState() {
        translateSelectedTextCheckbox?.state =
            SelectedTextTranslationPreference.isEnabled ? .on : .off
    }
    @objc private func filenameTemplateCommitted(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? FilenameFormatter.defaultTemplate : sender.stringValue
        if trimmed.isEmpty {
            sender.stringValue = FilenameFormatter.defaultTemplate
        }
        UserDefaults.standard.set(value, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    @objc private func filenameTemplateReset(_ sender: NSButton) {
        filenameTemplateField.stringValue = FilenameFormatter.defaultTemplate
        UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    fileprivate func updateFilenamePreview() {
        guard let field = filenameTemplateField, let preview = filenameTemplatePreview else { return }
        let raw = field.stringValue
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FilenameFormatter.defaultTemplate : raw
        let sampleDate = sampleFilenameDate()
        let sampleWindow = template.contains("{window}") ? "Example Window" : nil
        let sampleIndex = template.contains("{index}") ? 1 : nil
        let base = FilenameFormatter.format(template: template, windowTitle: sampleWindow, index: sampleIndex, date: sampleDate)
        preview.stringValue = "\(L("Preview:")) \(base).\(ImageEncoder.fileExtension)"
    }

    @objc private func recordingFilenameTemplateCommitted(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? FilenameFormatter.defaultRecordingTemplate : sender.stringValue
        if trimmed.isEmpty {
            sender.stringValue = FilenameFormatter.defaultRecordingTemplate
        }
        UserDefaults.standard.set(value, forKey: FilenameFormatter.recordingUserDefaultsKey)
        updateRecordingFilenamePreview()
    }

    @objc private func recordingFilenameTemplateReset(_ sender: NSButton) {
        recordingFilenameTemplateField.stringValue = FilenameFormatter.defaultRecordingTemplate
        UserDefaults.standard.set(FilenameFormatter.defaultRecordingTemplate, forKey: FilenameFormatter.recordingUserDefaultsKey)
        updateRecordingFilenamePreview()
    }

    fileprivate func updateRecordingFilenamePreview() {
        guard let field = recordingFilenameTemplateField, let preview = recordingFilenameTemplatePreview else { return }
        let raw = field.stringValue
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FilenameFormatter.defaultRecordingTemplate : raw
        let sampleDate = sampleFilenameDate()
        let sampleIndex = template.contains("{index}") ? 1 : nil
        let base = FilenameFormatter.format(template: template, windowTitle: nil, index: sampleIndex, date: sampleDate, fallback: FilenameFormatter.defaultRecordingTemplate)
        preview.stringValue = "\(L("Preview:")) \(base).mp4"
    }

    private func sampleFilenameDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 14; comps.minute = 22; comps.second = 5
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("Failed to update login item: \(error)")
                #endif
            }
        }
    }

    @objc private func urlSchemeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "urlSchemeEnabled")
    }

    fileprivate var urlSchemeInfoPopover: NSPopover?
    fileprivate var filenameTemplateInfoPopover: NSPopover?

    fileprivate func showURLSchemeInfoPopover(near sourceView: NSView) {
        if let existing = urlSchemeInfoPopover, existing.isShown { return }

        let commands: [(String, String)] = [
            ("\(BuildVariant.actionsURLScheme)://capture",             L("Start area capture")),
            ("\(BuildVariant.actionsURLScheme)://capture-fullscreen",  L("Capture the full screen")),
            ("\(BuildVariant.actionsURLScheme)://capture-last",        L("Re-capture the last selected area")),
            ("\(BuildVariant.actionsURLScheme)://quick-capture",       L("Quick capture (uses your Enter action)")),
            ("\(BuildVariant.actionsURLScheme)://ocr",                 L("Capture area and read text/QR codes")),
            ("\(BuildVariant.actionsURLScheme)://record",              L("Start area recording")),
            ("\(BuildVariant.actionsURLScheme)://record-fullscreen",   L("Start full-screen recording")),
            ("\(BuildVariant.actionsURLScheme)://stop-recording",      L("Stop the current recording")),
            ("\(BuildVariant.actionsURLScheme)://scroll-capture",      L("Start scroll capture")),
            ("\(BuildVariant.actionsURLScheme)://history",             L("Open the recent captures overlay")),
            ("\(BuildVariant.actionsURLScheme)://settings",            L("Open this settings window")),
            ("\(BuildVariant.actionsURLScheme)://open?file=/path.png", L("Open an image file in the editor")),
        ]

        let title = NSTextField(labelWithString: L("Supported URL Scheme Commands"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("Trigger Pinlume from Raycast, Alfred, Shortcuts, or any tool that opens URLs."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 440
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // NSGridView for perfect column alignment — each row's cmd column and
        // desc column line up precisely regardless of text width.
        let grid = NSGridView(numberOfColumns: 2, rows: commands.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in commands.enumerated() {
            let cmdLabel = NSTextField(labelWithString: entry.0)
            cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cmdLabel.textColor = .labelColor
            cmdLabel.isSelectable = true

            let descLabel = NSTextField(labelWithString: entry.1)
            descLabel.font = NSFont.systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = cmdLabel
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = descLabel
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container

        // Compute fitting size for the popover
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = fitting
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        urlSchemeInfoPopover = popover
    }

    @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
        let hidden = sender.state == .on
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hidden)
    }

    @objc private func menuBarIconModeChanged(_ sender: NSPopUpButton) {
        let mode = sender.indexOfSelectedItem == 1 ? "symbol" : "default"
        UserDefaults.standard.set(mode, forKey: AppDelegate.statusBarIconModeKey)
        updateMenuBarIconControlsEnabled()
        (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
    }

    @objc private func menuBarIconPresetChanged(_ sender: NSPopUpButton) {
        // Pull-down: index 0 is the "Presets" label; real symbols start at 1.
        guard sender.indexOfSelectedItem >= 1,
              let symbol = sender.titleOfSelectedItem, !symbol.isEmpty else { return }
        menuBarIconSymbolField.stringValue = symbol
        applyMenuBarIconSymbol(symbol)
    }

    @objc private func menuBarIconSymbolChanged(_ sender: NSTextField) {
        applyMenuBarIconSymbol(sender.stringValue)
    }

    private func applyMenuBarIconSymbol(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppDelegate.statusBarIconSymbolNameKey)
        } else {
            UserDefaults.standard.set(name, forKey: AppDelegate.statusBarIconSymbolNameKey)
        }
        (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
    }

    /// Enables the symbol field + preset picker only in "Custom symbol" mode.
    private func updateMenuBarIconControlsEnabled() {
        let custom = menuBarIconModePopup.indexOfSelectedItem == 1
        menuBarIconSymbolField.isEnabled = custom
        menuBarIconPresetPopup.isEnabled = custom
    }

    @objc private func translationProviderChanged(_ sender: NSPopUpButton) {
        TranslationService.provider = sender.indexOfSelectedItem == 0 ? .apple : .google
        updateTranslationProviderStatus()
    }

    @objc private func googleTranslationAllowedChanged(_ sender: NSButton) {
        TranslationService.googleTranslationAllowed = sender.state == .on
        updateTranslationProviderStatus()
    }

    private func updateTranslationProviderStatus() {
        guard translationProviderStatusLabel != nil else { return }
        let googleUnavailable = TranslationService.provider == .google
            && !TranslationService.googleTranslationAllowed
        translationProviderStatusLabel.stringValue = googleUnavailable
            ? L("Google translation is unavailable because sending text is disabled.")
            : ""
        translationProviderStatusLabel.textColor = googleUnavailable ? .systemRed : .secondaryLabelColor
        translationProviderStatusLabel.isHidden = !googleUnavailable
    }

    @objc private func openTranslationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization.Settings.extension?Translation") {
            NSWorkspace.shared.open(url)
        }
    }

    func showWindow() {
        loadSettings()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopShortcutRecording()
        stopToolShortcutRecording()
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}

// MARK: - NSTextFieldDelegate (live filename preview)

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === filenameTemplateField {
            // Save on every keystroke so closing the window without pressing
            // Enter doesn't silently lose the edit. Empty value resets to
            // the default template at commit time (see controlTextDidEndEditing).
            UserDefaults.standard.set(field.stringValue, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        } else if field === recordingFilenameTemplateField {
            UserDefaults.standard.set(field.stringValue, forKey: FilenameFormatter.recordingUserDefaultsKey)
            updateRecordingFilenamePreview()
        } else if field === menuBarIconSymbolField {
            applyMenuBarIconSymbol(field.stringValue)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // On commit, replace empty/whitespace-only values with the default so
        // the user never ends up with a blank template saved.
        guard let field = obj.object as? NSTextField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field === filenameTemplateField, trimmed.isEmpty {
            field.stringValue = FilenameFormatter.defaultTemplate
            UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        } else if field === recordingFilenameTemplateField, trimmed.isEmpty {
            field.stringValue = FilenameFormatter.defaultRecordingTemplate
            UserDefaults.standard.set(FilenameFormatter.defaultRecordingTemplate, forKey: FilenameFormatter.recordingUserDefaultsKey)
            updateRecordingFilenamePreview()
        }
    }
}

// MARK: - Filename template info popover

extension SettingsWindowController {
    fileprivate func showFilenameTemplateInfoPopover(near sourceView: NSView) {
        if let existing = filenameTemplateInfoPopover, existing.isShown { return }

        let tokens: [(String, String)] = [
            ("{date}",      "2026-04-17"),
            ("{time}",      "14-22-05"),
            ("{timestamp}", "2026-04-17_14-22-05"),
            ("{unix}",      "1745592125"),
            ("{window}",    L("Screenshots only — captured window title (blank otherwise)")),
            ("{index}",     L("Counter for multi-screen captures")),
            ("{random}",    L("8-character random string (e.g. k3j7x9q2)")),
        ]

        let title = NSTextField(labelWithString: L("Filename Template Tokens"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("The file extension is appended automatically. Slashes and colons in {window} become dashes."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 380
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(numberOfColumns: 2, rows: tokens.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in tokens.enumerated() {
            let tok = NSTextField(labelWithString: entry.0)
            tok.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tok.textColor = .labelColor
            tok.isSelectable = true

            let desc = NSTextField(labelWithString: entry.1)
            desc.font = NSFont.systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = tok
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = desc
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container
        container.layoutSubtreeIfNeeded()
        vc.preferredContentSize = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        filenameTemplateInfoPopover = popover
    }
}
