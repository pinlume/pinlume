import AppKit
import Foundation

enum SettingsProfilePreferenceBridgeError: Error, Equatable {
    case invalidLayoutValue(String)
    case overlappingLayoutItems(String)
    case invalidDedicatedToolKey(String)
    case invalidColor(String)
}

/// Projects the explicit profile schema onto the current UserDefaults-backed
/// runtime preferences. It does not own any preference state: toolbars, pins
/// and the status menu continue to read their existing keys and models.
final class SettingsProfilePreferenceBridge {
    private static let colorKeys: Set<String> = [
        "toolbarAccentColor",
        "toolbarIconColor",
        "toolbarBgColor",
        "loupeOutlineColor",
        "annotationOutlineColor",
        "lastUsedColor",
        "textBgColor",
        "textOutlineColor",
        "textGlyphStrokeColor",
    ]

    private static let defaultToolbarTools = [0, 3, 8, 6, 7, 9, 1, 2, 5, 18, 12, 17, 16, 11, 19]
    private static let defaultToolbarPrimaryTools = [0, 3, 8, 6, 7, 9]
    private static let defaultToolbarSecondaryTools = [1, 2, 5, 18, 12, 17, 16, 11, 19]
    private static let defaultToolbarActions = Array(1_001...1_023)
    private static let defaultStatusPrimaryItems = [
        "captureArea", "captureScreen", "captureOCR", "quickCapture", "pinFromClipboard", "toggleAllPins",
    ]
    private static let defaultStatusMoreItems = [
        "scrollCapture", "captureLastArea", "captureDelay", "selectableOCRCapture", "screenTranslationCapture",
        "translationWindow", "recordArea", "recordScreen", "recentCaptures", "historyOverlay", "openImage",
        "openVideo", "openFromClipboard",
    ]
    private static let defaultStatusItems = defaultStatusPrimaryItems + defaultStatusMoreItems
    private static let defaultPinPrimaryItems = defaultToolbarPrimaryTools.map { "tool:\($0)" }
        + ["selectText", "screenTranslation", "pinShadow"]
    private static let defaultPinSecondaryItems = defaultToolbarSecondaryTools.map { "tool:\($0)" }

    private static let hotkeyBindings = SettingsProfileHotkeyDefinition.all

