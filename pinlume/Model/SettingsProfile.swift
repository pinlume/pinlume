import Foundation

/// Portable RGBA representation used by configuration profiles. AppKit colors
/// are converted at the preference bridge boundary so profile documents stay
/// Foundation-only and portable.
struct SettingsProfileRGBA: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// The only value shapes allowed in a configuration profile. Keeping this
/// deliberately small prevents arbitrary UserDefaults objects from becoming
/// importable profile data.
enum SettingsProfileValue: Codable, Equatable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case integers([Int])
    case color(SettingsProfileRGBA)
    case colors([SettingsProfileRGBA])
    case stringMap([String: String])
    case boolMap([String: Bool])

    enum Kind: String, Codable {
        case bool
        case integer
        case double
        case string
        case strings
        case integers
        case color
        case colors
        case stringMap
        case boolMap
    }

    var kind: Kind {
        switch self {
        case .bool: return .bool
        case .integer: return .integer
        case .double: return .double
        case .string: return .string
        case .strings: return .strings
        case .integers: return .integers
        case .color: return .color
        case .colors: return .colors
        case .stringMap: return .stringMap
        case .boolMap: return .boolMap
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case boolValue
        case integerValue
        case doubleValue
        case stringValue
        case stringsValue
        case integersValue
        case colorValue
        case colorsValue
        case stringMapValue
        case boolMapValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .boolValue))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .integerValue))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .doubleValue))
        case .string:
            self = .string(try container.decode(String.self, forKey: .stringValue))
        case .strings:
            self = .strings(try container.decode([String].self, forKey: .stringsValue))
        case .integers:
            self = .integers(try container.decode([Int].self, forKey: .integersValue))
        case .color:
            self = .color(try container.decode(SettingsProfileRGBA.self, forKey: .colorValue))
        case .colors:
            self = .colors(try container.decode([SettingsProfileRGBA].self, forKey: .colorsValue))
        case .stringMap:
            self = .stringMap(try container.decode([String: String].self, forKey: .stringMapValue))
        case .boolMap:
            self = .boolMap(try container.decode([String: Bool].self, forKey: .boolMapValue))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .bool(let value): try container.encode(value, forKey: .boolValue)
        case .integer(let value): try container.encode(value, forKey: .integerValue)
        case .double(let value): try container.encode(value, forKey: .doubleValue)
        case .string(let value): try container.encode(value, forKey: .stringValue)
        case .strings(let value): try container.encode(value, forKey: .stringsValue)
        case .integers(let value): try container.encode(value, forKey: .integersValue)
        case .color(let value): try container.encode(value, forKey: .colorValue)
        case .colors(let value): try container.encode(value, forKey: .colorsValue)
        case .stringMap(let value): try container.encode(value, forKey: .stringMapValue)
        case .boolMap(let value): try container.encode(value, forKey: .boolMapValue)
        }
    }
}

struct SettingsProfilePayload: Codable, Equatable {
    var values: [String: SettingsProfileValue]

    init(values: [String: SettingsProfileValue] = [:]) {
        self.values = values
    }
}

/// Shared portable definitions for the 18 global shortcut slots. The profile
/// bridge and runtime preflight both use this source so an omitted profile
/// field resolves exactly like the existing hotkey registration path.
struct SettingsProfileHotkeyDefinition: Equatable {
    let slot: Int
    let keyCodeKey: String
    let modifiersKey: String
    let defaultKeyCode: Int
    let defaultModifiers: Int

