import Foundation
import CoreGraphics

enum VideoEffectKind {
    case zoom
    case censor
    case text
    case cut
    case speed
    case freeze
}

struct VideoEffectInterval: Equatable {
    let startTime: Double
    let endTime: Double
}

struct VideoEffectPlacement: Equatable {
    let startTime: Double
    let endTime: Double
}

enum VideoEffectCreatedSegment {
    case zoom(VideoZoomSegment)
    case censor(VideoCensorSegment)
    case text(VideoTextSegment)
    case cut(VideoCutSegment)
    case speed(VideoSpeedSegment)
    case freeze(VideoFreezeSegment)
}

enum VideoEffectClipboardPayload {
    struct ZoomSnapshot {
        let id: UUID
        let startTime: Double
        let endTime: Double
        let zoomLevel: CGFloat
        let center: CGPoint
        let fadeInDuration: Double
        let fadeOutDuration: Double
        let mode: VideoZoomMode
        let mouseExitBehavior: VideoZoomMouseExitBehavior
    }

    struct CensorSnapshot {
        let id: UUID
        let startTime: Double
        let endTime: Double
        let rect: CGRect
        let style: VideoCensorSegment.Style
        let fadeInDuration: Double
        let fadeOutDuration: Double
    }

    struct TextSnapshot {
        let id: UUID
        let startTime: Double
        let endTime: Double
        let rect: CGRect
        let text: String
        let fontSize: CGFloat
        let isBold: Bool
        let isItalic: Bool
        let textColor: VideoTextSegment.RGBA
        let backgroundStyle: VideoTextSegment.BackgroundStyle
        let backgroundColor: VideoTextSegment.RGBA
        let alignment: VideoTextSegment.Alignment
        let fadeInDuration: Double
        let fadeOutDuration: Double
    }

    struct CutSnapshot {
        let id: UUID
        let startTime: Double
        let endTime: Double
    }

    struct SpeedSnapshot {
        let id: UUID
        let startTime: Double
        let endTime: Double
        let factor: Double
    }

    struct FreezeSnapshot {
        let id: UUID
        let atTime: Double
        let holdDuration: Double
    }

    case zoom(ZoomSnapshot)
    case censor(CensorSnapshot)
    case text(TextSnapshot)
    case cut(CutSnapshot)
    case speed(SpeedSnapshot)
    case freeze(FreezeSnapshot)

    init(zoom: VideoZoomSegment) {
        self = .zoom(ZoomSnapshot(
            id: zoom.id,
            startTime: zoom.startTime,
            endTime: zoom.endTime,
            zoomLevel: zoom.zoomLevel,
            center: zoom.center,
            fadeInDuration: zoom.fadeIn,
            fadeOutDuration: zoom.fadeOut,
            mode: zoom.mode,
            mouseExitBehavior: zoom.mouseExitBehavior
        ))
    }

    init(censor: VideoCensorSegment) {
        self = .censor(CensorSnapshot(
            id: censor.id,
            startTime: censor.startTime,
            endTime: censor.endTime,
            rect: censor.rect,
            style: censor.style,
            fadeInDuration: censor.fadeIn,
            fadeOutDuration: censor.fadeOut
        ))
    }

    init(text: VideoTextSegment) {
        self = .text(TextSnapshot(
            id: text.id,
            startTime: text.startTime,
            endTime: text.endTime,
            rect: text.rect,
            text: text.text,
            fontSize: text.fontSize,
            isBold: text.bold,
            isItalic: text.italic,
            textColor: text.textColor,
            backgroundStyle: text.bgStyle,
            backgroundColor: text.bgColor,
            alignment: text.alignment,
            fadeInDuration: text.fadeIn,
            fadeOutDuration: text.fadeOut
        ))
    }

    init(cut: VideoCutSegment) {
        self = .cut(CutSnapshot(id: cut.id, startTime: cut.startTime, endTime: cut.endTime))
    }

    init(speed: VideoSpeedSegment) {
        self = .speed(SpeedSnapshot(
            id: speed.id,
            startTime: speed.startTime,
            endTime: speed.endTime,
            factor: speed.speedFactor
        ))
    }

    init(freeze: VideoFreezeSegment) {
        self = .freeze(FreezeSnapshot(
            id: freeze.id,
            atTime: freeze.atTime,
            holdDuration: freeze.holdDuration
        ))
    }

