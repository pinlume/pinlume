import Foundation

/// Thread-safe validity registry for history artifacts. A writer captures a
/// token before encoding and must recheck it immediately before touching disk.
final class HistoryArtifactLifecycle {
    private let lock = NSLock()
    private var generations: [String: UInt] = [:]
    private var tombstones: Set<String> = []

    func beginWrite(for id: String) -> UInt {
        lock.lock(); defer { lock.unlock() }
        let generation = (generations[id] ?? 0) &+ 1
        generations[id] = generation
        tombstones.remove(id)
        return generation
    }

    func tombstone(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        generations[id] = (generations[id] ?? 0) &+ 1
        tombstones.insert(id)
    }

    func isLive(id: String, generation: UInt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generations[id] == generation && !tombstones.contains(id)
    }
}
