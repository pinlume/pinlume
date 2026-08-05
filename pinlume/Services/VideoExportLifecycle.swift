import Foundation

/// Small, explicit state machine shared by video export paths. Keeping the
/// transition separate from AppKit makes duplicate AVFoundation callbacks and
/// close/cancel races harmless.
struct VideoExportLifecycle: Equatable {
    enum State: Equatable {
        case idle
        case exporting
        case cancelling
        case finished
        case cancelled
    }

    private(set) var state: State = .idle

    mutating func begin() -> Bool {
        guard state == .idle else { return false }
        state = .exporting
        return true
    }

    mutating func finishOnce() -> Bool {
        guard state == .exporting else { return false }
        state = .finished
        return true
    }

    mutating func cancelOnce() -> Bool {
        guard state == .exporting else { return false }
        state = .cancelling
        return true
    }

    mutating func finishCancellationOnce() -> Bool {
        guard state == .cancelling else { return false }
        state = .cancelled
        return true
    }
}