    var kind: VideoEffectKind {
        switch self {
        case .zoom: return .zoom
        case .censor: return .censor
        case .text: return .text
        case .cut: return .cut
        case .speed: return .speed
        case .freeze: return .freeze
        }
    }

    var sourceID: UUID {
        switch self {
        case .zoom(let snapshot): return snapshot.id
        case .censor(let snapshot): return snapshot.id
        case .text(let snapshot): return snapshot.id
        case .cut(let snapshot): return snapshot.id
        case .speed(let snapshot): return snapshot.id
        case .freeze(let snapshot): return snapshot.id
        }
    }

    var sourceStartTime: Double {
        switch self {
        case .zoom(let snapshot): return snapshot.startTime
        case .censor(let snapshot): return snapshot.startTime
        case .text(let snapshot): return snapshot.startTime
        case .cut(let snapshot): return snapshot.startTime
        case .speed(let snapshot): return snapshot.startTime
        case .freeze(let snapshot): return snapshot.atTime
        }
    }

    var sourceEndTime: Double {
        switch self {
        case .zoom(let snapshot): return snapshot.endTime
        case .censor(let snapshot): return snapshot.endTime
        case .text(let snapshot): return snapshot.endTime
        case .cut(let snapshot): return snapshot.endTime
        case .speed(let snapshot): return snapshot.endTime
        case .freeze(let snapshot): return snapshot.atTime
        }
    }

    var duration: Double {
        max(0, sourceEndTime - sourceStartTime)
    }

    var requiresExclusiveRange: Bool {
        switch kind {
        case .zoom, .speed: return true
        case .censor, .text, .cut, .freeze: return false
        }
    }

    func makeSegment(id: UUID = UUID(), placement: VideoEffectPlacement) -> VideoEffectCreatedSegment {
        switch self {
        case .zoom(let snapshot):
            let segment = VideoZoomSegment(
                id: id,
                startTime: placement.startTime,
                endTime: placement.endTime,
                zoomLevel: snapshot.zoomLevel,
                center: snapshot.center,
                fadeIn: snapshot.fadeInDuration,
                fadeOut: snapshot.fadeOutDuration,
                mode: snapshot.mode,
                mouseExitBehavior: snapshot.mouseExitBehavior
            )
            return .zoom(segment)
        case .censor(let snapshot):
            let segment = VideoCensorSegment(
                id: id,
                startTime: placement.startTime,
                endTime: placement.endTime,
                rect: snapshot.rect,
                style: snapshot.style,
                fadeIn: snapshot.fadeInDuration,
                fadeOut: snapshot.fadeOutDuration
            )
            return .censor(segment)
        case .text(let snapshot):
            let segment = VideoTextSegment(
                id: id,
                startTime: placement.startTime,
                endTime: placement.endTime,
                rect: snapshot.rect,
                text: snapshot.text,
                fontSize: snapshot.fontSize,
                bold: snapshot.isBold,
                italic: snapshot.isItalic,
                textColor: snapshot.textColor,
                bgStyle: snapshot.backgroundStyle,
                bgColor: snapshot.backgroundColor,
                alignment: snapshot.alignment,
                fadeIn: snapshot.fadeInDuration,
                fadeOut: snapshot.fadeOutDuration
            )
            return .text(segment)
        case .cut:
            return .cut(VideoCutSegment(id: id, startTime: placement.startTime, endTime: placement.endTime))
        case .speed(let snapshot):
            return .speed(VideoSpeedSegment(
                id: id,
                startTime: placement.startTime,
                endTime: placement.endTime,
                speedFactor: snapshot.factor
            ))
        case .freeze(let snapshot):
            return .freeze(VideoFreezeSegment(
                id: id,
                atTime: placement.startTime,
                holdDuration: snapshot.holdDuration
            ))
        }
    }
}

