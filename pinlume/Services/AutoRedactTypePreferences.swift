import Foundation

enum AutoRedactTypePreferences {
    static let enabledTypesKey = "enabledRedactTypes"
    static let selectionInitializedKey = "redactTypesSelectionInitialized"

    static let allTypeKeys: Set<String> = [
        "email", "phone", "ssn", "credit_card", "cvv", "expiry", "ipv4",
        "aws_key", "secret_assignment", "hex_key", "bearer"
    ]

    static func selectedTypes(defaults: UserDefaults = .standard) -> Set<String> {
        if defaults.bool(forKey: selectionInitializedKey) {
            return Set(defaults.stringArray(forKey: enabledTypesKey) ?? []).intersection(allTypeKeys)
        }

        if let storedTypes = defaults.stringArray(forKey: enabledTypesKey), !storedTypes.isEmpty {
            return Set(storedTypes).intersection(allTypeKeys)
        }

        var selectedTypes = allTypeKeys
        var hasLegacySelection = false
        for key in allTypeKeys {
            guard defaults.object(forKey: key) != nil else { continue }
            hasLegacySelection = true
            if !defaults.bool(forKey: key) {
                selectedTypes.remove(key)
            }
        }
        return hasLegacySelection ? selectedTypes : allTypeKeys
    }

    static func store(_ selectedTypes: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(selectedTypes.intersection(allTypeKeys).sorted(), forKey: enabledTypesKey)
        defaults.set(true, forKey: selectionInitializedKey)
    }
}
