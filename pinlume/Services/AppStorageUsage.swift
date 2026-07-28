import Foundation

enum AppStorageCategory: CaseIterable {
    case history
    case clipboard
    case pins
    case diagnostics
}

struct AppStorageUsageSnapshot: Equatable {
    let bytesByCategory: [AppStorageCategory: Int64]

    func formattedSize(for category: AppStorageCategory) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesByCategory[category] ?? 0)
    }
}

struct AppStorageUsagePaths {
    let pathsByCategory: [AppStorageCategory: [URL]]

    init(history: [URL], clipboard: [URL], pins: [URL], diagnostics: [URL]) {
        pathsByCategory = [
            .history: history,
            .clipboard: clipboard,
            .pins: pins,
            .diagnostics: diagnostics,
        ]
    }

    static func production(fileManager: FileManager = .default) -> AppStorageUsagePaths {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return production(applicationSupportDirectory: applicationSupport, libraryDirectory: library)
    }

    static func production(
        applicationSupportDirectory: URL,
        libraryDirectory: URL
    ) -> AppStorageUsagePaths {
        let applicationSupport = applicationSupportDirectory
        let appDirectory = AppIdentity.applicationSupportDirectoryURL(in: applicationSupport)

        return AppStorageUsagePaths(
            history: [appDirectory.appendingPathComponent("history", isDirectory: true)],
            clipboard: [appDirectory.appendingPathComponent("clipboard", isDirectory: true)],
            pins: [
                appDirectory.appendingPathComponent("pins.json"),
                appDirectory.appendingPathComponent("images", isDirectory: true),
            ],
            diagnostics: DiagnosticLogStore.storageURLs(
                applicationSupportDirectory: applicationSupport,
                libraryDirectory: libraryDirectory
            )
        )
    }
}

enum AppStorageUsage {
    static func calculate(
        pathsFactory: @escaping () -> AppStorageUsagePaths = { AppStorageUsagePaths.production() },
        completion: @escaping (AppStorageUsageSnapshot) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let paths = pathsFactory()
            let snapshot = calculate(paths: paths)
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    static func calculate(
        paths: AppStorageUsagePaths,
        fileManager: FileManager = .default
    ) -> AppStorageUsageSnapshot {
        var bytesByCategory: [AppStorageCategory: Int64] = [:]
        for category in AppStorageCategory.allCases {
            bytesByCategory[category] = paths.pathsByCategory[category, default: []]
                .reduce(0) { $0 + logicalSize(of: $1, fileManager: fileManager) }
        }
        return AppStorageUsageSnapshot(bytesByCategory: bytesByCategory)
    }

    private static func logicalSize(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true else { return 0 }

        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
              ) else { return 0 }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            guard let itemValues = try? itemURL.resourceValues(forKeys: keys) else { continue }
            if itemValues.isSymbolicLink == true {
                if itemValues.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard itemValues.isRegularFile == true else { continue }
            total += Int64(itemValues.fileSize ?? 0)
        }
        return total
    }
}
