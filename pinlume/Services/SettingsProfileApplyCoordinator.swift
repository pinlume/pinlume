import Foundation

/// Performs the profile write as a transaction over the existing preference
/// keys. Runtime refresh is intentionally separate so this layer never closes
/// overlays, discards annotations or re-registers shortcuts itself.
@MainActor
final class SettingsProfileApplyCoordinator {
    private let bridge: SettingsProfilePreferenceBridge

    init(defaults: UserDefaults = .standard) {
        bridge = SettingsProfilePreferenceBridge(defaults: defaults)
    }

    func snapshotCurrentPreferences() throws -> SettingsProfileSnapshot {
        try bridge.snapshotCurrentPreferences()
    }

    func validate(_ profile: SettingsProfile) throws {
        try bridge.validate(profile.payload)
    }

    func apply(_ profile: SettingsProfile) throws {
        try validate(profile)
        let rollback = try snapshotCurrentPreferences()
        do {
            try bridge.apply(profile.payload)
        } catch {
            try? bridge.apply(rollback.payload)
            throw error
        }
    }
}
