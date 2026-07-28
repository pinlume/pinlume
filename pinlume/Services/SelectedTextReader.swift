import AppKit
import ApplicationServices

struct TranslationInputSources {
    let selectedText: String?
    let clipboardText: String?
    let lastSessionText: String?
}

enum TranslationInputResolver {
    static func resolve(_ sources: TranslationInputSources) -> String {
        [sources.selectedText, sources.clipboardText, sources.lastSessionText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// Device-local preference: profiles must not overwrite an Accessibility
/// decision that belongs to this Mac and its current code-signing identity.
enum SelectedTextTranslationPreference {
    static let enabledKey = "selectedTextTranslationEnabled"
    private static let initialPermissionRequestKey = "selectedTextTranslationInitialPermissionRequested"

    static var wantsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isEnabled: Bool {
        wantsEnabled && SelectedTextReader.hasAccessibilityPermission
    }

    static func requestInitialAccessibilityPermissionIfNeeded() {
        guard wantsEnabled,
              !UserDefaults.standard.bool(forKey: initialPermissionRequestKey),
              !SelectedTextReader.hasAccessibilityPermission
        else { return }
        UserDefaults.standard.set(true, forKey: initialPermissionRequestKey)
        SelectedTextReader.requestAccessibilityPermission()
    }
}

enum SelectedTextReader {
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func readSelectedText() -> String? {
        guard hasAccessibilityPermission else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = elementValue(kAXFocusedUIElementAttribute, from: systemWide),
           let text = selectedText(startingAt: focused) {
            return text
        }
        guard let application = elementValue(kAXFocusedApplicationAttribute, from: systemWide) else { return nil }
        if let focused = elementValue(kAXFocusedUIElementAttribute, from: application),
           let text = selectedText(startingAt: focused) {
            return text
        }
        if let window = elementValue(kAXFocusedWindowAttribute, from: application) {
            return selectedText(startingAt: window)
        }
        return nil
    }

    static func readSelectedText(fromPID processIdentifier: pid_t) -> String? {
        guard hasAccessibilityPermission else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = elementValue(kAXFocusedUIElementAttribute, from: systemWide),
           belongs(focused, toPID: processIdentifier),
           let text = selectedText(startingAt: focused) {
            return text
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        if let focused = elementValue(kAXFocusedUIElementAttribute, from: application),
           let text = selectedText(startingAt: focused) {
            return text
        }
        if let window = elementValue(kAXFocusedWindowAttribute, from: application),
           let text = selectedText(startingAt: window) {
            return text
        }
        if let text = selectedText(startingAt: application) { return text }
        return copiedSelectionOrCaretLine(fromPID: processIdentifier)
    }

    private static func belongs(_ element: AXUIElement, toPID expectedPID: pid_t) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == expectedPID
    }

    private static func elementValue(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedText(startingAt element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<24 {
            guard let currentElement = current else { return nil }
            if let text = directSelectedText(in: currentElement)
                ?? markerSelectedText(in: currentElement)
                ?? rangeSelectedText(in: currentElement)
                ?? caretLineText(in: currentElement) {
                return text
            }
            current = elementValue(kAXParentAttribute, from: currentElement)
        }
        return nil
    }

    private static func directSelectedText(in focused: AXUIElement) -> String? {
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
            let text = selectedValue as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rangeSelectedText(in focused: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue) == .success,
            let rangeValue
        else { return nil }

        return string(forRangeValue: rangeValue, in: focused)
    }

    private static func markerSelectedText(in focused: AXUIElement) -> String? {
        let markerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        let stringForMarkerRange = "AXStringForTextMarkerRange" as CFString
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, markerRangeAttribute, &markerRange) == .success,
            let markerRange
        else { return nil }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            stringForMarkerRange,
            markerRange,
            &stringValue) == .success,
            let text = stringValue as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func caretLineText(in focused: AXUIElement) -> String? {
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue) == .success,
            let selectedRangeValue,
            CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
        else { return nil }

        var selectedRange = CFRange()
        guard AXValueGetValue(
            selectedRangeValue as! AXValue,
            .cfRange,
            &selectedRange),
            selectedRange.length == 0
        else { return nil }

        var lineValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: selectedRange.location),
            &lineValue) == .success,
            let lineNumber = lineValue as? NSNumber
        else { return nil }

        var lineRangeValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXRangeForLineParameterizedAttribute as CFString,
            lineNumber,
            &lineRangeValue) == .success,
            let lineRangeValue
        else { return nil }
        return string(forRangeValue: lineRangeValue, in: focused)
    }

    private static func string(forRangeValue rangeValue: CFTypeRef, in element: AXUIElement) -> String? {
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue) == .success,
            let text = stringValue as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func copiedSelectionOrCaretLine(fromPID pid: pid_t) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let copySentinel = "pinlume-copy-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(copySentinel, forType: .string)
        let baseline = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            restorePasteboard(snapshot, to: pasteboard)
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        let deadline = Date().addingTimeInterval(0.60)
        var copiedText: String?
        var copiedChangeCount: Int?
        var observedCopyChangeCount: Int?
        var copyGenerationAmbiguous = false
        var stableSince: Date?
        while Date() < deadline {
            let currentCount = pasteboard.changeCount
            let currentText = pasteboard.string(forType: .string)
            if currentCount != baseline {
                if let observedCopyChangeCount,
                   observedCopyChangeCount != currentCount {
                    copyGenerationAmbiguous = true
                } else if observedCopyChangeCount == nil {
                    observedCopyChangeCount = currentCount
                }
            }
            if currentCount != baseline, let currentText, currentText != copySentinel {
                if copiedChangeCount == currentCount, copiedText == currentText {
                    stableSince = stableSince ?? Date()
                    if Date().timeIntervalSince(stableSince!) >= 0.04 { break }
                } else {
                    copiedText = currentText
                    copiedChangeCount = currentCount
                    stableSince = Date()
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        // Restore only while the pasteboard still contains this copy
        // transaction. If another writer has changed it, preserving that new
        // value is safer than overwriting it with our snapshot.
        if !copyGenerationAmbiguous,
           let copiedChangeCount, let copiedText,
           pasteboard.changeCount == copiedChangeCount,
           pasteboard.string(forType: .string) == copiedText {
            restorePasteboard(snapshot, to: pasteboard)
        } else if !copyGenerationAmbiguous,
                  let observedCopyChangeCount,
                  pasteboard.changeCount == observedCopyChangeCount {
            // A target can copy files, images or a custom pasteboard type even
            // though this reader only accepts text. Restore the user's full
            // snapshot independently from whether a string was produced.
            restorePasteboard(snapshot, to: pasteboard)
        } else if pasteboard.changeCount == baseline,
                  pasteboard.string(forType: .string) == copySentinel {
            restorePasteboard(snapshot, to: pasteboard)
        }

        guard !copyGenerationAmbiguous, let text = copiedText else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let restoredItems = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}
