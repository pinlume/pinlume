import Foundation

enum ScrollCaptureLifecycleState: Equatable { case idle, starting, active, stopping }

struct ScrollCaptureLifecycle {
    private(set) var state: ScrollCaptureLifecycleState = .idle
    private(set) var generation: UInt = 0

    mutating func start() -> UInt? {
        guard state == .idle else { return nil }
        generation &+= 1
        state = .starting
        return generation
    }

    mutating func activate(generation: UInt) -> Bool {
        guard self.generation == generation, state == .starting else { return false }
        state = .active
        return true
    }

    func acceptsActive(generation: UInt) -> Bool {
        self.generation == generation && state == .active
    }

    mutating func stop() -> UInt? {
        guard state == .starting || state == .active else { return nil }
        state = .stopping
        return generation
    }

    mutating func finish(generation: UInt) -> Bool {
        guard self.generation == generation, state == .stopping else { return false }
        state = .idle
        return true
    }
}