enum VideoEffectPlacementResolver {
    static func resolve(
        payload: VideoEffectClipboardPayload,
        timelineDuration: Double,
        mouseTime: Double?,
        playheadTime: Double,
        occupied: [VideoEffectInterval]
    ) -> VideoEffectPlacement? {
        let timelineDuration = max(0, timelineDuration)
        let duration = payload.duration
        guard duration <= timelineDuration else { return nil }

        let effectiveOccupied = payload.requiresExclusiveRange
            ? normalizedIntervals(occupied, timelineDuration: timelineDuration)
            : []

        if duration <= 0.000_001 {
            for time in [mouseTime, playheadTime, payload.sourceEndTime].compactMap({ $0 }) {
                if time >= 0, time <= timelineDuration {
                    return VideoEffectPlacement(startTime: time, endTime: time)
                }
            }
            return VideoEffectPlacement(startTime: 0, endTime: 0)
        }

        var primaryAnchors: [Double] = []
        if let mouseTime, mouseTime >= 0, mouseTime <= timelineDuration {
            primaryAnchors.append(mouseTime)
        }
        primaryAnchors.append(min(max(0, playheadTime), timelineDuration))

        for anchor in primaryAnchors {
            if let right = placementToRight(
                of: anchor,
                duration: duration,
                timelineDuration: timelineDuration,
                occupied: effectiveOccupied
            ) {
                return right
            }
            if let left = placementEndingAtOrBefore(
                anchor,
                duration: duration,
                timelineDuration: timelineDuration,
                occupied: effectiveOccupied
            ) {
                return left
            }
        }

        return placementToRight(
            of: payload.sourceEndTime,
            duration: duration,
            timelineDuration: timelineDuration,
            occupied: effectiveOccupied
        )
    }

    static func isValid(
        payload: VideoEffectClipboardPayload,
        placement: VideoEffectPlacement,
        timelineDuration: Double,
        occupied: [VideoEffectInterval]
    ) -> Bool {
        guard placement.startTime >= 0,
              placement.endTime >= placement.startTime,
              placement.endTime <= timelineDuration,
              abs((placement.endTime - placement.startTime) - payload.duration) < 0.000_001 else {
            return false
        }
        guard payload.requiresExclusiveRange else { return true }
        return isFree(placement, occupied: normalizedIntervals(occupied, timelineDuration: timelineDuration))
    }

    private static func placementToRight(
        of anchor: Double,
        duration: Double,
        timelineDuration: Double,
        occupied: [VideoEffectInterval]
    ) -> VideoEffectPlacement? {
        let placement = VideoEffectPlacement(startTime: anchor, endTime: anchor + duration)
        guard placement.endTime <= timelineDuration, isFree(placement, occupied: occupied) else { return nil }
        return placement
    }

    private static func placementEndingAtOrBefore(
        _ anchor: Double,
        duration: Double,
        timelineDuration: Double,
        occupied: [VideoEffectInterval]
    ) -> VideoEffectPlacement? {
        let gaps = freeIntervals(timelineDuration: timelineDuration, occupied: occupied)
        for gap in gaps.reversed() {
            let end = min(anchor, gap.endTime)
            let start = end - duration
            if start >= gap.startTime, start >= 0 {
                return VideoEffectPlacement(startTime: start, endTime: end)
            }
        }
        return nil
    }

    private static func isFree(_ placement: VideoEffectPlacement, occupied: [VideoEffectInterval]) -> Bool {
        !occupied.contains { placement.startTime < $0.endTime && placement.endTime > $0.startTime }
    }

    private static func normalizedIntervals(
        _ intervals: [VideoEffectInterval],
        timelineDuration: Double
    ) -> [VideoEffectInterval] {
        let sorted = intervals.compactMap { interval -> VideoEffectInterval? in
            let start = min(max(0, interval.startTime), timelineDuration)
            let end = min(max(0, interval.endTime), timelineDuration)
            guard end > start else { return nil }
            return VideoEffectInterval(startTime: start, endTime: end)
        }.sorted { $0.startTime < $1.startTime }

        var merged: [VideoEffectInterval] = []
        for interval in sorted {
            guard let last = merged.last, interval.startTime <= last.endTime else {
                merged.append(interval)
                continue
            }
            merged[merged.count - 1] = VideoEffectInterval(
                startTime: last.startTime,
                endTime: max(last.endTime, interval.endTime)
            )
        }
        return merged
    }

    private static func freeIntervals(
        timelineDuration: Double,
        occupied: [VideoEffectInterval]
    ) -> [VideoEffectInterval] {
        var result: [VideoEffectInterval] = []
        var cursor = 0.0
        for interval in occupied {
            if interval.startTime > cursor {
                result.append(VideoEffectInterval(startTime: cursor, endTime: interval.startTime))
            }
            cursor = max(cursor, interval.endTime)
        }
        if cursor < timelineDuration {
            result.append(VideoEffectInterval(startTime: cursor, endTime: timelineDuration))
        }
        return result
    }
}

struct VideoEffectPasteRecord {
    let payload: VideoEffectClipboardPayload
    let placement: VideoEffectPlacement
    let id: UUID
}
