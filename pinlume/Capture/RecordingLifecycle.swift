import Foundation

enum RecordingLifecycleState: Equatable {
    case idle
    case countdown
    case starting
    case recording
    case paused
    case stopping
}

struct RecordingLifecycle {
    private(set) var state: RecordingLifecycleState = .idle
    private(set) var generation: UInt = 0

    mutating func beginCountdown() -> UInt? {
        guard state == .idle else { return nil }
        generation &+= 1
        state = .countdown
        return generation
    }

    mutating func beginStarting() -> UInt? {
        guard state == .idle else { return nil }
        generation &+= 1
        state = .starting
        return generation
    }

    mutating func markStarting(generation: UInt) -> Bool {
        guard self.generation == generation, state == .countdown else { return false }
        state = .starting
        return true
    }

    mutating func markRecording(generation: UInt) -> Bool {
        guard self.generation == generation, state == .starting else { return false }
        state = .recording
        return true
    }

    mutating func pause(generation: UInt) -> Bool {
        guard self.generation == generation, state == .recording else { return false }
        state = .paused
        return true
    }

    mutating func resume(generation: UInt) -> Bool {
        guard self.generation == generation, state == .paused else { return false }
        state = .recording
        return true
    }

    mutating func stop() -> UInt? {
        switch state {
        case .countdown:
            state = .idle
            return generation
        case .starting, .recording, .paused:
            state = .stopping
            return generation
        case .idle, .stopping:
            return nil
        }
    }

    mutating func complete(generation: UInt) -> Bool {
        guard self.generation == generation, state == .stopping else { return false }
        state = .idle
        return true
    }

    mutating func abort(generation: UInt) -> Bool {
        guard self.generation == generation else { return false }
        state = .idle
        return true
    }
}

enum RecordingCaptureDimensions {
    static func even(width: Int, height: Int) -> CGSize {
        CGSize(
            width: Double(max(2, width - width % 2)),
            height: Double(max(2, height - height % 2))
        )
    }
}

struct RecordingOutputReservation {
    let finalURL: URL
    let writerURL: URL
}

enum RecordingOutputURL {
    static func make(in directory: URL, baseName: String) -> RecordingOutputReservation? {
        guard let finalURL = try? TransactionalOutput.reserveUnique(
            in: directory,
            filename: "\(baseName).mp4") else { return nil }
        let writerURL = directory.appendingPathComponent(
            ".\(finalURL.lastPathComponent).writer-\(UUID().uuidString).mp4")
        return RecordingOutputReservation(finalURL: finalURL, writerURL: writerURL)
    }
}

enum RecordingDisplaySelection {
    static func target(requested: UInt32?, available: [UInt32]) -> UInt32? {
        guard let requested, available.contains(requested) else { return nil }
        return requested
    }
}
