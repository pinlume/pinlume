import Foundation

/// Makes every way of dismissing the audio dialog converge on one callback.
struct AudioMergeCompletionGate {
    private var completed = false

    mutating func finishOnce() -> Bool {
        guard !completed else { return false }
        completed = true
        return true
    }
}
