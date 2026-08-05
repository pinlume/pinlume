import Foundation

enum ScreenshotHistoryIndexLoadState: Equatable {
    case missing
    case valid
    case corrupt
}

struct ScreenshotHistoryIndexEntry: Codable, Equatable {
    let id: String
    let fileExtension: String
    let timestamp: Date
    let pixelWidth: Int
    let pixelHeight: Int
    var hasAnnotations: Bool?
    var lastEditedAt: Date?
}

struct ScreenshotHistoryIndexStartup {
    let state: ScreenshotHistoryIndexLoadState
    let entries: [ScreenshotHistoryIndexEntry]
    let shouldPruneOrphanedFiles: Bool
}

/// Owns the on-disk history index boundary. In particular, it never lets an
/// unreadable index masquerade as an intentionally empty history.
struct ScreenshotHistoryIndexStore {
    private static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    private let historyDirectory: URL
    private let indexFile: URL
    private let recoveryProtectionFile: URL
    private let fileManager: FileManager

    init(historyDirectory: URL, fileManager: FileManager = .default) {
        self.historyDirectory = historyDirectory
        self.indexFile = historyDirectory.appendingPathComponent("index.json")
        self.recoveryProtectionFile = historyDirectory.appendingPathComponent("index.recovery-protected.json")
        self.fileManager = fileManager
    }

    func prepareForStartup() -> ScreenshotHistoryIndexStartup {
        guard fileManager.fileExists(atPath: indexFile.path) else {
            return ScreenshotHistoryIndexStartup(
                state: .missing,
                entries: rebuildEntries(),
                shouldPruneOrphanedFiles: false)
        }

        guard let data = try? Data(contentsOf: indexFile),
              let entries = try? JSONDecoder().decode([ScreenshotHistoryIndexEntry].self, from: data),
              verify(entries) else {
            let protectedIDs = artifactIDs()
            let rebuiltEntries = rebuildEntries()
            if quarantineCorruptIndex(), saveRecoveryProtectedIDs(protectedIDs) {
                _ = save(rebuiltEntries)
            }
            return ScreenshotHistoryIndexStartup(state: .corrupt, entries: rebuiltEntries, shouldPruneOrphanedFiles: false)
        }

        return ScreenshotHistoryIndexStartup(state: .valid, entries: entries, shouldPruneOrphanedFiles: true)
    }

    @discardableResult
    func save(_ entries: [ScreenshotHistoryIndexEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        do {
            try data.write(to: indexFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func isOrphanedArtifact(named name: String, validIDs: Set<String>) -> Bool {
        if name == indexFile.lastPathComponent { return false }
        guard name.count >= 36 else { return false }
        let id = String(name.prefix(36))
        guard UUID(uuidString: id) != nil else { return false }
        guard let protectedIDs = recoveryProtectedIDs() else { return false }
        if protectedIDs.contains(id) { return false }
        return !validIDs.contains(id)
    }

    private func verify(_ entries: [ScreenshotHistoryIndexEntry]) -> Bool {
        var ids = Set<String>()
        for entry in entries {
            guard UUID(uuidString: entry.id) != nil,
                  Self.supportedImageExtensions.contains(entry.fileExtension.lowercased()),
                  ids.insert(entry.id).inserted else {
                return false
            }
        }
        return true
    }

    private func quarantineCorruptIndex() -> Bool {
        let quarantineFile = historyDirectory.appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
        do {
            try fileManager.moveItem(at: indexFile, to: quarantineFile)
            return true
        } catch {
            return false
        }
    }

    private func artifactIDs() -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        return Set(names.compactMap { name in
            guard name.count >= 36 else { return nil }
            let id = String(name.prefix(36))
            return UUID(uuidString: id) == nil ? nil : id
        })
    }

    /// IDs found during corrupt-index recovery stay protected across later launches.
    /// A damaged protection file fails closed: orphan pruning is disabled rather than
    /// risking a second round of data loss.
    private func recoveryProtectedIDs() -> Set<String>? {
        guard fileManager.fileExists(atPath: recoveryProtectionFile.path) else { return [] }
        guard let data = try? Data(contentsOf: recoveryProtectionFile),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data),
              ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { return nil }
        return ids
    }

    private func saveRecoveryProtectedIDs(_ ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return true }
        let existing = recoveryProtectedIDs() ?? []
        guard let data = try? JSONEncoder().encode(existing.union(ids)) else { return false }
        do {
            try data.write(to: recoveryProtectionFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func rebuildEntries() -> [ScreenshotHistoryIndexEntry] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return files.compactMap { file in
            let fileExtension = file.pathExtension.lowercased()
            let id = file.deletingPathExtension().lastPathComponent
            guard Self.supportedImageExtensions.contains(fileExtension), UUID(uuidString: id) != nil else { return nil }

            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let timestamp = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let rawFile = historyDirectory.appendingPathComponent("\(id)_raw.png")
            let annotationsFile = historyDirectory.appendingPathComponent("\(id)_annotations.json")
            let editFile = historyDirectory.appendingPathComponent("\(id)_edit.json")
            let hasAnnotations = fileManager.fileExists(atPath: rawFile.path) && (
                fileManager.fileExists(atPath: annotationsFile.path) || fileManager.fileExists(atPath: editFile.path)
            )
            let editValues = try? editFile.resourceValues(forKeys: [.contentModificationDateKey])

            return ScreenshotHistoryIndexEntry(
                id: id,
                fileExtension: fileExtension,
                timestamp: timestamp,
                pixelWidth: 0,
                pixelHeight: 0,
                hasAnnotations: hasAnnotations ? true : nil,
                lastEditedAt: editValues?.contentModificationDate
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}
