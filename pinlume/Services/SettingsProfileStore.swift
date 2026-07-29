import Foundation

enum SettingsProfileStoreError: Error, Equatable {
    case documentTooLarge
    case unsupportedSchema(Int)
    case emptyDocument
    case tooManyProfiles
    case duplicateProfileID
    case missingSystemProfile(SettingsProfileKind)
    case duplicateSystemProfile(SettingsProfileKind)
    case invalidSystemProfile(SettingsProfileKind)
    case invalidProfileName
    case duplicateCustomName
    case missingActiveProfile
    case tooManyFields
    case unknownField(String)
    case wrongValueType(String)
    case outOfRange(String)
    case invalidEnumValue(String)
    case stringTooLong(String)
    case collectionTooLarge(String)
    case duplicateCollectionElement(String)
    case invalidColor(String)
    case invalidExportDocument
    case cannotDeleteSystemProfile
    case cannotRenameSystemProfile
    case canOnlyDeleteActiveProfile
    case invalidDeletionFallback
}

/// Portable single-profile file format. It deliberately excludes local profile
/// IDs, kinds and the active-profile pointer so every import becomes a new
/// custom profile instead of mutating a built-in or local document.
struct SettingsProfileExportDocument: Codable, Equatable {
    // Export documents contain only a portable payload, so the local-document
    // migration that turns Basic into Slim must not invalidate existing files.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let name: String
    let payload: SettingsProfilePayload

    init(
        schemaVersion: Int = SettingsProfileExportDocument.currentSchemaVersion,
        name: String,
        payload: SettingsProfilePayload
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case name
        case payload
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard dynamicContainer.allKeys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
            throw SettingsProfileStoreError.invalidExportDocument
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        name = try container.decode(String.self, forKey: .name)
        payload = try container.decode(SettingsProfilePayload.self, forKey: .payload)
    }
}

/// Persistence and validation for profile documents. It intentionally has no
/// knowledge of AppKit, toolbars or live preferences; those stay behind the
/// later preference bridge and application coordinator.
final class SettingsProfileStore {
    static let storageKey = "settingsProfileDocumentV1"
    static let maximumDocumentBytes = 512 * 1_024
    private static let professionalSourceName = "满血版副本"

    struct LoadResult {
        let document: SettingsProfileDocument
        let createdNewDocument: Bool
        let migratedExistingDocument: Bool
    }

    func loadOrCreate(
        from defaults: UserDefaults,
        currentPayload: SettingsProfilePayload
    ) throws -> SettingsProfileDocument {
        try loadOrCreateResult(from: defaults, currentPayload: currentPayload).document
    }

    /// Keeps migration callers compatible while allowing app launch to apply a
    /// built-in preset exactly once for a genuinely new installation.
    func loadOrCreateResult(
        from defaults: UserDefaults,
        currentPayload: SettingsProfilePayload
    ) throws -> LoadResult {
        if let data = defaults.data(forKey: Self.storageKey) {
            let storedDocument = try decodeStoredDocument(from: data)
            let document = try migrateStoredDocumentIfNeeded(storedDocument, currentPayload: currentPayload)
            if document != storedDocument {
                try save(document, to: defaults)
            }
            return LoadResult(
                document: document,
                createdNewDocument: false,
                migratedExistingDocument: document != storedDocument
            )
        }

        try SettingsProfileSchema.validate(currentPayload)
        var basic = SettingsProfile(
            name: SettingsProfile.basicSystemStorageName,
            kind: .systemBasic,
            isEditable: false,
            payload: currentPayload
        )
        var full = SettingsProfile(
            name: SettingsProfile.fullSystemStorageName,
            kind: .systemFull,
            isEditable: false,
            payload: currentPayload
        )
        Self.applyBuiltinShortcutDefaults(to: &basic)
        Self.applyBuiltinShortcutDefaults(to: &full)
        Self.applyBuiltinQuickCaptureOutput(to: &basic)
        Self.applyBuiltinQuickCaptureOutput(to: &full)
        Self.applyBuiltinStatusBarIcon(to: &basic)
        Self.applyBuiltinStatusBarIcon(to: &full)
        Self.applyBuiltinStatusMenuDefaults(to: &basic)
        Self.applyBuiltinStatusMenuDefaults(to: &full)
        Self.applyBuiltinMarkerDefaults(to: &basic)
        Self.applyBuiltinMarkerDefaults(to: &full)
        Self.applySlimColorScheme(to: &basic)
        let document = SettingsProfileDocument(profiles: [basic, full], activeProfileID: basic.id)
        try save(document, to: defaults)
        return LoadResult(
            document: document,
            createdNewDocument: true,
            migratedExistingDocument: false
        )
    }

