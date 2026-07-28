import Cocoa

/// Manages single-key overlay/editor tool shortcuts.
/// Stored in UserDefaults as a dictionary of action ID → key character.
/// An empty string means the shortcut is disabled (None).
enum ToolShortcutManager {

    /// All configurable overlay shortcut actions with their default keys.
    enum Action: String, CaseIterable {
        case pencil
        case arrow
        case line
        case rectangle
        case ellipse
        case marker
        case text
        case number
        case censor       // pixelate/blur tool
        case highlight    // spotlight tool
        case colorSampler
        case stamp
        case measure
        case loupe
        case moveSelection
        case openInEditor
        case pin
        #if !OFFLINE
        case upload
        #endif
        case copy
        case save
        case ocr
        case scrollCapture
        case beautify
        case invertColors
        case removeBackground
        case translate
        case undo
        case redo
        case eraser

        var label: String {
            switch self {
            case .pencil: return L("Pencil")
            case .arrow: return L("Arrow")
            case .line: return L("Line")
            case .rectangle: return L("Rectangle")
            case .ellipse: return L("Ellipse")
            case .marker: return L("Marker")
            case .text: return L("Text")
            case .number: return L("Number")
            case .censor: return L("Censor")
            case .highlight: return L("Highlight")
            case .colorSampler: return L("Color Picker")
            case .stamp: return L("Stamp")
            case .measure: return L("Measure")
            case .loupe: return L("Loupe")
            case .moveSelection: return L("Move Selection")
            // Legacy storage name; this shortcut now follows the unified
            // static-image output path and pins the selection instead.
            case .openInEditor: return L("Pin to Screen")
            case .pin: return L("Pin")
            #if !OFFLINE
            case .upload: return L("Upload")
            #endif
            case .copy: return L("Copy")
            case .save: return L("Save")
            case .ocr: return L("OCR & QR")
            case .scrollCapture: return L("Scroll Capture")
            case .beautify: return L("Beautify")
            case .invertColors: return L("Invert Colors")
            case .removeBackground: return L("Remove Background")
            case .translate: return L("Translate")
            case .undo: return L("Undo")
            case .redo: return L("Redo")
            case .eraser: return L("Eraser")
            }
        }

        var defaultKey: String {
            SettingsProfileToolShortcutDefinitions.defaultKey(for: rawValue)
        }
    }

    private static let defaultsKey = "overlayToolShortcuts"
    private static var reverseLookupCache: [String: Action]?

    /// Get the key character for an action. Empty string = disabled.
    static func key(for action: Action) -> String {
        if let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
           let key = dict[action.rawValue] {
            return key
        }
        return action.defaultKey
    }

    /// Set the key character for an action. Pass empty string to disable.
    static func setKey(_ key: String, for action: Action) {
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        dict[action.rawValue] = key
        UserDefaults.standard.set(dict, forKey: defaultsKey)
        reverseLookupCache = nil
    }

    /// Remove all per-action overrides so every tool reads its shared default.
    static func resetAllToDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        reverseLookupCache = nil
    }

    /// Build a reverse lookup: character → ToolbarButtonAction.
    static func lookupAction(for character: String) -> ToolbarButtonAction? {
        guard let action = action(for: character) else { return nil }
        return toolbarAction(for: action)
    }

    /// Resolve conflicts in declaration order. Empty keys are intentionally
    /// skipped so None remains a valid way to disable an action.
    static func action(for character: String) -> Action? {
        reverseLookup()[character]
    }

    private static func reverseLookup() -> [String: Action] {
        if let reverseLookupCache { return reverseLookupCache }
        var lookup: [String: Action] = [:]
        for action in Action.allCases {
            let key = key(for: action)
            guard !key.isEmpty, lookup[key] == nil else { continue }
            lookup[key] = action
        }
        reverseLookupCache = lookup
        return lookup
    }

    private static func toolbarAction(for action: Action) -> ToolbarButtonAction? {
        switch action {
        case .pencil: return .tool(.pencil)
        case .arrow: return .tool(.arrow)
        case .line: return .tool(.line)
        case .rectangle: return .tool(.rectangle)
        case .ellipse: return .tool(.ellipse)
        case .marker: return .tool(.marker)
        case .text: return .tool(.text)
        case .number: return .tool(.number)
        case .censor: return .tool(.pixelate)
        case .highlight: return .tool(.highlight)
        case .colorSampler: return .tool(.colorSampler)
        case .stamp: return .tool(.stamp)
        case .measure: return .tool(.measure)
        case .loupe: return .tool(.loupe)
        case .moveSelection: return .moveSelection
        case .openInEditor: return .detach
        case .pin: return .pin
        #if !OFFLINE
        case .upload: return .upload
        #endif
        case .copy: return .copy
        case .save: return .save
        case .ocr: return .ocr
        case .scrollCapture: return .scrollCapture
        case .beautify: return .beautify
        case .invertColors: return .invertColors
        case .removeBackground: return .removeBackground
        case .translate: return .translate
        case .undo: return .undo
        case .redo: return .redo
        case .eraser: return .tool(.eraser)
        }
    }

    /// Display string for a key (for UI).
    static func displayString(for action: Action) -> String {
        let k = key(for: action)
        if k == " " { return L("Space") }
        return k.isEmpty ? L("None") : k.uppercased()
    }

    /// Raw configured shortcut text for toolbar tooltip suffixes.
    /// Empty string means no shortcut should be shown.
    static func tooltipShortcut(for toolbarAction: ToolbarButtonAction) -> String? {
        let action: Action?
        switch toolbarAction {
        case .tool(let tool):
            switch tool {
            case .pencil: action = .pencil
            case .arrow: action = .arrow
            case .line: action = .line
            case .rectangle: action = .rectangle
            case .ellipse: action = .ellipse
            case .marker: action = .marker
            case .text: action = .text
            case .number: action = .number
            case .pixelate: action = .censor
            case .highlight: action = .highlight
            case .colorSampler: action = .colorSampler
            case .stamp: action = .stamp
            case .measure: action = .measure
            case .loupe: action = .loupe
            case .eraser: action = .eraser
            default: action = nil
            }
        case .detach: action = .openInEditor
        case .pin: action = .pin
        #if !OFFLINE
        case .upload: action = .upload
        #endif
        case .copy: action = .copy
        case .save: action = .save
        case .ocr: action = .ocr
        case .scrollCapture: action = .scrollCapture
        case .beautify: action = .beautify
        case .invertColors: action = .invertColors
        case .removeBackground: action = .removeBackground
        case .translate: action = .translate
        case .undo: action = .undo
        case .redo: action = .redo
        case .loupe: action = .loupe
        case .moveSelection: action = .moveSelection
        default: action = nil
        }

        guard let action else { return nil }
        let shortcut = key(for: action)
        if shortcut == " " { return displayString(for: action) }
        let trimmed = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
