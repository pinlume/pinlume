import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ToolbarShortcutRoutingContractTests {
    static func main() throws {
        let shortcuts = try source("pinlume/Services/ToolShortcutManager.swift")
        let profile = try source("pinlume/Model/SettingsProfile.swift")
        let toolbar = try source("pinlume/UI/Toolbar/ToolbarDefinitions.swift")
        let strip = try source("pinlume/UI/Toolbar/ToolbarStripView.swift")
        let overlay = try source("pinlume/UI/Overlay/OverlayView.swift")
        let overlayController = try source("pinlume/UI/Overlay/OverlayWindowController.swift")
        let transparentCanvas = try source("pinlume/UI/Windows/TransparentAnnotationCanvasView.swift")
        let transparentSession = try source("pinlume/UI/Windows/TransparentAnnotationSessionController.swift")
        let pin = try source("pinlume/UI/Windows/PinWindowController.swift")
        let english = try source("pinlume/en.lproj/Localizable.strings")
        let simplifiedChinese = try source("pinlume/zh-Hans.lproj/Localizable.strings")

        for action in [
            "recognizeText", "copyRecognizedText", "translationLanguage",
            "translationCompare", "translationToggle", "copyOriginalText", "copyTranslatedText",
        ] {
            expect(shortcuts.contains("case \(action)"), "\(action) has a configurable shortcut action")
            expect(profile.contains("\"\(action)\": \"\""), "\(action) defaults to None")
        }
        expect(!shortcuts.contains("case moveSelection"), "selection-follow shortcut is removed")
        expect(!shortcuts.contains("case openInEditor"), "legacy E shortcut is removed")
        expect(!profile.contains("\"moveSelection\":"), "profiles no longer default Space to move-selection")
        expect(!profile.contains("\"openInEditor\":"), "profiles no longer default E to Pin")
        expect(profile.contains("\"pin\": \"f\""), "F remains the one default Pin shortcut")
        expect(english.contains("\"Toggle Original / Translation\"")
                   && simplifiedChinese.contains("\"Toggle Original / Translation\""),
               "new shortcut labels are localized in English and Simplified Chinese")

        expect(toolbar.contains("var shortcutAction: ToolShortcutManager.Action?"),
               "toolbar buttons can declare their precise shortcut owner")
        expect(toolbar.contains("shortcutAction: .copyOriginalText")
                   && toolbar.contains("shortcutAction: .copyTranslatedText"),
               "translation copy buttons keep distinct shortcut identities")
        expect(shortcuts.contains("static func tooltipText(")
                   && shortcuts.contains("case .cancel, .stopRecord")
                   && shortcuts.contains("(Esc)"),
               "one tooltip formatter always exposes Escape for every cancel action")
        expect(strip.contains("private func nativeTooltip") && strip.contains("ToolShortcutManager.tooltipText("),
               "ordinary native toolbar tooltips use the shared shortcut formatter")
        expect(!toolbar.contains("Censor (Pixelate / Blur / Solid)"),
               "the Censor tooltip only names Censor before its shortcut suffix")

        guard let transparentToolbarStart = transparentSession.range(of: "private func rebuildToolbar()") else {
            fputs("FAIL: transparent toolbar builder is missing\n", stderr)
            exit(1)
        }
        let transparentToolbar = transparentSession[transparentToolbarStart.lowerBound...]
        guard let transparentPin = transparentToolbar.range(of: "ToolbarButton(action: .pin"),
              let transparentCancel = transparentToolbar.range(of: "ToolbarButton(action: .cancel")
        else {
            fputs("FAIL: transparent Pin/Cancel actions are missing\n", stderr)
            exit(1)
        }
        expect(transparentCancel.lowerBound < transparentPin.lowerBound,
               "transparent annotation orders Cancel before Pin like the ordinary capture toolbar")

        expect(transparentCanvas.contains("var onToolbarShortcut")
                   && transparentSession.contains("handleToolbarShortcut"),
               "transparent sessions route shortcuts through their owning toolbar controller")
        expect(pin.contains("onToolbarShortcut")
                   && pin.contains("handlePinToolbarShortcut"),
               "both Pin panels route shortcuts through the Pin toolbar controller")
        expect(pin.contains("pinToolbarSecondaryButtons") && pin.contains("Dedicated OCR and"),
               "normal Pins keep configured More-tools shortcuts while dedicated Pins stay button-gated")
        expect(pin.contains("toolbarPanel?.isVisible == true && displayed"),
               "dedicated Pin shortcuts stop when their compact toolbar is hidden")
        expect(overlay.contains("handleSelectableOCRToolbarShortcut")
                   && overlay.contains("handleScreenTranslationToolbarShortcut"),
               "OCR and translation shortcut paths dispatch their existing toolbar actions")
        expect(overlay.contains("func handleDedicatedToolbarShortcut(_ event: NSEvent) -> Bool"),
               "dedicated workflow shortcuts have one responder-independent entry point")
        expect(overlayController.contains("onDedicatedToolbarShortcut")
                   && overlayController.contains("override func sendEvent(_ event: NSEvent)"),
               "the overlay window forwards dedicated shortcuts before a text selection view can consume them")
        expect(overlay.contains("visibleToolbarContains(toolbarAction)"),
               "dedicated shortcuts require their current button to be visible")
        expect(overlay.contains("case .recognizeSelectableText:")
                   && overlay.contains("guard selectableOCRSession.phase == .active"),
               "recognize may reuse its visible button while copy and Pin remain completion-gated")
        expect(!overlay.contains("isKeyboardMoveSelectionActive"),
               "finished-selection keyboard move state is removed")

        print("toolbar shortcut routing contract tests passed")
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}