    func decodeDocument(from data: Data) throws -> SettingsProfileDocument {
        let document = try decodeStoredDocument(from: data)
        try validate(document)
        return document
    }

    func exportData(for profile: SettingsProfile, name: String? = nil) throws -> Data {
        try SettingsProfileSchema.validate(profile.payload)
        let exportName = name ?? profile.name
        guard !exportName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              exportName == exportName.trimmingCharacters(in: .whitespacesAndNewlines),
              exportName.count <= SettingsProfileSchema.maximumProfileNameLength
        else {
            throw SettingsProfileStoreError.invalidProfileName
        }
        let document = SettingsProfileExportDocument(name: exportName, payload: profile.payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw SettingsProfileStoreError.documentTooLarge
        }
        return data
    }

    /// Decodes and validates an import without changing the local document or
    /// preferences. The settings UI performs runtime shortcut preflight and
    /// actual application only after this candidate has been accepted.
    func importedProfile(from data: Data, into document: SettingsProfileDocument) throws -> SettingsProfile {
        guard data.count <= Self.maximumDocumentBytes else {
            throw SettingsProfileStoreError.documentTooLarge
        }
        try validate(document)
        let imported = try decodeExportDocument(from: data)
        let name = try uniqueCustomName(imported.name, in: document)
        return SettingsProfile(name: name, kind: .custom, isEditable: true, payload: imported.payload)
    }

