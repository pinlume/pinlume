import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case moreTools
    case separator
    case sizeDisplay
    case undo
    case redo
    case copy
    case copyText
    case selectText
    case translationPinToggle
    case translationPinLanguage
    case screenTranslationCompare
    case startScreenTranslation
    case recognizeSelectableText
    case copyRecognizedText
    case pinSelectableText
    case save
    case confirmAnnotation
    /// Transparent annotation Pins are preview-only. This action reopens the
    /// original vector payload in the dedicated transparent selection session.
    case reeditTransparentAnnotation
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case flipHorizontal
    case flipVertical
    case rotateClockwise
    case pinShadowToggle
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case showKeystrokes
    case webcam
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var isEnabled: Bool = true
    var tintColor: NSColor = ToolbarLayout.iconColor
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
    var isSeparator: Bool = false
    /// Overrides the shortcut inferred from `action` when one visual action
    /// has a context-specific meaning (for example Copy Original vs Copy Text).
    var shortcutAction: ToolShortcutManager.Action? = nil
}

enum ToolbarCustomAction: Int {
    #if !OFFLINE
    case upload = 1001
    #endif
    case pin = 1002
    case ocr = 1003
    case beautify = 1004
    case removeBackground = 1005
    case autoRedact = 1006
    case reserved1007 = 1007
    case translate = 1008
    case record = 1009
    case scrollCapture = 1010
    case invertColors = 1011
    case share = 1012
    case effects = 1013
    case flipHorizontal = 1014
    case flipVertical = 1015
    case rotateClockwise = 1016
    case pinShadow = 1017
    case copyText = 1018
    case selectText = 1019
    case cancel = 1020
    case save = 1021
    case copy = 1022
    case screenTranslation = 1023

