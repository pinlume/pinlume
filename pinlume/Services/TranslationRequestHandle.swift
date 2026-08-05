import Foundation

final class TranslationRequestHandle {
    private let lock = NSLock()
    private var cancellationActions: [() -> Void] = []
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func registerCancellation(_ action: @escaping () -> Void) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            action()
            return false
        }
        cancellationActions.append(action)
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let actions = cancellationActions
        cancellationActions.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }

    func finish() {
        lock.lock()
        cancellationActions.removeAll()
        lock.unlock()
    }
}
