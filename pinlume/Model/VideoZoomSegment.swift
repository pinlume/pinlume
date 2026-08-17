import Foundation
import CoreGraphics

enum VideoZoomMode: String, Codable, Sendable {
    case fixed
    case followMouse
}

enum VideoZoomMouseExitBehavior: String, Codable, Sendable {
    case holdLastPosition
    case restoreOriginal
}

/// A timeline region where the rendered video zooms into a chosen point.
///
/// - `startTime` / `endTime` are in seconds, relative to the full (untrimmed)
///   source asset. Export code clips these to the active trim range.
/// - `zoomLevel` is a multiplier: 1.0 = no zoom, 2.0 = 2x magnification.
/// - `center` is normalized to the source video's natural (non-transformed)
///   bounds: (0, 0) = top-left, (1, 1) = bottom-right. The current UI keeps it
///   at (0.5, 0.5) and the transform clamps to valid translations.
/// - `fadeIn` / `fadeOut` are the transition ramp durations at each edge.
///   Clamped so they never exceed half the segment.
final class VideoZoomSegment: Codable {

    static let minDuration: Double = 0.3
    /// Target fade duration for a generously long segment. For shorter
    /// segments we auto-scale down so the plateau always dominates.
    static let defaultFade: Double = 0.75
    static let minZoom: CGFloat = 1.2
    static let maxZoom: CGFloat = 5.0

    /// Returns the fade duration auto-scaled so the combined in+out fades
    /// never exceed ~40 % of the segment, preserving a visible plateau.
    static func autoFade(for duration: Double) -> Double {
        // One fade (in or out) max length: 20 % of total, capped at defaultFade.
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var zoomLevel: CGFloat
    var center: CGPoint
    var fadeIn: Double
    var fadeOut: Double
    var mode: VideoZoomMode
    var mouseExitBehavior: VideoZoomMouseExitBehavior

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         zoomLevel: CGFloat = 2.0,
         center: CGPoint = CGPoint(x: 0.5, y: 0.5),
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade,
         mode: VideoZoomMode = .fixed,
         mouseExitBehavior: VideoZoomMouseExitBehavior = .restoreOriginal) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.zoomLevel = zoomLevel
        self.center = center
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.mode = mode
        self.mouseExitBehavior = mouseExitBehavior
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, zoomLevel, center, fadeIn, fadeOut
        case mode, mouseExitBehavior
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decode(Double.self, forKey: .endTime)
        zoomLevel = try container.decode(CGFloat.self, forKey: .zoomLevel)
        center = try container.decode(CGPoint.self, forKey: .center)
        fadeIn = try container.decode(Double.self, forKey: .fadeIn)
        fadeOut = try container.decode(Double.self, forKey: .fadeOut)
        mode = try container.decodeIfPresent(VideoZoomMode.self, forKey: .mode) ?? .fixed
        mouseExitBehavior = try container.decodeIfPresent(
            VideoZoomMouseExitBehavior.self, forKey: .mouseExitBehavior) ?? .restoreOriginal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(zoomLevel, forKey: .zoomLevel)
        try container.encode(center, forKey: .center)
        try container.encode(fadeIn, forKey: .fadeIn)
        try container.encode(fadeOut, forKey: .fadeOut)
        try container.encode(mode, forKey: .mode)
        try container.encode(mouseExitBehavior, forKey: .mouseExitBehavior)
    }

    var duration: Double { max(0, endTime - startTime) }

    /// Effective fade duration — honors the user's fadeIn/fadeOut but always
    /// clamps to half the segment so there's at least one plateau frame.
    /// Never exceeds duration/2 (otherwise in+out would overlap).
    var effectiveFadeIn: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeIn, 0), cap)
    }
    var effectiveFadeOut: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeOut, 0), cap)
    }

    /// Interpolated zoom level at time `t` (in seconds, source-asset clock).
    /// Returns 1.0 outside the segment.
    func zoomLevel(at t: Double) -> CGFloat {
        guard t >= startTime, t <= endTime, duration > 0 else { return 1.0 }
        let fIn = effectiveFadeIn
        let fOut = effectiveFadeOut
        let into = t - startTime
        let toEnd = endTime - t

        if into < fIn, fIn > 0 {
            let p = into / fIn
            return 1.0 + (zoomLevel - 1.0) * easeInOut(CGFloat(p))
        } else if toEnd < fOut, fOut > 0 {
            let p = toEnd / fOut
            return 1.0 + (zoomLevel - 1.0) * easeInOut(CGFloat(p))
        } else {
            return zoomLevel
        }
    }

    /// Smoothstep / cubic ease for zoom ramps. Input and output on [0, 1].
    private func easeInOut(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    /// Translation (in video-pixel space) that places `center` at the visible
    /// center when applying `scale(zoom).translate(tx, ty)` to a frame of
    /// `videoSize`. Clamped so the zoom window never shows area outside the
    /// video's bounds (no black bars at edges from over-pan).
    func translation(zoom: CGFloat, videoSize: CGSize) -> CGPoint {
        guard zoom > 1.0001 else { return .zero }
        // Pixel coords of the chosen center
        let cx = center.x * videoSize.width
        let cy = center.y * videoSize.height
        // Amount to shift so that (cx, cy) lands at the center of the output
        let rawTx = videoSize.width / 2 - cx
        let rawTy = videoSize.height / 2 - cy
        // After zoom, max allowed translation is the distance from center to
        // the edge of the scaled content minus half the output.
        let maxTx = (zoom - 1) * videoSize.width / (2 * zoom)
        let maxTy = (zoom - 1) * videoSize.height / (2 * zoom)
        let clampedTx = min(max(rawTx, -maxTx), maxTx)
        let clampedTy = min(max(rawTy, -maxTy), maxTy)
        return CGPoint(x: clampedTx, y: clampedTy)
    }

    /// Whether this segment's time range overlaps another. Touching endpoints
    /// do not count as overlap.
    func overlaps(_ other: VideoZoomSegment) -> Bool {
        return startTime < other.endTime && endTime > other.startTime
    }
}

