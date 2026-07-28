import Foundation

/// User preference and automatic quality policy for the live ScreenCaptureKit path.
///
/// The automatic choice is based on source pixels per second instead of display
/// model, size, scale factor, or a fixed monitor geometry. This keeps interactive
/// recording responsive on every Mac while retaining the existing high-quality
/// setting for lower-throughput recordings.
enum LiveRecordingQuality: String {
    case automatic
    case low
    case medium
    case high

    /// Above this source throughput, H.264 high quality can contend with
    /// WindowServer on systems whose hardware encoder has limited headroom.
    private static let highQualityPixelRateLimit = 150_000_000

    static func resolve(rawValue: String?, width: Int, height: Int, fps: Int) -> LiveRecordingQuality {
        if let rawValue, let requested = LiveRecordingQuality(rawValue: rawValue), requested != .automatic {
            return requested
        }

        let pixelRate = max(width, 0) * max(height, 0) * max(fps, 0)
        return pixelRate >= highQualityPixelRateLimit ? .medium : .high
    }
}
