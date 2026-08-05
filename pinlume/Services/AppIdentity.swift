import Foundation

enum AppIdentity {
    static let maintainerName = "duhuajie"
    static let maintainerURL = URL(string: "https://github.com/duhuajie")!

    #if INTERNAL_DEBUG
    static let bundleIdentifier = "com.pinlume.app.debug"
    #else
    static let bundleIdentifier = "com.pinlume.app"
    #endif
    static let applicationSupportDirectoryName = bundleIdentifier

    /// Read only for the one-time on-disk migration. These are not active
    /// product identifiers and must not be shown in the UI or used for new data.
    static let legacyApplicationSupportDirectoryNames = [
        "com.xiegang.macshot.plus",
        "com.sw33tlie.macshot",
    ]

    /// Internal Debug copies the current release preferences once so daily
    /// development starts with the same settings, without sharing later edits
    /// or moving the release app's history, pins, and other on-disk data.
    static let legacyPreferenceBundleIdentifiers: [String] = {
        #if INTERNAL_DEBUG
        return ["com.pinlume.app"] + legacyApplicationSupportDirectoryNames
        #else
        return legacyApplicationSupportDirectoryNames
        #endif
    }()
    static let preferencesMigrationMarkerKey = "pinlumeLegacyPreferencesMigrated"

    /// Copies the old app's UserDefaults domain once. The new domain wins on
    /// conflicts so a user who has already configured Pinlume is never reset.
    static func migrateLegacyPreferences(
        in defaults: UserDefaults = .standard,
        currentBundleIdentifier: String = bundleIdentifier,
        legacyBundleIdentifiers: [String] = legacyPreferenceBundleIdentifiers
    ) {
        let current = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        guard (current[preferencesMigrationMarkerKey] as? Bool) != true else { return }

        var merged = current
        for legacyBundleIdentifier in legacyBundleIdentifiers {
            guard let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) else { continue }
            for (key, value) in legacy where merged[key] == nil {
                merged[key] = value
            }
            break
        }
        merged[preferencesMigrationMarkerKey] = true
        defaults.setPersistentDomain(merged, forName: currentBundleIdentifier)
    }

    static let applicationSupportDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return resolveApplicationSupportDirectory(in: base)
    }()

    static func applicationSupportDirectory(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        resolveApplicationSupportDirectory(in: baseDirectory, fileManager: fileManager)
    }

    /// Pure path construction for reporting code that must not create or move
    /// anything merely by asking where product data belongs.
    static func applicationSupportDirectoryURL(in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(
            applicationSupportDirectoryName, isDirectory: true)
    }

    /// Moves the old storage root in place and leaves a symlink behind so a
    /// rollback build still sees the same data. No screenshot, token, history,
    /// or diagnostic content is decoded during migration.
    static func resolveApplicationSupportDirectory(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let current = applicationSupportDirectoryURL(in: baseDirectory)
        if fileManager.fileExists(atPath: current.path) {
            applyOwnerOnlyPermissions(to: current, fileManager: fileManager)
            return current
        }

        for legacyName in legacyApplicationSupportDirectoryNames {
            let legacy = baseDirectory.appendingPathComponent(legacyName, isDirectory: true)
            var legacyIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
                  legacyIsDirectory.boolValue else { continue }

            do {
                try fileManager.moveItem(at: legacy, to: current)
                do {
                    try fileManager.createSymbolicLink(at: legacy, withDestinationURL: current)
                } catch {
                    try? fileManager.moveItem(at: current, to: legacy)
                    return fileManager.fileExists(atPath: legacy.path) ? legacy : current
                }
                applyOwnerOnlyPermissions(to: current, fileManager: fileManager)
                return current
            } catch {
                if fileManager.fileExists(atPath: current.path) {
                    applyOwnerOnlyPermissions(to: current, fileManager: fileManager)
                    return current
                }
                return legacy
            }
        }

        try? fileManager.createDirectory(
            at: current,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        applyOwnerOnlyPermissions(to: current, fileManager: fileManager)
        return current
    }

    private static func applyOwnerOnlyPermissions(
        to directory: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
