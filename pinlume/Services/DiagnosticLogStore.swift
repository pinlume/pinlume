import Foundation

struct AppStorageCleanupOptions: OptionSet {
    let rawValue: Int

    static let history = AppStorageCleanupOptions(rawValue: 1 << 0)
    static let clipboard = AppStorageCleanupOptions(rawValue: 1 << 1)
    static let pins = AppStorageCleanupOptions(rawValue: 1 << 2)
    static let diagnostics = AppStorageCleanupOptions(rawValue: 1 << 3)
}

/// Optional, bounded file diagnostics for user-supported troubleshooting.
/// The unified macOS log remains managed by the operating system; this store
/// never receives image bytes, OCR text, clipboard contents, or credentials.
enum DiagnosticLogStore {
    static let enabledKey = "diagnosticFileLoggingEnabled"
    static let maximumBytes = 2 * 1024 * 1024
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let loggingDidChangeNotification = Notification.Name("Pinlume.diagnosticLoggingDidChange")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: loggingDidChangeNotification, object: nil)
    }

    static var logURL: URL {
        AppIdentity.applicationSupportDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("diagnostic.log")
    }

    static func append(_ report: String) {
        guard isEnabled else { return }
        let fileManager = FileManager.default
        let url = logURL
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate,
           Date().timeIntervalSince(modified) > retention {
            try? fileManager.removeItem(at: url)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n========== \(timestamp) ==========\n\(report)\n"
        guard let entryData = entry.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entryData)
            try? handle.close()
        } else {
            try? entryData.write(to: url, options: .atomic)
        }
        trimToMaximumSize()
    }

    static func clear(
        fileManager: FileManager = .default,
        logURL: URL = Self.logURL,
        legacyTimingLogURL: URL = Self.legacyTimingLogURL,
        terminationLogURL: URL = Self.terminationLogURL
    ) {
        try? fileManager.removeItem(at: logURL)
        cleanupLegacyLogs(at: legacyTimingLogURL, fileManager: fileManager)
        try? fileManager.removeItem(at: terminationLogURL)
    }

    /// Removes the unbounded timing log written by legacy development builds.
    /// This path is intentionally separate from this app's diagnostic directory.
    static func cleanupLegacyLogs(
        at legacyTimingLogURL: URL = Self.legacyTimingLogURL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: legacyTimingLogURL)
    }

    static var legacyTimingLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pinlume/timing.log")
    }

    static var terminationLogURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/pinlume/termination.log")
    }

    static func storageURLs(applicationSupportDirectory: URL, libraryDirectory: URL) -> [URL] {
        [
            AppIdentity.applicationSupportDirectoryURL(
                in: applicationSupportDirectory)
                .appendingPathComponent("logs/diagnostic.log"),
            applicationSupportDirectory.appendingPathComponent("pinlume/timing.log"),
            libraryDirectory.appendingPathComponent("Logs/pinlume/termination.log"),
        ]
    }

    private static func trimToMaximumSize() {
        guard let data = try? Data(contentsOf: logURL), data.count > maximumBytes else { return }
        let suffix = data.suffix(maximumBytes)
        try? Data(suffix).write(to: logURL, options: .atomic)
    }
}
