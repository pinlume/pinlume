import Foundation

enum DedicatedToolbarContext: String, CaseIterable {
    case ocrSelection
    case ocrPin
    case screenTranslation
    case translationPin

    var settingsTitle: String {
        switch self {
        case .ocrSelection: return "OCR Selection"
        case .ocrPin: return "OCR Pin"
        case .screenTranslation: return "Screen Translation"
        case .translationPin: return "Translation Pin"
        }
    }
}

enum DedicatedToolbarTool: String {
    case recognizeText
    case selectText
    case copyText
    case language
    case compare
    case toggleOriginalTranslation
    case copyOriginal
    case copyTranslation
    case pin
    case cancel

    var settingsLabel: String {
        switch self {
        case .recognizeText: return "Recognize Text"
        case .selectText: return "Select Text"
        case .copyText: return "Copy Text"
        case .language: return "Language"
        case .compare: return "Compare"
        case .toggleOriginalTranslation: return "Show Original / Translation"
        case .copyOriginal: return "Copy Original"
        case .copyTranslation: return "Copy Translation"
        case .pin: return "Pin"
        case .cancel: return "Cancel"
        }
    }
}

enum DedicatedToolPreferences {
    static func tools(in context: DedicatedToolbarContext) -> [DedicatedToolbarTool] {
        switch context {
        case .ocrSelection:
            return [.recognizeText, .copyText, .pin]
        case .ocrPin:
            return [.selectText, .copyText]
        case .screenTranslation:
            return [.language, .compare, .toggleOriginalTranslation, .copyOriginal, .copyTranslation, .pin, .cancel]
        case .translationPin:
            return [.language, .toggleOriginalTranslation, .copyOriginal, .copyTranslation, .selectText]
        }
    }

    static func isVisible(
        _ tool: DedicatedToolbarTool,
        in context: DedicatedToolbarContext,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = defaultsKey(tool: tool, context: context)
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setVisible(
        _ visible: Bool,
        tool: DedicatedToolbarTool,
        in context: DedicatedToolbarContext,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(visible, forKey: defaultsKey(tool: tool, context: context))
    }

    private static func defaultsKey(
        tool: DedicatedToolbarTool,
        context: DedicatedToolbarContext
    ) -> String {
        "dedicatedToolbar.\(context.rawValue).\(tool.rawValue).visible"
    }
}