    static var allKnownActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [
            .pin, .ocr, .beautify, .removeBackground, .autoRedact, .reserved1007,
            .translate, .record, .scrollCapture, .invertColors, .share, .effects,
            .flipHorizontal, .flipVertical, .rotateClockwise, .pinShadow, .copyText,
            .selectText, .cancel, .save, .copy, .screenTranslation,
        ])
        return actions
    }

    static var bottomToolbarActions: [ToolbarCustomAction] {
        [.invertColors, .effects, .beautify, .removeBackground]
    }

    static var rightToolbarActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = [.share]
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .translate, .scrollCapture, .record])
        return actions
    }

    static var bottomSettingsActions: [ToolbarCustomAction] {
        bottomToolbarActions
    }

    static var rightSettingsActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .autoRedact, .translate, .record, .scrollCapture, .share])
        return actions
    }

    var settingsLabel: String {
        switch self {
        #if !OFFLINE
        case .upload: return L("Upload")
        #endif
        case .pin: return L("Pin to Screen")
        case .ocr: return L("Text Recognition / QR")
        case .beautify: return L("Beautify Screenshot")
        case .removeBackground: return L("Remove Background")
        case .autoRedact: return L("Auto-Redact Sensitive Information")
        case .reserved1007: return ""
        case .translate: return L("Translate")
        case .record: return L("Record")
        case .scrollCapture: return L("Scroll Capture")
        case .invertColors: return L("Invert Colors")
        case .flipHorizontal: return L("Flip Horizontal")
        case .flipVertical: return L("Flip Vertical")
        case .rotateClockwise: return L("Rotate Clockwise")
        case .pinShadow: return L("Pin Shadow")
        case .copyText: return L("Copy Pinned Text")
        case .selectText: return L("Select Text")
        case .cancel: return L("Cancel")
        case .save: return L("Save")
        case .copy: return L("Copy")
        case .screenTranslation: return L("Screen Translation")
        case .share: return L("Share")
        case .effects: return L("Image Adjustments")
        }
    }

    func makeToolbarButton(
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> ToolbarButton? {
        switch self {
        #if !OFFLINE
        case .upload:
            var button = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", tooltip: L("Upload"))
            button.hasContextMenu = true
            return button
        #endif
        case .pin:
            return ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin"))
        case .ocr:
            return ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR"))
        case .beautify:
            var button = ToolbarButton(action: .beautify, sfSymbol: "sparkles", tooltip: L("Beautify"))
            if beautifyEnabled {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        case .removeBackground:
            if #available(macOS 14.0, *) {
                return ToolbarButton(
                    action: .removeBackground,
                    sfSymbol: "person.crop.circle.dashed",
                    tooltip: L("Remove Background")
                )
            }
            return nil
        case .autoRedact, .reserved1007:
            return nil
        case .translate:
            var button = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: L("Translate"))
            button.isSelected = translateEnabled
            button.hasContextMenu = true
            return button
        case .record:
            guard !isEditorMode else { return nil }
            var button = ToolbarButton(action: .record, sfSymbol: "video.fill", tooltip: L("Record"))
            button.tintColor = ToolbarLayout.iconColor
            return button
        case .scrollCapture:
            guard !isRecording && !isEditorMode else { return nil }
            return ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture"))
        case .invertColors:
            return ToolbarButton(
                action: .invertColors,
                sfSymbol: "circle.righthalf.filled.inverse",
                tooltip: L("Invert Colors")
            )
        case .flipHorizontal:
            return ToolbarButton(
                action: .flipHorizontal,
                sfSymbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                tooltip: L("Flip Horizontal")
            )
        case .flipVertical:
            return ToolbarButton(
                action: .flipVertical,
                sfSymbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                tooltip: L("Flip Vertical")
            )
        case .rotateClockwise:
            return ToolbarButton(
                action: .rotateClockwise,
                sfSymbol: "rotate.right",
                tooltip: L("Rotate Clockwise")
            )
        case .pinShadow:
            var button = ToolbarButton(
                action: .pinShadowToggle,
                sfSymbol: "square.stack.3d.down.right",
                tooltip: L("Pin Shadow")
            )
            button.isSelected = false
            return button
        case .copyText:
            return ToolbarButton(action: .copyText, sfSymbol: "text.badge.plus", tooltip: L("Copy Text"))
        case .selectText:
            return ToolbarButton(action: .selectText, sfSymbol: "text.cursor", tooltip: L("Select Text"))
        case .screenTranslation:
            return ToolbarButton(
                action: .startScreenTranslation,
                sfSymbol: "character.book.closed",
                tooltip: L("Screen Translation")
            )
        case .cancel, .save, .copy:
            // Visibility-only preferences. ToolbarLayout builds these buttons
            // because Save needs the current destination in its tooltip.
            return nil
        case .share:
            return ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: L("Share"))
        case .effects:
            var button = ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Adjust"))
            if effectsActive {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        }
    }
}

enum ToolbarActionPreferences {
    static let enabledDefaultsKey = "enabledActions"
    static let knownDefaultsKey = "knownActionTags"

    static var allKnownRawValues: [Int] {
        ToolbarCustomAction.allKnownActions.map(\.rawValue)
    }

    static var defaultEnabledRawValues: [Int] {
        allKnownRawValues
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        var enabledActions = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newTags = allKnownRawValues.filter { !(knownActionTags ?? []).contains($0) }

        if !newTags.isEmpty {
            if enabledActions == nil {
                enabledActions = allKnownRawValues
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
            } else {
                enabledActions = enabledActions! + newTags
            }
            UserDefaults.standard.set(enabledActions, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownRawValues, forKey: knownDefaultsKey)
        }

        return enabledActions
    }

    static func isEnabled(_ action: ToolbarCustomAction, in enabledActions: [Int]?) -> Bool {
        enabledActions == nil || enabledActions!.contains(action.rawValue)
    }
}

enum ToolbarPrimaryTrailingAction {
    case pin
    case confirm
}

class ToolbarLayout {