    static let all: [SettingsProfileHotkeyDefinition] = [
        .init(slot: 1, keyCodeKey: "hotkeyKeyCode", modifiersKey: "hotkeyModifiers", defaultKeyCode: 122, defaultModifiers: 256),
        .init(slot: 2, keyCodeKey: "hotkeyFullScreenKeyCode", modifiersKey: "hotkeyFullScreenModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 3, keyCodeKey: "hotkeyRecordKeyCode", modifiersKey: "hotkeyRecordModifiers", defaultKeyCode: 15, defaultModifiers: 768),
        .init(slot: 4, keyCodeKey: "hotkeyRecordFullScreenKeyCode", modifiersKey: "hotkeyRecordFullScreenModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 5, keyCodeKey: "hotkeyHistoryKeyCode", modifiersKey: "hotkeyHistoryModifiers", defaultKeyCode: 4, defaultModifiers: 768),
        .init(slot: 6, keyCodeKey: "hotkeyOCRKeyCode", modifiersKey: "hotkeyOCRModifiers", defaultKeyCode: 17, defaultModifiers: 768),
        .init(slot: 7, keyCodeKey: "hotkeyQuickCaptureKeyCode", modifiersKey: "hotkeyQuickCaptureModifiers", defaultKeyCode: 1, defaultModifiers: 768),
        .init(slot: 8, keyCodeKey: "hotkeyScrollCaptureKeyCode", modifiersKey: "hotkeyScrollCaptureModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 9, keyCodeKey: "hotkeyOpenClipboardKeyCode", modifiersKey: "hotkeyOpenClipboardModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 10, keyCodeKey: "hotkeyCaptureLastAreaKeyCode", modifiersKey: "hotkeyCaptureLastAreaModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 11, keyCodeKey: "hotkeyPinClipboardKeyCode", modifiersKey: "hotkeyPinClipboardModifiers", defaultKeyCode: 99, defaultModifiers: 0),
        .init(slot: 12, keyCodeKey: "hotkeyClearHistoryKeyCode", modifiersKey: "hotkeyClearHistoryModifiers", defaultKeyCode: 0, defaultModifiers: 0),
        .init(slot: 13, keyCodeKey: "hotkeyToggleAllPinsKeyCode", modifiersKey: "hotkeyToggleAllPinsModifiers", defaultKeyCode: 99, defaultModifiers: 2_560),
        .init(slot: 14, keyCodeKey: "hotkeySelectableOCRKeyCode", modifiersKey: "hotkeySelectableOCRModifiers", defaultKeyCode: 120, defaultModifiers: 2_560),
        .init(slot: 15, keyCodeKey: "hotkeyTranslationWindowKeyCode", modifiersKey: "hotkeyTranslationWindowModifiers", defaultKeyCode: 19, defaultModifiers: 2_048),
        .init(slot: 16, keyCodeKey: "hotkeyScreenTranslationKeyCode", modifiersKey: "hotkeyScreenTranslationModifiers", defaultKeyCode: 3, defaultModifiers: 2_048),
        .init(slot: 17, keyCodeKey: "hotkeyTransparentAnnotationKeyCode", modifiersKey: "hotkeyTransparentAnnotationModifiers", defaultKeyCode: 47, defaultModifiers: 2_304),
        .init(slot: 18, keyCodeKey: "hotkeyPresentationDrawingKeyCode", modifiersKey: "hotkeyPresentationDrawingModifiers", defaultKeyCode: 43, defaultModifiers: 2_304),
    ]

    static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    static func definition(for slot: Int) -> SettingsProfileHotkeyDefinition? {
        all.first { $0.slot == slot }
    }
}

/// Portable defaults for configurable overlay shortcuts. Runtime routing stays
/// in ToolShortcutManager; this table only resolves omitted profile entries.
enum SettingsProfileToolShortcutDefinitions {
    static let defaultKeys: [String: String] = {
        var keys: [String: String] = [
            "pencil": "p", "arrow": "a", "line": "l", "rectangle": "r",
            "ellipse": "o", "marker": "m", "text": "t", "number": "n",
            "censor": "b", "highlight": "h", "colorSampler": "i", "stamp": "g",
            "measure": "", "loupe": "", "moveSelection": " ", "openInEditor": "e",
            "pin": "f", "copy": "", "save": "", "ocr": "", "scrollCapture": "",
            "beautify": "", "invertColors": "", "removeBackground": "", "translate": "",
            "undo": "z", "redo": "", "eraser": "",
        ]
        #if !OFFLINE
        keys["upload"] = "u"
        #endif
        return keys
    }()

    static func defaultKey(for actionID: String) -> String {
        defaultKeys[actionID] ?? ""
    }
}

enum SettingsProfileInteractionShortcutDefinitions {
    static let defaultModifiers: [String: String] = [
        "togglePixelInspector": "option",
        "togglePixelInspectorFormat": "shift",
        "nudgeInspectorCursor": "command",
        "nudgeSelection": "none",
        "pinZoom": "none",
        "pinOpacity": "command",
        "closePin": "none",
        "compactPin": "shift",
    ]

    static let conflictGroups: [[String]] = [
        ["togglePixelInspector", "togglePixelInspectorFormat"],
        ["nudgeInspectorCursor", "nudgeSelection"],
        ["pinZoom", "pinOpacity"],
        ["closePin", "compactPin"],
    ]
}

enum SettingsProfileKind: String, Codable, CaseIterable {
    case systemBasic
    case systemFull
    case custom
}

struct SettingsProfile: Codable, Equatable, Identifiable {
    static let currentConfigurationName = "Current Configuration"
    static let basicSystemStorageName = "system-basic"
    static let fullSystemStorageName = "system-full"

    var id: UUID
    var name: String
    let kind: SettingsProfileKind
    var isEditable: Bool
    var payload: SettingsProfilePayload

    init(
        id: UUID = UUID(),
        name: String,
        kind: SettingsProfileKind,
        isEditable: Bool,
        payload: SettingsProfilePayload
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEditable = isEditable
        self.payload = payload
    }
}

struct SettingsProfileDocument: Codable, Equatable {
    static let currentSchemaVersion = 12

    var schemaVersion: Int
    var profiles: [SettingsProfile]
    var activeProfileID: UUID

    var activeProfile: SettingsProfile {
        get {
            guard let profile = profiles.first(where: { $0.id == activeProfileID }) else {
                preconditionFailure("SettingsProfileDocument has no active profile")
            }
            return profile
        }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
                preconditionFailure("SettingsProfileDocument has no active profile")
            }
            profiles[index] = newValue
            activeProfileID = newValue.id
        }
    }

    init(schemaVersion: Int = SettingsProfileDocument.currentSchemaVersion, profiles: [SettingsProfile], activeProfileID: UUID) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }
}

