#if !OFFLINE
import Foundation

/// Owns the terminal state of one selection-upload attempt. A token belongs
/// only to the generation that created it, so an older network completion can
/// never restore or close a newer selection session.
struct UploadOverlaySession {
    enum Phase: Equatable {
        case idle
        case confirming
        case uploading
        case presentingFailure
    }

    struct Token: Equatable {
        fileprivate let generation: UInt
    }

    private(set) var phase: Phase = .idle
    private var generation: UInt = 0

    mutating func begin() -> Token {
        generation &+= 1
        phase = .confirming
        return Token(generation: generation)
    }

    mutating func accept(_ token: Token) -> Bool {
        guard token.generation == generation, phase == .confirming else { return false }
        phase = .uploading
        return true
    }

    mutating func prepareFailure(_ token: Token) -> Bool {
        guard token.generation == generation,
              phase == .confirming || phase == .uploading
        else { return false }
        phase = .presentingFailure
        return true
    }

    mutating func restoreAfterFailure(_ token: Token) -> Bool {
        guard token.generation == generation, phase == .presentingFailure else { return false }
        phase = .idle
        return true
    }

    mutating func cancel(_ token: Token) -> Bool {
        guard token.generation == generation, phase == .confirming else { return false }
        phase = .idle
        return true
    }

    mutating func completeSuccess(_ token: Token) -> Bool {
        guard token.generation == generation, phase == .uploading else { return false }
        phase = .idle
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        phase = .idle
    }
}
#endif