    // Fresh installs start with the approved Graphite Blue light triplet.
    static let defaultAccentColor = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
    static let defaultIconColor = NSColor(srgbRed: 0x1F / 255, green: 0x29 / 255, blue: 0x37 / 255, alpha: 1)
    static let defaultBgColor = NSColor(srgbRed: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255, alpha: 1)

    // User-customizable colors — read from UserDefaults with the Plus palette as fallback.
    static var accentColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarAccentColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultAccentColor
    }
    static var iconColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarIconColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultIconColor
    }
    static var bgColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultBgColor
    }
    static var handleColor: NSColor { accentColor }
    static let cornerRadius: CGFloat = 6

    static func pinOnlyActionButtons() -> [ToolbarButton] {
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        guard ToolbarActionPreferences.isEnabled(.selectText, in: enabledActions),
              let button = ToolbarCustomAction.selectText.makeToolbarButton()
        else { return [] }
        return [button]
    }

    static func selectableOCRButtons() -> [ToolbarButton] {
        let buttons: [(DedicatedToolbarTool, ToolbarButton)] = [
            (.recognizeText, ToolbarButton(action: .recognizeSelectableText, sfSymbol: "text.viewfinder", tooltip: L("Recognize Text"), shortcutAction: .recognizeText)),
            (.copyText, ToolbarButton(action: .copyRecognizedText, sfSymbol: "doc.on.doc", tooltip: L("Copy Text"), shortcutAction: .copyRecognizedText)),
            (.pin, ToolbarButton(action: .pinSelectableText, sfSymbol: "pin.fill", tooltip: L("Pin"), shortcutAction: .pin)),
        ]
        return buttons.compactMap { tool, button in
            DedicatedToolPreferences.isVisible(tool, in: .ocrSelection) ? button : nil
        }
    }

    static func screenTranslationButtons(
        displayMode: ScreenTranslationSession.DisplayMode,
        sourceLanguage: String?,
        targetLanguage: String?,
        comparisonEnabled: Bool
    ) -> [ToolbarButton] {
        let languagePair = [sourceLanguage, targetLanguage]
            .compactMap { code in
                guard let code else { return nil }
                return TranslationService.availableLanguages.first(where: { $0.code == code })
                    .map { L($0.name) } ?? code
            }
            .joined(separator: " → ")
        let buttons: [(DedicatedToolbarTool, ToolbarButton)] = [
            (.language, ToolbarButton(
                action: .translationPinLanguage,
                sfSymbol: "character.book.closed",
                tooltip: languagePair.isEmpty ? L("Language") : languagePair,
                shortcutAction: .translationLanguage)),
            (.compare, ToolbarButton(
                action: .screenTranslationCompare,
                sfSymbol: "rectangle.on.rectangle",
                tooltip: L("Compare"),
                isSelected: comparisonEnabled,
                shortcutAction: .translationCompare)),
            (.toggleOriginalTranslation, ToolbarButton(
                action: .translationPinToggle,
                sfSymbol: displayMode == .translated ? "character.book.closed.fill" : "photo",
                tooltip: displayMode == .translated ? L("Show Original") : L("Show Translation"),
                isSelected: displayMode == .translated && !comparisonEnabled,
                shortcutAction: .translationToggle)),
            (.copyOriginal, ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy Original"), shortcutAction: .copyOriginalText)),
            (.copyTranslation, ToolbarButton(action: .copyText, sfSymbol: "character.book.closed", tooltip: L("Copy Translation"), shortcutAction: .copyTranslatedText)),
            (.pin, ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin"), shortcutAction: .pin)),
            (.cancel, ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel"))),
        ]
        return buttons.compactMap { tool, button in
            DedicatedToolPreferences.isVisible(tool, in: .screenTranslation) ? button : nil
        }
    }

    /// Save accent color to UserDefaults.
    static func saveAccentColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarAccentColor")
        }
    }

    /// Save icon color to UserDefaults.
    static func saveIconColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarIconColor")
        }
    }

    /// Appearance matching the toolbar background brightness.
    /// Dark background → `.darkAqua`, light background → `.aqua`.
    static var appearance: NSAppearance? {
        let color = bgColor.usingColorSpace(.deviceRGB) ?? bgColor
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return NSAppearance(named: brightness > 0.5 ? .aqua : .darkAqua)
    }

    /// Save background color to UserDefaults.
    static func saveBgColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarBgColor")
        }
    }

    /// Reset all colors to defaults.
    static func resetColors() {
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
        UserDefaults.standard.removeObject(forKey: "toolbarBgColor")
    }

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false,
        beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false,
        effectsActive: Bool = false, canUndo: Bool = true, canRedo: Bool = true
    ) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        let enabledRawValues = ToolbarToolPreferences.enabledRawValuesAfterMigration()

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "scribble", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "rectangle", L("Rectangle")),
            (.ellipse, "oval", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "1.circle.fill", L("Number")),
            (.pixelate, "_custom.checkerboard", L("Censor")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "magnifyingglass", L("Magnify (Loupe)")),
            (.stamp, "face.smiling", L("Stamp / Emoji")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
        ]

        for (tool, symbol, tip) in tools {
            // Skip if disabled
            if !ToolbarToolPreferences.isToolEnabled(tool, in: enabledRawValues) {
                continue
            }
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe:
                break  // options shown in the tool options row, not via right-click
            default:
                break
            }
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo"), isEnabled: canUndo))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo"), isEnabled: canRedo))

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        for action in ToolbarCustomAction.bottomToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                beautifyEnabled: beautifyEnabled,
                effectsActive: effectsActive,
                isRecording: isRecording
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }

    static func annotationToolbarButton(
        for tool: AnnotationTool,
        selectedTool: AnnotationTool
    ) -> ToolbarButton? {
        let data: (String, String)?
        switch tool {
        case .pencil: data = ("scribble", L("Pencil (Draw)"))
        case .line: data = ("line.diagonal", L("Line"))
        case .arrow: data = ("arrow.up.right", L("Arrow"))
        case .rectangle: data = ("rectangle", L("Rectangle"))
        case .filledRectangle: data = ("rectangle.fill", L("Filled Rectangle"))
        case .ellipse: data = ("oval", L("Ellipse"))
        case .marker:
            data = ({
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker"))
        case .text: data = ("t.square", L("Text"))
        case .number: data = ("1.circle.fill", L("Number"))
        case .stamp: data = ("face.smiling", L("Stamp / Emoji"))
        case .pixelate: data = ("_custom.checkerboard", L("Censor"))
        case .blur: data = ("drop", L("Blur"))
        case .measure: data = ("ruler", L("Measure (px)"))
        case .loupe: data = ("magnifyingglass", L("Magnify (Loupe)"))
        case .highlight: data = ("sun.max", L("Highlight (Spotlight)"))
        case .eraser: data = ("eraser", L("Eraser"))
        case .colorSampler: data = ("eyedropper", L("Color Picker"))
        case .select, .translateOverlay, .crop:
            data = nil
        }
        guard let (symbol, tooltip) = data else { return nil }
        var button = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tooltip)
        button.isSelected = tool == selectedTool
        return button
    }

    static func primaryOverlayButtons(
        selectedTool: AnnotationTool,
        selectedColor: NSColor,
        moreExpanded: Bool,
        hasMoreTools: Bool = true,
        trailingAction: ToolbarPrimaryTrailingAction = .pin,
        canUndo: Bool = true,
        canRedo: Bool = true,
        isRecording: Bool = false,
        includeOrdinarySelectionActions: Bool = false
    ) -> [ToolbarButton] {
        if isRecording { return [] }
        let enabledRawValues = ToolbarToolPreferences.enabledRawValuesAfterMigration()
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        var buttons = ordinaryToolbarButtons(
            inPrimary: true,
            selectedTool: selectedTool,
            enabledTools: enabledRawValues,
            enabledActions: enabledActions,
            includeSpecialActions: includeOrdinarySelectionActions
        )

        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)
        buttons.append(ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo"), isEnabled: canUndo))
        buttons.append(ToolbarButton(action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo"), isEnabled: canRedo))
        if hasMoreTools {
            var more = ToolbarButton(action: .moreTools, sfSymbol: "ellipsis", tooltip: L("More Tools"))
            more.isSelected = moreExpanded
            buttons.append(more)
        }
        buttons.append(ToolbarButton(action: .separator, sfSymbol: nil, tooltip: "", isSeparator: true))
        if ToolbarActionPreferences.isEnabled(.cancel, in: enabledActions) {
            buttons.append(ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
        }

        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        if ToolbarActionPreferences.isEnabled(.save, in: enabledActions) {
            var saveBtn = ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down.fill", tooltip: saveTooltip)
            saveBtn.hasContextMenu = true
            buttons.append(saveBtn)
        }
        if ToolbarActionPreferences.isEnabled(.copy, in: enabledActions) {
            buttons.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        }
        switch trailingAction {
        case .pin:
            buttons.append(ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin")))
        case .confirm:
            var confirm = ToolbarButton(action: .confirmAnnotation, sfSymbol: "checkmark", tooltip: L("Done"))
            confirm.tintColor = .systemGreen
            buttons.append(confirm)
        }
        return buttons
    }

    static func secondaryOverlayButtons(
        selectedTool: AnnotationTool,
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        includeExtraActions: Bool = true,
        includeImageTransformActions: Bool = false,
        includePinShadowAction: Bool = false,
        includeOrdinarySelectionActions: Bool = false
    ) -> [ToolbarButton] {
        let enabledRawValues = ToolbarToolPreferences.enabledRawValuesAfterMigration()
        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        var buttons = ordinaryToolbarButtons(
            inPrimary: false,
            selectedTool: selectedTool,
            enabledTools: enabledRawValues,
            enabledActions: enabledActions,
            includeSpecialActions: includeOrdinarySelectionActions
        )

        if includeImageTransformActions {
            for action in [ToolbarCustomAction.flipHorizontal, .flipVertical, .rotateClockwise] {
                guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
                if let button = action.makeToolbarButton(
                    beautifyEnabled: beautifyEnabled,
                    translateEnabled: translateEnabled,
                    effectsActive: effectsActive,
                    isEditorMode: false
                ) {
                    buttons.append(button)
                }
            }
        }

        if includePinShadowAction {
            if ToolbarActionPreferences.isEnabled(.pinShadow, in: enabledActions),
               let button = ToolbarCustomAction.pinShadow.makeToolbarButton(
                    beautifyEnabled: beautifyEnabled,
                    translateEnabled: translateEnabled,
                    effectsActive: effectsActive,
                    isEditorMode: false
               ) {
                buttons.append(button)
            }
        }

        if includeExtraActions {
            var secondaryActions: [ToolbarCustomAction] = [
                .invertColors, .effects, .beautify, .removeBackground, .share,
            ]
            #if !OFFLINE
            secondaryActions.append(.upload)
            #endif
            secondaryActions.append(contentsOf: [.ocr, .translate, .scrollCapture, .record])
            for action in secondaryActions {
                guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
                if let button = action.makeToolbarButton(
                    beautifyEnabled: beautifyEnabled,
                    translateEnabled: translateEnabled,
                    effectsActive: effectsActive,
                    isEditorMode: false
                ) {
                    buttons.append(button)
                }
            }
        }
        return buttons
    }

    private static func ordinaryToolbarButtons(
        inPrimary: Bool,
        selectedTool: AnnotationTool,
        enabledTools: [Int]?,
        enabledActions: [Int]?,
        includeSpecialActions: Bool
    ) -> [ToolbarButton] {
        PinToolbarLayoutPreferences.items(inPrimary: inPrimary).compactMap { item in
            switch item {
            case .tool(let tool):
                guard ToolbarToolPreferences.isToolEnabled(tool, in: enabledTools) else { return nil }
                return annotationToolbarButton(for: tool, selectedTool: selectedTool)
            case .selectText:
                guard includeSpecialActions,
                      ToolbarActionPreferences.isEnabled(.selectText, in: enabledActions)
                else { return nil }
                return ToolbarCustomAction.selectText.makeToolbarButton()
            case .screenTranslation:
                guard includeSpecialActions,
                      ToolbarActionPreferences.isEnabled(.screenTranslation, in: enabledActions)
                else { return nil }
                return ToolbarCustomAction.screenTranslation.makeToolbarButton()
            case .pinShadow:
                return nil
            }
        }
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(
        beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false,
        translateEnabled: Bool = false, isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // Recording setup mode — show start button + toggles, then return early
        if isRecording {
            var startBtn = ToolbarButton(
                action: .startRecord, sfSymbol: "record.circle", tooltip: L("Start Recording"))
            startBtn.tintColor = .systemRed
            buttons.append(startBtn)

            // Stop/cancel button to exit recording mode without starting
            buttons.append(
                ToolbarButton(action: .stopRecord, sfSymbol: "xmark", tooltip: L("Cancel Recording")))

            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = ToolbarButton(
                action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", tooltip: L("Highlight Mouse Clicks"))
            mouseBtn.isSelected = mouseHighlightOn
            buttons.append(mouseBtn)

            let keystrokesOn = UserDefaults.standard.bool(forKey: "recordKeystroke")
            var keystrokeBtn = ToolbarButton(
                action: .showKeystrokes, sfSymbol: "keyboard", tooltip: L("Show Keystrokes"))
            keystrokeBtn.isSelected = keystrokesOn
            keystrokeBtn.hasContextMenu = true
            buttons.append(keystrokeBtn)

            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            var audioBtn = ToolbarButton(
                action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
                tooltip: L("Record System Audio"))
            audioBtn.isSelected = audioOn
            buttons.append(audioBtn)

            let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
            var micBtn = ToolbarButton(
                action: .micAudio, sfSymbol: micOn ? "mic.fill" : "mic.slash", tooltip: L("Record Microphone"))
            micBtn.isSelected = micOn
            micBtn.hasContextMenu = true
            buttons.append(micBtn)

            let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")
            let webcamSymbol: String = {
                if #available(macOS 14.0, *) {
                    return webcamOn ? "web.camera.fill" : "web.camera"
                }
                return webcamOn ? "camera.fill" : "camera"
            }()
            var webcamBtn = ToolbarButton(
                action: .webcam, sfSymbol: webcamSymbol, tooltip: L("Webcam Overlay"))
            webcamBtn.isSelected = webcamOn
            webcamBtn.hasContextMenu = true
            buttons.append(webcamBtn)

            // Recording settings gear
            buttons.append(
                ToolbarButton(
                    action: .recordSettings, sfSymbol: "gearshape",
                    tooltip: L("Recording Settings")))

            // Allow moving the selection before starting
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))

            return buttons
        }

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()

        // Cancel and move-selection — not shown in editor window.
        if !isEditorMode {
            if ToolbarActionPreferences.isEnabled(.cancel, in: enabledActions) {
                buttons.append(
                    ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
            }
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))
        }
        // Copy and save follow the same visibility preferences as the bottom toolbar.
        if ToolbarActionPreferences.isEnabled(.copy, in: enabledActions) {
            buttons.append(
                ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        }
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        if ToolbarActionPreferences.isEnabled(.save, in: enabledActions) {
            var saveBtn = ToolbarButton(
                action: .save, sfSymbol: "square.and.arrow.down.fill",
                tooltip: saveTooltip
            )
            saveBtn.hasContextMenu = true
            buttons.append(saveBtn)
        }

        for action in ToolbarCustomAction.rightToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                translateEnabled: translateEnabled,
                isRecording: isRecording,
                isEditorMode: isEditorMode
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }
}
