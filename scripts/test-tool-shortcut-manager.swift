import Cocoa

enum AnnotationTool: Equatable { case pencil, arrow, line, rectangle, ellipse, marker, text, number, pixelate, highlight, colorSampler, stamp, measure, loupe, eraser }
enum ToolbarButtonAction: Equatable {
    case tool(AnnotationTool), pin, upload, copy, copyText, save, ocr, scrollCapture, beautify, invertColors, removeBackground, translate, undo, redo, loupe, cancel, stopRecord
    case recognizeSelectableText, copyRecognizedText, pinSelectableText
    case translationPinLanguage, screenTranslationCompare, translationPinToggle
}
enum SettingsProfileToolShortcutDefinitions {
    static func defaultKey(for actionID: String) -> String {
        ["pencil": "p", "arrow": "a", "line": "l", "rectangle": "r", "pin": "f"][actionID] ?? ""
    }
}
func L(_ value: String) -> String { value }

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct ToolShortcutManagerTest {
    static func main() {
        let defaults = UserDefaults.standard
        let key = "overlayToolShortcuts"
        let old = defaults.object(forKey: key)
        defer {
            if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set([
            ToolShortcutManager.Action.pencil.rawValue: "x",
            ToolShortcutManager.Action.arrow.rawValue: "x",
            ToolShortcutManager.Action.line.rawValue: ""
        ], forKey: key)
        expect(ToolShortcutManager.action(for: "x") == .pencil, "tool shortcut conflicts use Action.allCases order")
        expect(ToolShortcutManager.action(for: "") == nil, "None does not become a shortcut")
        expect(ToolShortcutManager.key(for: .pin) == "f", "F remains the default Pin shortcut")
        expect(ToolShortcutManager.key(for: .recognizeText).isEmpty,
               "recognize-text starts disabled")
        expect(ToolShortcutManager.key(for: .copyRecognizedText).isEmpty,
               "copy-text starts disabled")
        expect(ToolShortcutManager.key(for: .translationLanguage).isEmpty
                   && ToolShortcutManager.key(for: .translationCompare).isEmpty
                   && ToolShortcutManager.key(for: .translationToggle).isEmpty
                   && ToolShortcutManager.key(for: .copyOriginalText).isEmpty
                   && ToolShortcutManager.key(for: .copyTranslatedText).isEmpty,
               "translation-specific actions start disabled")
        expect(ToolShortcutManager.selectableOCRToolbarAction(for: .recognizeText) == .recognizeSelectableText,
               "OCR recognize shortcut maps to its dedicated toolbar button")
        expect(ToolShortcutManager.selectableOCRToolbarAction(for: .copyRecognizedText) == .copyRecognizedText,
               "OCR copy shortcut maps to its dedicated toolbar button")
        expect(ToolShortcutManager.screenTranslationToolbarAction(for: .copyOriginalText) == .copy,
               "original-copy shortcut keeps the distinct original button identity")
        expect(ToolShortcutManager.screenTranslationToolbarAction(for: .copyTranslatedText) == .copyText,
               "translated-copy shortcut keeps the distinct translation button identity")
        expect(ToolShortcutManager.tooltipText(
            base: "Cancel", toolbarAction: .cancel, shortcutOwner: nil, showConfiguredShortcut: false
        ) == "Cancel (Esc)", "Cancel always displays Escape even when shortcut hints are off")
        expect(ToolShortcutManager.tooltipText(
            base: "Cancel Recording", toolbarAction: .stopRecord, shortcutOwner: nil, showConfiguredShortcut: false
        ) == "Cancel Recording (Esc)", "recording cancel always displays Escape even when shortcut hints are off")
        ToolShortcutManager.setKey("y", for: .pencil)
        expect(ToolShortcutManager.action(for: "x") == .arrow, "cache rebuild keeps the next declaration-order conflict winner")
        expect(ToolShortcutManager.action(for: "y") == .pencil, "setKey invalidates the reverse lookup cache")
        print("tool shortcut manager tests passed")
    }
}