/// Value-only copy handed to background preview/export rendering.
struct VideoZoomRenderSnapshot: Sendable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let zoomLevel: CGFloat
    let center: CGPoint
    let fadeIn: Double
    let fadeOut: Double
    let mode: VideoZoomMode
    let mouseExitBehavior: VideoZoomMouseExitBehavior

    init(segment: VideoZoomSegment) {
        id = segment.id
        startTime = segment.startTime
        endTime = segment.endTime
        zoomLevel = segment.zoomLevel
        center = segment.center
        fadeIn = segment.fadeIn
        fadeOut = segment.fadeOut
        mode = segment.mode
        mouseExitBehavior = segment.mouseExitBehavior
    }

    var duration: Double { max(0, endTime - startTime) }

    private var effectiveFadeIn: Double {
        min(max(fadeIn, 0), max(0, duration / 2 - 0.001))
    }

    private var effectiveFadeOut: Double {
        min(max(fadeOut, 0), max(0, duration / 2 - 0.001))
    }

    func level(at time: Double) -> CGFloat {
        guard time >= startTime, time <= endTime, duration > 0 else { return 1 }
        let elapsed = time - startTime
        let remaining = endTime - time
        if effectiveFadeIn > 0, elapsed < effectiveFadeIn {
            return 1 + (zoomLevel - 1) * Self.ease(CGFloat(elapsed / effectiveFadeIn))
        }
        if effectiveFadeOut > 0, remaining < effectiveFadeOut {
            return 1 + (zoomLevel - 1) * Self.ease(CGFloat(remaining / effectiveFadeOut))
        }
        return zoomLevel
    }

    func translation(zoom: CGFloat, center: CGPoint, videoSize: CGSize) -> CGPoint {
        guard zoom > 1.0001 else { return .zero }
        let rawTx = videoSize.width / 2 - center.x * videoSize.width
        let rawTy = videoSize.height / 2 - center.y * videoSize.height
        let maxTx = (zoom - 1) * videoSize.width / (2 * zoom)
        let maxTy = (zoom - 1) * videoSize.height / (2 * zoom)
        return CGPoint(x: min(max(rawTx, -maxTx), maxTx),
                       y: min(max(rawTy, -maxTy), maxTy))
    }

    fileprivate static func ease(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct VideoZoomResolvedState: Equatable, Sendable {
    let zoomLevel: CGFloat
    let center: CGPoint
    let translation: CGPoint
}

enum VideoZoomResolver {
    private static let mouseExitGraceDuration: Double = 0.3

    static func resolve(at time: Double,
                        segments: [VideoZoomRenderSnapshot],
                        trajectory: VideoMouseTrajectory?,
                        videoSize: CGSize) -> VideoZoomResolvedState? {
        guard let segment = segments.first(where: {
            time >= $0.startTime && time <= $0.endTime && $0.duration > 0
        }) else { return nil }

        var center = segment.center
        var presence: CGFloat = 1
        if segment.mode == .followMouse, let cursor = trajectory?.state(at: time) {
            center = cursor.isInside ? cursor.point : (cursor.lastInsidePoint ?? segment.center)
            if segment.mouseExitBehavior == .restoreOriginal {
                if cursor.isInside {
                    if cursor.stateBeganAt <= segment.startTime {
                        presence = 1
                    } else {
                        let outsideDuration = cursor.precedingStateDuration ?? .infinity
                        let fadedBeforeEntry = max(0, outsideDuration - mouseExitGraceDuration)
                        let presenceAtEntry = 1 - transitionPresence(
                            elapsed: fadedBeforeEntry,
                            duration: segment.fadeOut)
                        let reentryProgress = transitionPresence(
                            elapsed: time - cursor.stateBeganAt,
                            duration: segment.fadeIn)
                        presence = presenceAtEntry + (1 - presenceAtEntry) * reentryProgress
                    }
                } else {
                    if cursor.stateBeganAt <= segment.startTime {
                        presence = 0
                    } else {
                        presence = 1 - transitionPresence(
                            elapsed: time - cursor.stateBeganAt - mouseExitGraceDuration,
                            duration: segment.fadeOut)
                    }
                }
            }
        }

        let segmentLevel = segment.level(at: time)
        let resolvedLevel = 1 + (segmentLevel - 1) * presence
        return VideoZoomResolvedState(
            zoomLevel: resolvedLevel,
            center: center,
            translation: segment.translation(zoom: resolvedLevel,
                                             center: center,
                                             videoSize: videoSize))
    }

    private static func transitionPresence(elapsed: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 1 }
        return VideoZoomRenderSnapshot.ease(CGFloat(elapsed / duration))
    }
}