/// The explicit portable configuration boundary. New preferences must be added
/// here with a type and validation range before the bridge can export them.
enum SettingsProfileSchema {
    struct FieldDefinition {
        let kind: SettingsProfileValue.Kind
        let defaultValue: SettingsProfileValue
        let integerRange: ClosedRange<Int>?
        let doubleRange: ClosedRange<Double>?
        let allowedStrings: Set<String>?
        let maximumStringLength: Int
        let maximumCollectionCount: Int
        let requiresUniqueElements: Bool

        init(
            kind: SettingsProfileValue.Kind,
            defaultValue: SettingsProfileValue,
            integerRange: ClosedRange<Int>? = nil,
            doubleRange: ClosedRange<Double>? = nil,
            allowedStrings: Set<String>? = nil,
            maximumStringLength: Int = 1_024,
            maximumCollectionCount: Int = 64,
            requiresUniqueElements: Bool = false
        ) {
            self.kind = kind
            self.defaultValue = defaultValue
            self.integerRange = integerRange
            self.doubleRange = doubleRange
            self.allowedStrings = allowedStrings
            self.maximumStringLength = maximumStringLength
            self.maximumCollectionCount = maximumCollectionCount
            self.requiresUniqueElements = requiresUniqueElements
        }
    }

    static let maximumProfileCount = 32
    static let maximumFieldCount = 256
    static let maximumProfileNameLength = 80
    static let maximumDictionaryKeyLength = 128

    static let fields: [String: FieldDefinition] = makeFields()

    /// Profiles are allowed to omit fields so older exports remain portable.
    /// Compare them after resolving omissions to the same defaults the bridge
    /// applies at runtime; otherwise an unrelated defaults notification can
    /// look like a user edit and create a copy of a built-in profile.
    static func semanticallyEqual(
        _ lhs: SettingsProfilePayload,
        _ rhs: SettingsProfilePayload
    ) -> Bool {
        var normalizedLHS = normalized(lhs)
        var normalizedRHS = normalized(rhs)
        if usesSamePresetToolbarScheme(normalizedLHS, normalizedRHS) {
            for key in toolbarColorKeys {
                normalizedLHS.values.removeValue(forKey: key)
                normalizedRHS.values.removeValue(forKey: key)
            }
        }
        return normalizedLHS == normalizedRHS
    }

    private static let toolbarColorKeys: Set<String> = [
        "toolbarAccentColor",
        "toolbarIconColor",
        "toolbarBgColor",
    ]

    private static let presetToolbarSchemeIDs: Set<String> = [
        "graphiteBlue", "midnightIndigo", "deepTeal", "amber", "forest", "mono",
    ]

