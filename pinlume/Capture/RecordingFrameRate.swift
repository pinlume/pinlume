import Foundation

enum RecordingFrameRate {
    static func effectiveFPS(requested: Int, displayRefreshRate: Double?) -> Int {
        guard let displayRefreshRate, displayRefreshRate > 0 else { return requested }
        return min(requested, Int(displayRefreshRate.rounded()))
    }
}
