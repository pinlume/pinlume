import Foundation

struct TranslationRequestToken: Equatable {
    fileprivate let value: UUID
}

/// Invalidates stale translation completions whenever a window closes, a new
/// request starts, or the user changes target language.
struct TranslationRequestGeneration {
    private var activeToken: TranslationRequestToken?

    mutating func begin() -> TranslationRequestToken {
        let token = TranslationRequestToken(value: UUID())
        activeToken = token
        return token
    }

    mutating func invalidate() {
        activeToken = nil
    }

    func contains(_ token: TranslationRequestToken) -> Bool {
        token == activeToken
    }
}

/// Provider and timeout paths may race. This gate makes the public completion
/// contract exactly-once without requiring every provider to coordinate.
final class TranslationCompletionGate {
    private let lock = NSLock()
    private var completed = false
    private let completion: (Result<[String], Error>) -> Void

    init(_ completion: @escaping (Result<[String], Error>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(result)
    }
}