    /// A preset's stored colors are derived from the current light/dark
    /// appearance. The preset identifier is the user's actual choice; those
    /// derived values must not be mistaken for a manual palette edit.
    private static func usesSamePresetToolbarScheme(
        _ lhs: SettingsProfilePayload,
        _ rhs: SettingsProfilePayload
    ) -> Bool {
        guard case .string(let lhsID)? = lhs.values["toolbarColorSchemeID"],
              case .string(let rhsID)? = rhs.values["toolbarColorSchemeID"],
              lhsID == rhsID
        else { return false }
        return presetToolbarSchemeIDs.contains(lhsID)
    }

    private static func normalized(_ payload: SettingsProfilePayload) -> SettingsProfilePayload {
        var values = payload.values
        for (key, definition) in fields where values[key] == nil {
            values[key] = definition.defaultValue
        }
        return SettingsProfilePayload(values: values)
    }

    static func validate(_ payload: SettingsProfilePayload) throws {
        guard payload.values.count <= maximumFieldCount else {
            throw SettingsProfileStoreError.tooManyFields
        }

        for (key, value) in payload.values {
            guard let definition = fields[key] else {
                throw SettingsProfileStoreError.unknownField(key)
            }
            guard definition.kind == value.kind else {
                throw SettingsProfileStoreError.wrongValueType(key)
            }
            try validate(value, key: key, definition: definition)
        }
    }

    private static func validate(_ value: SettingsProfileValue, key: String, definition: FieldDefinition) throws {
        func validateString(_ value: String) throws {
            guard value.count <= definition.maximumStringLength else {
                throw SettingsProfileStoreError.stringTooLong(key)
            }
            if let allowedStrings = definition.allowedStrings, !allowedStrings.contains(value) {
                throw SettingsProfileStoreError.invalidEnumValue(key)
            }
        }

        switch value {
        case .bool:
            break
        case .integer(let value):
            guard definition.integerRange?.contains(value) ?? true else {
                throw SettingsProfileStoreError.outOfRange(key)
            }
        case .double(let value):
            guard value.isFinite, definition.doubleRange?.contains(value) ?? true else {
                throw SettingsProfileStoreError.outOfRange(key)
            }
        case .string(let value):
            try validateString(value)
        case .strings(let values):
            guard values.count <= definition.maximumCollectionCount else {
                throw SettingsProfileStoreError.collectionTooLarge(key)
            }
            for value in values { try validateString(value) }
            if definition.requiresUniqueElements, Set(values).count != values.count {
                throw SettingsProfileStoreError.duplicateCollectionElement(key)
            }
        case .integers(let values):
            guard values.count <= definition.maximumCollectionCount else {
                throw SettingsProfileStoreError.collectionTooLarge(key)
            }
            for value in values where !(definition.integerRange?.contains(value) ?? true) {
                throw SettingsProfileStoreError.outOfRange(key)
            }
            if definition.requiresUniqueElements, Set(values).count != values.count {
                throw SettingsProfileStoreError.duplicateCollectionElement(key)
            }
        case .color(let color):
            guard color.isValid else { throw SettingsProfileStoreError.invalidColor(key) }
        case .colors(let colors):
            guard colors.count <= definition.maximumCollectionCount else {
                throw SettingsProfileStoreError.collectionTooLarge(key)
            }
            guard colors.allSatisfy(\.isValid) else { throw SettingsProfileStoreError.invalidColor(key) }
        case .stringMap(let values):
            try validateMap(values, key: key, definition: definition, validateValue: validateString)
        case .boolMap(let values):
            guard values.count <= definition.maximumCollectionCount else {
                throw SettingsProfileStoreError.collectionTooLarge(key)
            }
            guard values.keys.allSatisfy({ $0.count <= maximumDictionaryKeyLength }) else {
                throw SettingsProfileStoreError.stringTooLong(key)
            }
        }
    }

    private static func validateMap(
        _ values: [String: String],
        key: String,
        definition: FieldDefinition,
        validateValue: (String) throws -> Void
    ) throws {
        guard values.count <= definition.maximumCollectionCount else {
            throw SettingsProfileStoreError.collectionTooLarge(key)
        }
        for (mapKey, value) in values {
            guard mapKey.count <= maximumDictionaryKeyLength else {
                throw SettingsProfileStoreError.stringTooLong(key)
            }
            try validateValue(value)
        }
    }

