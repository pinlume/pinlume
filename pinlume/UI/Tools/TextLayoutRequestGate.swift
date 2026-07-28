import Foundation

/// Coalesces live text-layout work until TextKit has finished its current
/// storage edit transaction. This type is main-actor confined because the
/// scheduled work always mutates AppKit views.
@MainActor
final class TextLayoutRequestGate {
    typealias Work = @MainActor () -> Void
    typealias Scheduler = (@escaping Work) -> Void

    private let schedule: Scheduler
    private var sessionID: UInt = 0
    private var pendingSessionID: UInt?

    init(schedule: @escaping Scheduler = { work in
        DispatchQueue.main.async {
            work()
        }
    }) {
        self.schedule = schedule
    }

    @discardableResult
    func beginSession() -> UInt {
        sessionID &+= 1
        pendingSessionID = nil
        return sessionID
    }

    func invalidate() {
        sessionID &+= 1
        pendingSessionID = nil
    }

    func request(in requestedSessionID: UInt, perform: @escaping Work) {
        guard requestedSessionID == sessionID,
              pendingSessionID != requestedSessionID else { return }
        pendingSessionID = requestedSessionID

        schedule { [weak self] in
            guard let self,
                  self.sessionID == requestedSessionID,
                  self.pendingSessionID == requestedSessionID else { return }
            self.pendingSessionID = nil
            perform()
        }
    }
}
