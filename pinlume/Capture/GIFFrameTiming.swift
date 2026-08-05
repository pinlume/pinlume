import Foundation

/// Selects GIF frames from their media presentation timestamps, not from a
/// guessed source frame rate. It also supplies the delay for the previous
/// selected frame, preserving variable-frame-rate pacing.
struct GIFFrameTiming {
    enum Error: Swift.Error {
        case invalidTimestamp
        case nonMonotonicTimestamp
    }

    private let minimumInterval: Double
    private var lastObservedTime: Double?
    private var lastSelectedTime: Double?
    private var nextSelectionTime: Double?

    static func targetFPS(nominalFrameRate: Double) -> Int {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else { return 15 }
        return max(1, min(15, Int(nominalFrameRate.rounded())))
    }

    init(fps: Int) {
        let normalizedFPS = fps > 0 ? min(fps, 15) : 15
        minimumInterval = 1.0 / Double(normalizedFPS)
    }

    mutating func shouldSelect(presentationTime: Double) throws -> Bool {
        guard presentationTime.isFinite, presentationTime >= 0 else { throw Error.invalidTimestamp }
        if let lastObservedTime, presentationTime < lastObservedTime {
            throw Error.nonMonotonicTimestamp
        }
        lastObservedTime = presentationTime

        guard var nextSelectionTime else {
            self.lastSelectedTime = presentationTime
            self.nextSelectionTime = presentationTime + minimumInterval
            return true
        }
        guard presentationTime + 1e-9 >= nextSelectionTime else { return false }
        repeat {
            nextSelectionTime += minimumInterval
        } while presentationTime + 1e-9 >= nextSelectionTime
        self.nextSelectionTime = nextSelectionTime
        self.lastSelectedTime = presentationTime
        return true
    }

    func delay(from previous: Double, to next: Double) throws -> Float {
        guard next.isFinite, next > previous else { throw Error.nonMonotonicTimestamp }
        return Float(next - previous)
    }

    func trailingDelay(finalPresentationTime: Double) throws -> Float {
        guard finalPresentationTime.isFinite, let lastSelectedTime,
              finalPresentationTime > lastSelectedTime else {
            throw Error.invalidTimestamp
        }
        return Float(finalPresentationTime - lastSelectedTime)
    }
}