    func importedProfile(from url: URL, into document: SettingsProfileDocument) throws -> SettingsProfile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumDocumentBytes + 1) ?? Data()
        return try importedProfile(from: data, into: document)
    }

    /// Produces the document state after removing the active custom profile.
    /// The caller applies the supplied Basic profile through the existing
    /// runtime route before committing this returned document to storage.
    func deletingActiveCustomProfile(
        _ profileID: UUID,
        from document: SettingsProfileDocument,
        activating fallbackProfileID: UUID
    ) throws -> SettingsProfileDocument {
        try validate(document)
        guard document.activeProfileID == profileID else {
            throw SettingsProfileStoreError.canOnlyDeleteActiveProfile
        }
        guard let profile = document.profiles.first(where: { $0.id == profileID }) else {
            throw SettingsProfileStoreError.missingActiveProfile
        }
        guard profile.kind == .custom else {
            throw SettingsProfileStoreError.cannotDeleteSystemProfile
        }
        guard document.profiles.first(where: { $0.id == fallbackProfileID })?.kind == .systemBasic else {
            throw SettingsProfileStoreError.invalidDeletionFallback
        }

        var updated = document
        updated.profiles.removeAll { $0.id == profileID }
        updated.activeProfileID = fallbackProfileID
        try validate(updated)
        return updated
    }

    func renamingCustomProfile(
        _ profileID: UUID,
        in document: SettingsProfileDocument,
        to requestedName: String
    ) throws -> SettingsProfileDocument {
        try validate(document)
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw SettingsProfileStoreError.missingActiveProfile
        }
        guard document.profiles[index].kind == .custom else {
            throw SettingsProfileStoreError.cannotRenameSystemProfile
        }

        var namesWithoutCurrentProfile = document
        namesWithoutCurrentProfile.profiles.removeAll { $0.id == profileID }
        let name = try uniqueCustomName(requestedName, in: namesWithoutCurrentProfile)
        var updated = document
        updated.profiles[index].name = name
        try validate(updated)
        return updated
    }

    /// Copies any profile into a new editable custom configuration and makes
    /// that copy active. The caller supplies the localized display-based name.
    func duplicatingProfile(
        _ profileID: UUID,
        in document: SettingsProfileDocument,
        named requestedName: String
    ) throws -> SettingsProfileDocument {
        try validate(document)
        guard let profile = document.profiles.first(where: { $0.id == profileID }) else {
            throw SettingsProfileStoreError.missingActiveProfile
        }
        let name = try uniqueCustomName(requestedName, in: document)
        let copy = SettingsProfile(name: name, kind: .custom, isEditable: true, payload: profile.payload)
        var updated = document
        updated.profiles.append(copy)
        updated.activeProfileID = copy.id
        try validate(updated)
        return updated
    }

    func save(_ document: SettingsProfileDocument, to defaults: UserDefaults) throws {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw SettingsProfileStoreError.documentTooLarge
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    func uniqueCustomName(_ requestedName: String, in document: SettingsProfileDocument) throws -> String {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= SettingsProfileSchema.maximumProfileNameLength else {
            throw SettingsProfileStoreError.invalidProfileName
        }

        let existingNames = Set(document.profiles.compactMap { profile -> String? in
            guard profile.kind == .custom else { return nil }
            return profile.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        if !existingNames.contains(canonicalName(trimmed)) {
            return trimmed
        }
        for suffix in 2...9_999 {
            let candidate = "\(trimmed) \(suffix)"
            guard candidate.count <= SettingsProfileSchema.maximumProfileNameLength else {
                throw SettingsProfileStoreError.invalidProfileName
            }
            if !existingNames.contains(canonicalName(candidate)) {
                return candidate
            }
        }
        throw SettingsProfileStoreError.invalidProfileName
    }

    private func decodeExportDocument(from data: Data) throws -> SettingsProfileExportDocument {
        let document: SettingsProfileExportDocument
        do {
            document = try JSONDecoder().decode(SettingsProfileExportDocument.self, from: data)
        } catch let error as SettingsProfileStoreError {
            throw error
        } catch {
            throw SettingsProfileStoreError.invalidExportDocument
        }
        guard document.schemaVersion == SettingsProfileExportDocument.currentSchemaVersion else {
            throw SettingsProfileStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.name == document.name.trimmingCharacters(in: .whitespacesAndNewlines),
              document.name.count <= SettingsProfileSchema.maximumProfileNameLength
        else {
            throw SettingsProfileStoreError.invalidProfileName
        }
        try SettingsProfileSchema.validate(document.payload)
        return document
    }

    private func decodeStoredDocument(from data: Data) throws -> SettingsProfileDocument {
        guard data.count <= Self.maximumDocumentBytes else {
            throw SettingsProfileStoreError.documentTooLarge
        }
        return try JSONDecoder().decode(SettingsProfileDocument.self, from: data)
    }

    private func migrateStoredDocumentIfNeeded(
        _ document: SettingsProfileDocument,
        currentPayload: SettingsProfilePayload
    ) throws -> SettingsProfileDocument {
        if document.schemaVersion < SettingsProfileDocument.currentSchemaVersion,
           document.profiles.contains(where: {
               if case .string? = $0.payload.values["pencilSmoothMode"] { return true }
               return false
           })
        {
            var normalized = document
            for index in normalized.profiles.indices {
                Self.migratePencilSmoothMode(to: &normalized.profiles[index])
            }
            return try migrateStoredDocumentIfNeeded(normalized, currentPayload: currentPayload)
        }
        switch document.schemaVersion {
        case SettingsProfileDocument.currentSchemaVersion:
            try validate(document)
            return document
        case 1:
            try validate(document, schemaVersion: 1, systemProfilesAreEditable: true)
            try SettingsProfileSchema.validate(currentPayload)
            var migrated = document
            migrated.schemaVersion = 2
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                migrated.profiles[index].isEditable = false
                migrated.profiles[index].payload = currentPayload
            }
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 2:
            try validate(document, schemaVersion: 2, systemProfilesAreEditable: false)
            try SettingsProfileSchema.validate(currentPayload)
            guard let basicIndex = document.profiles.firstIndex(where: { $0.kind == .systemBasic }) else {
                throw SettingsProfileStoreError.missingSystemProfile(.systemBasic)
            }
            var migrated = document
            migrated.schemaVersion = 3
            migrated.profiles[basicIndex].payload = currentPayload
            migrated.activeProfileID = migrated.profiles[basicIndex].id
            try validate(migrated, schemaVersion: 3, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 3:
            try validate(document, schemaVersion: 3, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 4
            try validate(migrated, schemaVersion: 4, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 4:
            try validate(document, schemaVersion: 4, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 5
            if let sourcePayload = migrated.profiles.first(where: {
                $0.kind == .custom && $0.name == Self.professionalSourceName
            })?.payload,
               let fullIndex = migrated.profiles.firstIndex(where: { $0.kind == .systemFull })
            {
                migrated.profiles[fullIndex].payload = sourcePayload
            }
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinCaptureHotkey(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 5, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 5:
            try validate(document, schemaVersion: 5, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 6
            guard let basicIndex = migrated.profiles.firstIndex(where: { $0.kind == .systemBasic }) else {
                throw SettingsProfileStoreError.missingSystemProfile(.systemBasic)
            }
            Self.applySlimColorScheme(to: &migrated.profiles[basicIndex])
            try validate(migrated, schemaVersion: 6, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 6:
            try validate(document, schemaVersion: 6, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 7
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinStatusBarIcon(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 7, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 7:
            try validate(document, schemaVersion: 7, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 8
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinQuickCaptureOutput(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 8, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 8:
            try validate(document, schemaVersion: 8, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 9
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinShortcutDefaults(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 9, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 9:
            try validate(document, schemaVersion: 9, systemProfilesAreEditable: false)
            guard let basicIndex = document.profiles.firstIndex(where: { $0.kind == .systemBasic }),
                  let fullIndex = document.profiles.firstIndex(where: { $0.kind == .systemFull }) else {
                throw SettingsProfileStoreError.missingSystemProfile(.systemBasic)
            }
            var migrated = document
            migrated.schemaVersion = 10
            Self.copyShortcutPreferences(from: migrated.profiles[basicIndex], to: &migrated.profiles[fullIndex])
            try validate(migrated, schemaVersion: 10, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 10:
            try validate(document, schemaVersion: 10, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 11
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinStatusMenuDefaults(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 11, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 11:
            try validate(document, schemaVersion: 11, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 12
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinShortcutDefaults(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 12, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 12:
            try validate(document, schemaVersion: 12, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 13
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinShortcutDefaults(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 13, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 13:
            try validate(document, schemaVersion: 13, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 14
            for index in migrated.profiles.indices {
                Self.migratePencilSmoothMode(to: &migrated.profiles[index])
                if migrated.profiles[index].kind != .custom {
                    Self.applyBuiltinShortcutDefaults(to: &migrated.profiles[index])
                }
            }
            try validate(migrated, schemaVersion: 14, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 14:
            try validate(document, schemaVersion: 14, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 15
            for index in migrated.profiles.indices where migrated.profiles[index].kind != .custom {
                Self.applyBuiltinMarkerDefaults(to: &migrated.profiles[index])
            }
            try validate(migrated, schemaVersion: 15, systemProfilesAreEditable: false)
            return try migrateStoredDocumentIfNeeded(migrated, currentPayload: currentPayload)
        case 15:
            try validate(document, schemaVersion: 15, systemProfilesAreEditable: false)
            var migrated = document
            migrated.schemaVersion = 16
            try validate(migrated)
            return migrated
        default:
            throw SettingsProfileStoreError.unsupportedSchema(document.schemaVersion)
        }
    }

    private func validate(_ document: SettingsProfileDocument) throws {
        try validate(
            document,
            schemaVersion: SettingsProfileDocument.currentSchemaVersion,
            systemProfilesAreEditable: false
        )
    }

    private func validate(
        _ document: SettingsProfileDocument,
        schemaVersion: Int,
        systemProfilesAreEditable: Bool
    ) throws {
        guard document.schemaVersion == schemaVersion else {
            throw SettingsProfileStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.profiles.isEmpty else { throw SettingsProfileStoreError.emptyDocument }
        guard document.profiles.count <= SettingsProfileSchema.maximumProfileCount else {
            throw SettingsProfileStoreError.tooManyProfiles
        }
        guard Set(document.profiles.map(\.id)).count == document.profiles.count else {
            throw SettingsProfileStoreError.duplicateProfileID
        }
        guard document.profiles.contains(where: { $0.id == document.activeProfileID }) else {
            throw SettingsProfileStoreError.missingActiveProfile
        }

        let basicProfiles = document.profiles.filter { $0.kind == .systemBasic }
        let fullProfiles = document.profiles.filter { $0.kind == .systemFull }
        try validateSystemProfiles(
            basicProfiles,
            kind: .systemBasic,
            expectedName: SettingsProfile.basicSystemStorageName,
            isEditable: systemProfilesAreEditable
        )
        try validateSystemProfiles(
            fullProfiles,
            kind: .systemFull,
            expectedName: SettingsProfile.fullSystemStorageName,
            isEditable: systemProfilesAreEditable
        )

        var customNames = Set<String>()
        for profile in document.profiles {
            if profile.kind == .custom {
                let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name == profile.name, name.count <= SettingsProfileSchema.maximumProfileNameLength else {
                    throw SettingsProfileStoreError.invalidProfileName
                }
                guard customNames.insert(canonicalName(name)).inserted else {
                    throw SettingsProfileStoreError.duplicateCustomName
                }
            }
            try SettingsProfileSchema.validate(profile.payload)
        }
    }

    private func validateSystemProfiles(
        _ profiles: [SettingsProfile],
        kind: SettingsProfileKind,
        expectedName: String,
        isEditable: Bool
    ) throws {
        guard let profile = profiles.first else { throw SettingsProfileStoreError.missingSystemProfile(kind) }
        guard profiles.count == 1 else { throw SettingsProfileStoreError.duplicateSystemProfile(kind) }
        guard profile.name == expectedName, profile.isEditable == isEditable else {
            throw SettingsProfileStoreError.invalidSystemProfile(kind)
        }
    }

    private static func applyBuiltinCaptureHotkey(to profile: inout SettingsProfile) {
        profile.payload.values["hotkey.1.keyCode"] = .integer(122)
        profile.payload.values["hotkey.1.modifiers"] = .integer(256)
        profile.payload.values["hotkey.1.disabled"] = .bool(false)
    }

    private static func applyBuiltinShortcutDefaults(to profile: inout SettingsProfile) {
        for definition in SettingsProfileHotkeyDefinition.all {
            let prefix = "hotkey.\(definition.slot)"
            profile.payload.values["\(prefix).keyCode"] = .integer(definition.defaultKeyCode)
            profile.payload.values["\(prefix).modifiers"] = .integer(definition.defaultModifiers)
            profile.payload.values["\(prefix).disabled"] = .bool(definition.defaultDisabled)
        }

        var toolShortcuts: [String: String] = [:]
        if case .stringMap(let existing)? = profile.payload.values["overlayToolShortcuts"] {
            toolShortcuts = existing
        }
        toolShortcuts["undo"] = "z"
        profile.payload.values["overlayToolShortcuts"] = .stringMap(toolShortcuts)
    }

    private static func migratePencilSmoothMode(to profile: inout SettingsProfile) {
        guard case .string(let legacyValue)? = profile.payload.values["pencilSmoothMode"] else { return }
        let mode: Int
        switch legacyValue.lowercased() {
        case "none", "0": mode = 0
        case "refined", "extra", "2": mode = 2
        default: mode = 1
        }
        profile.payload.values["pencilSmoothMode"] = .integer(mode)
    }

    /// Slim owns the shared built-in shortcut baseline. Professional keeps its
    /// own feature availability, but uses the same shortcut assignments.
    private static func copyShortcutPreferences(from source: SettingsProfile, to destination: inout SettingsProfile) {
        for definition in SettingsProfileHotkeyDefinition.all {
            let prefix = "hotkey.\(definition.slot)"
            copyShortcutValue("\(prefix).keyCode", from: source, to: &destination)
            copyShortcutValue("\(prefix).modifiers", from: source, to: &destination)
            copyShortcutValue("\(prefix).disabled", from: source, to: &destination)
        }
        copyShortcutValue("overlayToolShortcuts", from: source, to: &destination)
        for actionID in SettingsProfileInteractionShortcutDefinitions.defaultModifiers.keys {
            copyShortcutValue("interactionShortcutModifier.\(actionID)", from: source, to: &destination)
        }
    }

    private static func copyShortcutValue(_ key: String, from source: SettingsProfile, to destination: inout SettingsProfile) {
        if let value = source.payload.values[key] {
            destination.payload.values[key] = value
        } else {
            destination.payload.values.removeValue(forKey: key)
        }
    }

    private static func applyBuiltinQuickCaptureOutput(to profile: inout SettingsProfile) {
        profile.payload.values["quickCaptureMode"] = .integer(1)
    }

    private static func applyBuiltinStatusBarIcon(to profile: inout SettingsProfile) {
        profile.payload.values["statusBarIconMode"] = .string("default")
        profile.payload.values["statusBarIconSymbolName"] = .string("")
    }

    private static func applyBuiltinMarkerDefaults(to profile: inout SettingsProfile) {
        profile.payload.values["markerStrokeWidth"] = .double(3)
        profile.payload.values["smartMarkerEnabled"] = .bool(false)
    }

    /// System profile payloads must match the status-menu model exactly.
    /// Otherwise its own startup migration adds newly introduced items after a
    /// profile is applied and Settings mistakes that system write for a user edit.
    private static func applyBuiltinStatusMenuDefaults(to profile: inout SettingsProfile) {
        profile.payload.values["layout.statusMenu.enabledItemIDs"] = .strings(CaptureMenuItemID.configurableItems.map(\.rawValue))
        profile.payload.values["layout.statusMenu.primaryItemIDs"] = .strings(CaptureMenuItemID.defaultPrimaryOrder.map(\.rawValue))
        profile.payload.values["layout.statusMenu.secondaryItemIDs"] = .strings(CaptureMenuItemID.defaultMoreOrder.map(\.rawValue))
    }

    private static func applySlimColorScheme(to profile: inout SettingsProfile) {
        profile.payload.values["toolbarColorSchemeID"] = .string("graphiteBlue")
    }

    private func canonicalName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