    private static func makeFields() -> [String: FieldDefinition] {
        var fields: [String: FieldDefinition] = [:]

        func add(_ key: String, _ definition: FieldDefinition) {
            precondition(fields[key] == nil, "Duplicate settings profile field: \(key)")
            fields[key] = definition
        }
        func bool(_ key: String, default value: Bool = false) {
            add(key, FieldDefinition(kind: .bool, defaultValue: .bool(value)))
        }
        func integer(_ key: String, default value: Int = 0, range: ClosedRange<Int>) {
            add(key, FieldDefinition(kind: .integer, defaultValue: .integer(value), integerRange: range))
        }
        func double(_ key: String, default value: Double = 0, range: ClosedRange<Double>) {
            add(key, FieldDefinition(kind: .double, defaultValue: .double(value), doubleRange: range))
        }
        func string(_ key: String, default value: String = "", allowed: Set<String>? = nil, maximumLength: Int = 1_024) {
            add(key, FieldDefinition(kind: .string, defaultValue: .string(value), allowedStrings: allowed, maximumStringLength: maximumLength))
        }
        func strings(_ key: String, maximumCount: Int = 64, unique: Bool = false, maximumLength: Int = 128) {
            add(key, FieldDefinition(kind: .strings, defaultValue: .strings([]), maximumStringLength: maximumLength, maximumCollectionCount: maximumCount, requiresUniqueElements: unique))
        }
        func integers(_ key: String, range: ClosedRange<Int>, maximumCount: Int = 64, unique: Bool = false) {
            add(key, FieldDefinition(kind: .integers, defaultValue: .integers([]), integerRange: range, maximumCollectionCount: maximumCount, requiresUniqueElements: unique))
        }
        func color(_ key: String, default value: SettingsProfileRGBA = SettingsProfileRGBA(red: 1, green: 1, blue: 1, alpha: 1)) {
            add(key, FieldDefinition(kind: .color, defaultValue: .color(value)))
        }
        func colors(_ key: String, maximumCount: Int = 64) {
            add(key, FieldDefinition(kind: .colors, defaultValue: .colors([]), maximumCollectionCount: maximumCount))
        }
        func stringMap(_ key: String, maximumCount: Int = 64, maximumLength: Int = 128) {
            add(key, FieldDefinition(kind: .stringMap, defaultValue: .stringMap([:]), maximumStringLength: maximumLength, maximumCollectionCount: maximumCount))
        }
        func boolMap(_ key: String, maximumCount: Int = 64) {
            add(key, FieldDefinition(kind: .boolMap, defaultValue: .boolMap([:]), maximumCollectionCount: maximumCount))
        }

        // General and appearance.
        string("appLanguage", default: "system", allowed: LanguageManager.supportedLanguageCodes, maximumLength: 16)
        string("applicationAppearance", default: "system", allowed: ["system", "light", "dark"], maximumLength: 16)
        bool("urlSchemeEnabled", default: true)
        bool("hideMenuBarIcon")
        string("statusBarIconMode", default: "default", maximumLength: 32)
        string("statusBarIconSymbolName", maximumLength: 128)
        string("toolbarColorSchemeID", default: "custom", allowed: ["graphiteBlue", "midnightIndigo", "deepTeal", "amber", "forest", "mono", "custom"], maximumLength: 32)
        color("toolbarAccentColor", default: SettingsProfileRGBA(red: 0.145098, green: 0.388235, blue: 0.921569, alpha: 1))
        color("toolbarIconColor", default: SettingsProfileRGBA(red: 0.121569, green: 0.160784, blue: 0.215686, alpha: 1))
        color("toolbarBgColor", default: SettingsProfileRGBA(red: 0.972549, green: 0.980392, blue: 0.988235, alpha: 1))
        bool("showToolShortcutsInTooltips", default: true)

        // Capture, pin, thumbnail and ordinary output behaviour.
        integer("quickCaptureMode", default: 1, range: 0...4)
        // Retained only so older configuration profiles remain importable.
        // Runtime no longer reads this legacy editor-opening preference.
        bool("quickCaptureOpenEditor")
        integer("captureDelaySeconds", range: 0...60)
        bool("playCopySound", default: true)
        bool("rememberLastTool", default: true)
        integer("defaultAnnotationToolRawValue", range: 0...64)
        bool("showFloatingThumbnail", default: true)
        integer("thumbnailAutoDismiss", range: 0...3_600)
        string("thumbnailCorner", default: "bottomRight", maximumLength: 32)
        double("thumbnailScale", default: 1, range: 0.25...3)
        bool("thumbnailStacking", default: true)
        bool("pinCompactShowsThumbnail", default: true)
        bool("pinCompactShowsPartialImage", default: true)
        bool("snapGuidesEnabled", default: true)
        bool("windowSnapEnabled", default: true)
        bool("boundarySnapEnabled", default: true)
        bool("ignoreWindowOcclusionForSnaps")
        bool("captureCursor")
        bool("doubleClickToCopy", default: true)
        bool("hideCaptureInstructions")
        bool("disableSelectionOutsideShadow")
        string("preSelectionResolutionPresetKind", default: "freeform", maximumLength: 32)
        double("preSelectionResolutionPresetAspect", default: 1, range: 0.01...100)
        integer("preSelectionResolutionPresetWidth", default: 1, range: 1...32_768)
        integer("preSelectionResolutionPresetHeight", default: 1, range: 1...32_768)
        string("pinZoomAnchorMode", default: "mouse", maximumLength: 32)
        bool("pinWheelZoomEnabled", default: true)
        bool("pinMagnifyZoomEnabled", default: true)
        bool("pinSmoothZoomEnabled", default: true)
        string("doubleClickPinAction", default: "none", maximumLength: 32)
        bool("pinShadowEnabled", default: true)
        integer("saveAction", range: 0...8)
        string("filenameTemplate", default: "Screenshot {date} at {time}", maximumLength: 512)
        string("imageFormat", default: "png", allowed: ["png", "jpeg", "heic", "webp"], maximumLength: 16)
        double("imageQuality", default: 0.9, range: 0...1)
        bool("downscaleRetina")
        integer("historySize", default: 50, range: 1...10_000)
        bool("historyUnlimited")
        bool("historyOrderByLastEdit", default: true)

        // Global, interaction and tool shortcuts.
        for slot in 1...18 {
            integer("hotkey.\(slot).keyCode", range: 0...65_535)
            integer("hotkey.\(slot).modifiers", range: 0...65_535)
            bool("hotkey.\(slot).disabled")
        }
        stringMap("overlayToolShortcuts", maximumCount: 64, maximumLength: 16)
        let interactionModifiers: Set<String> = ["none", "command", "option", "shift", "control"]
        string("interactionShortcutModifier.togglePixelInspector", default: "option", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.togglePixelInspectorFormat", default: "shift", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.nudgeInspectorCursor", default: "command", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.nudgeSelection", default: "none", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.pinZoom", default: "none", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.pinOpacity", default: "command", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.closePin", default: "none", allowed: interactionModifiers, maximumLength: 16)
        string("interactionShortcutModifier.compactPin", default: "shift", allowed: interactionModifiers, maximumLength: 16)

        // Annotation and effects defaults.
        double("currentStrokeWidth", default: 3, range: 0.5...100)
        double("numberStrokeWidth", default: 3, range: 0.5...100)
        double("markerStrokeWidth", default: 20, range: 1...200)
        integer("currentLineStyle", range: 0...2)
        integer("currentArrowStyle", range: 0...5)
        integer("currentRectFillStyle", range: 0...2)
        double("currentRectCornerRadius", range: 0...1_000)
        bool("arrowReversed")
        bool("pencilPressureEnabled")
        string("pencilSmoothMode", default: "standard", maximumLength: 32)
        bool("pencilSmoothEnabled", default: true)
        bool("smartMarkerEnabled", default: true)
        double("highlightDimOpacity", default: 0.5, range: 0...1)
        bool("highlightBorderDashed")
        integer("censorMode", range: 0...3)
        integer("censorShape", range: 0...1)
        double("censorStrength", default: 6, range: 1...10)
        double("censorBrushWidth", default: 12, range: 1...500)
        strings("enabledRedactTypes", maximumCount: 32, unique: true, maximumLength: 64)
        integer("numberFormat", range: 0...3)
        integer("numberStartAt", default: 1, range: 0...9_999)
        bool("measureInPoints")
        double("loupeSize", default: 160, range: 40...1_024)
        double("loupeMagnification", default: 2, range: 1...16)
        bool("loupeOutlineEnabled", default: true)
        color("loupeOutlineColor")
        bool("annotationOutlineEnabled")
        color("annotationOutlineColor")
        // Keep the profile fallback aligned with OverlayView's drawing default.
        // A profile with this field omitted must not silently turn new lines white/gray.
        color("lastUsedColor", default: SettingsProfileRGBA(
            red: 1,
            green: 0.2196078431372549,
            blue: 0.23529411764705882,
            alpha: 1
        ))
        double("lastUsedColorOpacity", default: 1, range: 0...1)
        strings("customColors", maximumCount: 7, maximumLength: 16)
        string("textFontFamily", maximumLength: 128)
        double("textFontSize", default: 18, range: 6...288)
        bool("textBgEnabled")
        color("textBgColor")
        bool("textOutlineEnabled")
        color("textOutlineColor")
        bool("textGlyphStrokeEnabled")
        color("textGlyphStrokeColor")
        string("effectsPreset", default: "none", maximumLength: 32)
        double("effectsBrightness", range: -2...2)
        double("effectsContrast", default: 1, range: 0...4)
        double("effectsSaturation", default: 1, range: 0...4)
        double("effectsSharpness", range: 0...4)
        bool("keepAspectRatio", default: true)
        double("keepAspectRatioValue", default: 1, range: 0.01...100)
        bool("resolutionUnitIsPoints")
        bool("beautifyEnabled")
        string("beautifyMode", default: "gradient", maximumLength: 32)
        integer("beautifyStyleIndex", range: 0...256)
        double("beautifyPadding", range: 0...2_000)
        double("beautifyCornerRadius", range: 0...2_000)
        double("beautifyShadowRadius", range: 0...2_000)
        double("beautifyBgBlur", range: 0...200)
        double("beautifyBgRadius", range: 0...2_000)

        // OCR, translation, recording, scroll capture and safe upload choices.
        integer("ocrAction", range: 0...2)
        string("ocrRecognitionStrategy", default: "accurate", maximumLength: 32)
        bool("ocrDetectQRCodes", default: true)
        double("ocrResultFontSize", default: 14, range: 8...72)
        string("translationProvider", default: "apple", maximumLength: 32)
        string("translateTargetLang", default: "en", maximumLength: 16)
        integer("recordingFPS", default: 30, range: 1...240)
        string("recordingQuality", default: "high", maximumLength: 32)
        string("recordingOnStop", default: "save", maximumLength: 32)
        string("recordingFilenameTemplate", default: "Recording {date} at {time}", maximumLength: 512)
        bool("hideRecordingHUD")
        bool("recordSystemAudio")
        bool("recordMicAudio")
        bool("recordMouseHighlight")
        bool("recordKeystroke")
        bool("keystrokeShowAll")
        bool("recordWebcam")
        string("webcamPosition", default: "bottomRight", maximumLength: 32)
        string("webcamSize", default: "medium", maximumLength: 32)
        string("webcamShape", default: "circle", maximumLength: 32)
        bool("scrollAutoScrollEnabled", default: true)
        integer("scrollAutoScrollSpeed", default: 3, range: 1...4)
        integer("scrollMaxHeight", default: 16_384, range: 1_024...200_000)
        bool("scrollFrozenDetection", default: true)
        string("uploadProvider", default: "imgbb", maximumLength: 32)
        bool("uploadConfirmEnabled", default: true)

        // Structured layouts are projected through the existing preference models.
        integers("layout.toolbar.enabledToolRawValues", range: 0...1_000_000, maximumCount: 64, unique: true)
        integers("layout.toolbar.primaryToolRawValues", range: 0...1_000_000, maximumCount: 64, unique: true)
        integers("layout.toolbar.secondaryToolRawValues", range: 0...1_000_000, maximumCount: 64, unique: true)
        integers("layout.toolbar.enabledActionRawValues", range: 0...1_000_000, maximumCount: 64, unique: true)
        strings("layout.pin.primaryItemIDs", maximumCount: 64, unique: true, maximumLength: 64)
        strings("layout.pin.secondaryItemIDs", maximumCount: 64, unique: true, maximumLength: 64)
        strings("layout.statusMenu.enabledItemIDs", maximumCount: 64, unique: true, maximumLength: 64)
        strings("layout.statusMenu.primaryItemIDs", maximumCount: 64, unique: true, maximumLength: 64)
        strings("layout.statusMenu.secondaryItemIDs", maximumCount: 64, unique: true, maximumLength: 64)
        boolMap("layout.dedicatedToolVisibility", maximumCount: 64)

        return fields
    }
}
