#if !OFFLINE
import Foundation

/// Local metadata for successful uploads. This never stores image bytes,
/// credentials, or a remote service response beyond the links already shown to
/// the user.
struct UploadHistoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let provider: String
    let link: String
    let deleteURL: String?
    let createdAt: Date
}

@MainActor
final class UploadHistoryStore {
    static let shared = UploadHistoryStore()

    static let maximumEntries = 100
    private static let storageKey = "uploadHistory"
    private static let legacyStorageKey = "imgbbUploads"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entries() -> [UploadHistoryEntry] {
        if let data = defaults.data(forKey: Self.storageKey),
           let entries = try? JSONDecoder().decode([UploadHistoryEntry].self, from: data) {
            return entries
        }

        let legacy = defaults.array(forKey: Self.legacyStorageKey) as? [[String: String]] ?? []
        return legacy.enumerated().compactMap { index, item in
            guard let link = item["link"], !link.isEmpty else { return nil }
            return UploadHistoryEntry(
                id: "legacy-\(index)",
                provider: "imgbb",
                link: link,
                deleteURL: item["deleteURL"],
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }

    func append(provider: String, link: String, deleteURL: String?) {
        var allEntries = entries()
        allEntries.append(UploadHistoryEntry(
            id: UUID().uuidString,
            provider: provider,
            link: link,
            deleteURL: deleteURL?.isEmpty == true ? nil : deleteURL,
            createdAt: Date()
        ))
        write(Array(allEntries.suffix(Self.maximumEntries)))
    }

    func remove(id: String) {
        write(entries().filter { $0.id != id })
    }

    func removeAll() {
        write([])
    }

    func removeAll(provider: String) {
        write(entries().filter { $0.provider != provider })
    }

    private func write(_ entries: [UploadHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: .uploadHistoryDidChange, object: self)
    }
}

extension Notification.Name {
    static let uploadHistoryDidChange = Notification.Name("uploadHistoryDidChange")
}
#endif