    private static let dedicatedToolDefaults: [String: Bool] = [
        "ocrSelection.recognizeText": true,
        "ocrSelection.copyText": true,
        "ocrSelection.pin": true,
        "ocrPin.selectText": true,
        "ocrPin.copyText": true,
        "screenTranslation.language": true,
        "screenTranslation.compare": true,
        "screenTranslation.toggleOriginalTranslation": true,
        "screenTranslation.copyOriginal": true,
        "screenTranslation.copyTranslation": true,
        "screenTranslation.pin": true,
        "screenTranslation.cancel": true,
        "translationPin.language": true,
        "translationPin.toggleOriginalTranslation": true,
        "translationPin.copyOriginal": true,
        "translationPin.copyTranslation": true,
        "translationPin.selectText": true,
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshotCurrentPreferences() throws -> SettingsProfileSnapshot {
        var values: [String: SettingsProfileValue] = [:]
        for (key, definition) in SettingsProfileSchema.fields where !isSpecial(key) {
            values[key] = valueFromDefaults(for: key, definition: definition)
        }

        for key in Self.colorKeys {
            values[key] = .color(try readColor(forKey: key))
        }
        snapshotHotkeys(into: &values)
        snapshotLayouts(into: &values)
        return SettingsProfileSnapshot(payload: SettingsProfilePayload(values: values))
    }

    func validate(_ payload: SettingsProfilePayload) throws {
        try SettingsProfileSchema.validate(payload)
        try validateDistinctItems(payload, primaryKey: "layout.toolbar.primaryToolRawValues", secondaryKey: "layout.toolbar.secondaryToolRawValues")
        try validateDistinctItems(payload, primaryKey: "layout.pin.primaryItemIDs", secondaryKey: "layout.pin.secondaryItemIDs")
        try validateDistinctItems(payload, primaryKey: "layout.statusMenu.primaryItemIDs", secondaryKey: "layout.statusMenu.secondaryItemIDs")

        if case .boolMap(let values)? = payload.values["layout.dedicatedToolVisibility"] {
            for key in values.keys where !isDedicatedToolKey(key) {
                throw SettingsProfilePreferenceBridgeError.invalidDedicatedToolKey(key)
            }
        }
    }

    func apply(_ payload: SettingsProfilePayload) throws {
        try validate(payload)
        for (key, definition) in SettingsProfileSchema.fields where !isSpecial(key) {
            try write(value(for: key, in: payload, definition: definition), to: key)
        }
        for key in Self.colorKeys {
            guard case .color(let color) = value(for: key, in: payload, definition: SettingsProfileSchema.fields[key]!) else {
                throw SettingsProfilePreferenceBridgeError.invalidColor(key)
            }
            try write(color: color, forKey: key)
        }
        applyHotkeys(from: payload)
        applyLayouts(from: payload)
    }

    /// Applies only preferences represented by the Shortcuts settings page.
    /// This lets a protected profile restore its own shortcut baseline without
    /// resetting capture output, appearance, layout, or any other preference.
    func applyShortcutPreferences(from payload: SettingsProfilePayload) throws {
        try SettingsProfileSchema.validate(payload)
        applyHotkeys(from: payload)

        let toolShortcuts = stringMapValue("overlayToolShortcuts", from: payload)
            ?? stringMapDefault(SettingsProfileSchema.fields["overlayToolShortcuts"]!)
        defaults.set(toolShortcuts, forKey: "overlayToolShortcuts")

        for actionID in SettingsProfileInteractionShortcutDefinitions.defaultModifiers.keys {
            let key = "interactionShortcutModifier.\(actionID)"
            let modifier = stringValue(key, from: payload)
                ?? SettingsProfileInteractionShortcutDefinitions.defaultModifiers[actionID]!
            defaults.set(modifier, forKey: key)
        }
    }

    private func valueFromDefaults(
        for key: String,
        definition: SettingsProfileSchema.FieldDefinition
    ) -> SettingsProfileValue {
        switch definition.kind {
        case .bool:
            return .bool((defaults.object(forKey: key) as? Bool) ?? boolDefault(definition))
        case .integer:
            return .integer((defaults.object(forKey: key) as? NSNumber)?.intValue ?? integerDefault(definition))
        case .double:
            return .double((defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? doubleDefault(definition))
        case .string:
            return .string(defaults.string(forKey: key) ?? stringDefault(definition))
        case .strings:
            return .strings(defaults.stringArray(forKey: key) ?? stringsDefault(definition))
        case .integers:
            return .integers((defaults.array(forKey: key) as? [NSNumber])?.map(\.intValue) ?? integersDefault(definition))
        case .stringMap:
            return .stringMap(defaults.dictionary(forKey: key) as? [String: String] ?? stringMapDefault(definition))
        case .boolMap:
            return .boolMap(defaults.dictionary(forKey: key) as? [String: Bool] ?? boolMapDefault(definition))
        case .color, .colors:
            return definition.defaultValue
        }
    }

    private func write(_ value: SettingsProfileValue, to key: String) throws {
        switch value {
        case .bool(let value): defaults.set(value, forKey: key)
        case .integer(let value): defaults.set(value, forKey: key)
        case .double(let value): defaults.set(value, forKey: key)
        case .string(let value): defaults.set(value, forKey: key)
        case .strings(let value): defaults.set(value, forKey: key)
        case .integers(let value): defaults.set(value, forKey: key)
        case .stringMap(let value): defaults.set(value, forKey: key)
        case .boolMap(let value): defaults.set(value, forKey: key)
        case .color, .colors:
            throw SettingsProfilePreferenceBridgeError.invalidLayoutValue(key)
        }
    }

    private func snapshotHotkeys(into values: inout [String: SettingsProfileValue]) {
        for binding in Self.hotkeyBindings {
            let prefix = "hotkey.\(binding.slot)"
            values["\(prefix).keyCode"] = .integer((defaults.object(forKey: binding.keyCodeKey) as? NSNumber)?.intValue ?? binding.defaultKeyCode)
            values["\(prefix).modifiers"] = .integer((defaults.object(forKey: binding.modifiersKey) as? NSNumber)?.intValue ?? binding.defaultModifiers)
            values["\(prefix).disabled"] = .bool((defaults.object(forKey: "hotkeyDisabled_\(binding.slot)") as? Bool) ?? false)
        }
    }

    private func applyHotkeys(from payload: SettingsProfilePayload) {
        for binding in Self.hotkeyBindings {
            let prefix = "hotkey.\(binding.slot)"
            defaults.set(integerValue("\(prefix).keyCode", from: payload) ?? binding.defaultKeyCode, forKey: binding.keyCodeKey)
            defaults.set(integerValue("\(prefix).modifiers", from: payload) ?? binding.defaultModifiers, forKey: binding.modifiersKey)
            defaults.set(boolValue("\(prefix).disabled", from: payload) ?? false, forKey: "hotkeyDisabled_\(binding.slot)")
        }
    }

    private func snapshotLayouts(into values: inout [String: SettingsProfileValue]) {
        values["layout.toolbar.enabledToolRawValues"] = .integers(integerArray(forKey: "enabledTools", fallback: Self.defaultToolbarTools))
        values["layout.toolbar.primaryToolRawValues"] = .integers(integerArray(forKey: "primaryToolbarToolOrder", fallback: Self.defaultToolbarPrimaryTools))
        values["layout.toolbar.secondaryToolRawValues"] = .integers(integerArray(forKey: "secondaryToolbarToolOrder", fallback: Self.defaultToolbarSecondaryTools))
        values["layout.toolbar.enabledActionRawValues"] = .integers(integerArray(forKey: "enabledActions", fallback: Self.defaultToolbarActions))
        values["layout.pin.primaryItemIDs"] = .strings(defaults.stringArray(forKey: "primaryPinToolbarItemOrder") ?? Self.defaultPinPrimaryItems)
        values["layout.pin.secondaryItemIDs"] = .strings(defaults.stringArray(forKey: "secondaryPinToolbarItemOrder") ?? Self.defaultPinSecondaryItems)
        values["layout.statusMenu.enabledItemIDs"] = .strings(defaults.stringArray(forKey: "statusMenuEnabledItemIDs") ?? Self.defaultStatusItems)
        values["layout.statusMenu.primaryItemIDs"] = .strings(defaults.stringArray(forKey: "captureMenuItemOrder") ?? Self.defaultStatusPrimaryItems)
        values["layout.statusMenu.secondaryItemIDs"] = .strings(defaults.stringArray(forKey: "statusMenuMoreItemOrder") ?? Self.defaultStatusMoreItems)

        var dedicatedValues = Self.dedicatedToolDefaults
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("dedicatedToolbar.") && key.hasSuffix(".visible") {
            let profileKey = String(key.dropFirst("dedicatedToolbar.".count).dropLast(".visible".count))
            if isDedicatedToolKey(profileKey), let visible = value as? Bool {
                dedicatedValues[profileKey] = visible
            }
        }
        values["layout.dedicatedToolVisibility"] = .boolMap(dedicatedValues)
    }

    private func applyLayouts(from payload: SettingsProfilePayload) {
        let enabledTools = integerArrayValue("layout.toolbar.enabledToolRawValues", from: payload) ?? Self.defaultToolbarTools
        let primaryTools = integerArrayValue("layout.toolbar.primaryToolRawValues", from: payload) ?? Self.defaultToolbarPrimaryTools
        let secondaryTools = integerArrayValue("layout.toolbar.secondaryToolRawValues", from: payload) ?? Self.defaultToolbarSecondaryTools
        let enabledActions = integerArrayValue("layout.toolbar.enabledActionRawValues", from: payload) ?? Self.defaultToolbarActions
        defaults.set(enabledTools, forKey: "enabledTools")
        defaults.set(Self.defaultToolbarTools, forKey: "knownToolRawValues")
        defaults.set(primaryTools, forKey: "primaryToolbarToolOrder")
        defaults.set(secondaryTools, forKey: "secondaryToolbarToolOrder")
        defaults.set(enabledActions, forKey: "enabledActions")
        defaults.set(Self.defaultToolbarActions, forKey: "knownActionTags")

        let primaryPinItems = stringArrayValue("layout.pin.primaryItemIDs", from: payload) ?? Self.defaultPinPrimaryItems
        let secondaryPinItems = stringArrayValue("layout.pin.secondaryItemIDs", from: payload) ?? Self.defaultPinSecondaryItems
        defaults.set(primaryPinItems, forKey: "primaryPinToolbarItemOrder")
        defaults.set(secondaryPinItems, forKey: "secondaryPinToolbarItemOrder")
        defaults.set(primaryPinItems.contains("pinShadow"), forKey: "pinShadowToolInPrimary")
        defaults.set(primaryPinItems.contains("selectText"), forKey: "selectTextToolInPrimary")
        defaults.set(primaryPinItems.contains("screenTranslation"), forKey: "screenTranslationToolInPrimary")

        defaults.set(stringArrayValue("layout.statusMenu.enabledItemIDs", from: payload) ?? Self.defaultStatusItems, forKey: "statusMenuEnabledItemIDs")
        defaults.set(stringArrayValue("layout.statusMenu.primaryItemIDs", from: payload) ?? Self.defaultStatusPrimaryItems, forKey: "captureMenuItemOrder")
        defaults.set(stringArrayValue("layout.statusMenu.secondaryItemIDs", from: payload) ?? Self.defaultStatusMoreItems, forKey: "statusMenuMoreItemOrder")
        defaults.set(1, forKey: "statusMenuEnabledItemMigrationVersion")

        var dedicatedValues = Self.dedicatedToolDefaults
        if let profileValues = boolMapValue("layout.dedicatedToolVisibility", from: payload) {
            dedicatedValues.merge(profileValues) { _, profileValue in profileValue }
        }
        for (key, visible) in dedicatedValues {
            defaults.set(visible, forKey: "dedicatedToolbar.\(key).visible")
        }
    }

    private func readColor(forKey key: String) throws -> SettingsProfileRGBA {
        if let data = defaults.data(forKey: key),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
           let rgba = rgba(from: color) {
            return rgba
        }
        guard let rgba = rgba(from: fallbackColor(forKey: key)) else {
            throw SettingsProfilePreferenceBridgeError.invalidColor(key)
        }
        return rgba
    }

    private func write(color: SettingsProfileRGBA, forKey key: String) throws {
        guard color.isValid else { throw SettingsProfilePreferenceBridgeError.invalidColor(key) }
        let appKitColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        let data = try NSKeyedArchiver.archivedData(withRootObject: appKitColor, requiringSecureCoding: true)
        defaults.set(data, forKey: key)
    }

    private func rgba(from color: NSColor) -> SettingsProfileRGBA? {
        guard let sRGB = color.usingColorSpace(.sRGB) else { return nil }
        let value = SettingsProfileRGBA(
            red: sRGB.redComponent,
            green: sRGB.greenComponent,
            blue: sRGB.blueComponent,
            alpha: sRGB.alphaComponent
        )
        return value.isValid ? value : nil
    }

    private func fallbackColor(forKey key: String) -> NSColor {
        switch key {
        case "toolbarAccentColor": return NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
        case "toolbarIconColor": return NSColor(srgbRed: 0x1F / 255, green: 0x29 / 255, blue: 0x37 / 255, alpha: 1)
        case "toolbarBgColor": return NSColor(srgbRed: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255, alpha: 1)
        case "lastUsedColor": return .systemRed
        default: return .white
        }
    }

    private func validateDistinctItems(_ payload: SettingsProfilePayload, primaryKey: String, secondaryKey: String) throws {
        let primary = orderedItems(for: primaryKey, in: payload)
        let secondary = orderedItems(for: secondaryKey, in: payload)
        guard Set(primary).isDisjoint(with: Set(secondary)) else {
            throw SettingsProfilePreferenceBridgeError.overlappingLayoutItems(primaryKey)
        }
    }

    private func orderedItems(for key: String, in payload: SettingsProfilePayload) -> [String] {
        if case .strings(let values)? = payload.values[key] { return values }
        if case .integers(let values)? = payload.values[key] { return values.map(String.init) }
        return []
    }

    private func isSpecial(_ key: String) -> Bool {
        Self.colorKeys.contains(key)
            || key.hasPrefix("hotkey.")
            || key.hasPrefix("layout.")
    }

    private func integerArray(forKey key: String, fallback: [Int]) -> [Int] {
        (defaults.array(forKey: key) as? [NSNumber])?.map(\.intValue) ?? fallback
    }

    private func value(
        for key: String,
        in payload: SettingsProfilePayload,
        definition: SettingsProfileSchema.FieldDefinition
    ) -> SettingsProfileValue {
        payload.values[key] ?? definition.defaultValue
    }

    private func integerValue(_ key: String, from payload: SettingsProfilePayload) -> Int? {
        guard case .integer(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func boolValue(_ key: String, from payload: SettingsProfilePayload) -> Bool? {
        guard case .bool(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func stringValue(_ key: String, from payload: SettingsProfilePayload) -> String? {
        guard case .string(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func integerArrayValue(_ key: String, from payload: SettingsProfilePayload) -> [Int]? {
        guard case .integers(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func stringArrayValue(_ key: String, from payload: SettingsProfilePayload) -> [String]? {
        guard case .strings(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func stringMapValue(_ key: String, from payload: SettingsProfilePayload) -> [String: String]? {
        guard case .stringMap(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func boolMapValue(_ key: String, from payload: SettingsProfilePayload) -> [String: Bool]? {
        guard case .boolMap(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func boolDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> Bool {
        guard case .bool(let value) = definition.defaultValue else { return false }
        return value
    }

    private func integerDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> Int {
        guard case .integer(let value) = definition.defaultValue else { return 0 }
        return value
    }

    private func doubleDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> Double {
        guard case .double(let value) = definition.defaultValue else { return 0 }
        return value
    }

    private func stringDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> String {
        guard case .string(let value) = definition.defaultValue else { return "" }
        return value
    }

    private func stringsDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> [String] {
        guard case .strings(let value) = definition.defaultValue else { return [] }
        return value
    }

    private func integersDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> [Int] {
        guard case .integers(let value) = definition.defaultValue else { return [] }
        return value
    }

    private func stringMapDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> [String: String] {
        guard case .stringMap(let value) = definition.defaultValue else { return [:] }
        return value
    }

    private func boolMapDefault(_ definition: SettingsProfileSchema.FieldDefinition) -> [String: Bool] {
        guard case .boolMap(let value) = definition.defaultValue else { return [:] }
        return value
    }

    private func isDedicatedToolKey(_ key: String) -> Bool {
        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
    }
}

struct SettingsProfileSnapshot: Equatable {
    var payload: SettingsProfilePayload
}
