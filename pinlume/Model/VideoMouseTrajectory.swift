import Foundation
import CoreGraphics

struct VideoMouseRawSample: Equatable, Sendable {
    let time: Double
    let point: CGPoint
    let isInside: Bool
}

/// Immutable, random-access cursor movement captured on the source asset clock.
/// Points are normalized to the recorded video with a top-left origin.
struct VideoMouseTrajectory: Sendable {

    struct State: Equatable, Sendable {
        let point: CGPoint
        let isInside: Bool
        let stateBeganAt: Double
        let precedingStateDuration: Double?
        let lastInsidePoint: CGPoint?
    }

    private struct Sample: Sendable {
        let time: Double
        let point: CGPoint
        let isInside: Bool
        let stateBeganAt: Double
        let precedingStateDuration: Double?
        let lastInsidePoint: CGPoint?
    }

    private let samples: [Sample]

    init?(rawSamples: [VideoMouseRawSample], smoothingResponse: Double = 0.15) {
        let ordered = rawSamples
            .filter { $0.time.isFinite && $0.point.x.isFinite && $0.point.y.isFinite }
            .sorted { $0.time < $1.time }
        guard let first = ordered.first else { return nil }

        let response = max(0.001, smoothingResponse)
        var processed: [Sample] = []
        processed.reserveCapacity(ordered.count)

        var previousTime = first.time
        var smoothedPoint = Self.clamp(first.point)
        var stateBeganAt = first.time
        var precedingStateDuration: Double?
        var previousInside = first.isInside
        var lastInsidePoint: CGPoint? = first.isInside ? smoothedPoint : nil
        processed.append(Sample(time: first.time,
                                point: smoothedPoint,
                                isInside: first.isInside,
                                stateBeganAt: stateBeganAt,
                                precedingStateDuration: precedingStateDuration,
                                lastInsidePoint: lastInsidePoint))

        for raw in ordered.dropFirst() where raw.time > previousTime {
            let delta = raw.time - previousTime
            if raw.isInside {
                let target = Self.clamp(raw.point)
                let alpha = CGFloat(1 - exp(-delta / response))
                smoothedPoint = CGPoint(
                    x: smoothedPoint.x + (target.x - smoothedPoint.x) * alpha,
                    y: smoothedPoint.y + (target.y - smoothedPoint.y) * alpha)
                lastInsidePoint = smoothedPoint
            }
            if raw.isInside != previousInside {
                precedingStateDuration = raw.time - stateBeganAt
                stateBeganAt = raw.time
            }
            processed.append(Sample(time: raw.time,
                                    point: smoothedPoint,
                                    isInside: raw.isInside,
                                    stateBeganAt: stateBeganAt,
                                    precedingStateDuration: precedingStateDuration,
                                    lastInsidePoint: lastInsidePoint))
            previousTime = raw.time
            previousInside = raw.isInside
        }
        self.samples = processed
    }

    static func rawSample(quartzPoint: CGPoint,
                          recordingRect: CGRect,
                          time: Double) -> VideoMouseRawSample {
        guard recordingRect.width > 0, recordingRect.height > 0 else {
            return VideoMouseRawSample(time: time, point: .zero, isInside: false)
        }
        let normalized = CGPoint(
            x: (quartzPoint.x - recordingRect.minX) / recordingRect.width,
            y: (quartzPoint.y - recordingRect.minY) / recordingRect.height)
        return VideoMouseRawSample(time: time,
                                   point: clamp(normalized),
                                   isInside: recordingRect.contains(quartzPoint))
    }

    func state(at time: Double) -> State? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return state(from: first) }
        if time >= last.time { return state(from: last) }

        var lower = 0
        var upper = samples.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time <= time {
                lower = middle
            } else {
                upper = middle
            }
        }

        let lhs = samples[lower]
        let rhs = samples[upper]
        let span = rhs.time - lhs.time
        let progress = span > 0 ? CGFloat((time - lhs.time) / span) : 0
        let point = CGPoint(x: lhs.point.x + (rhs.point.x - lhs.point.x) * progress,
                            y: lhs.point.y + (rhs.point.y - lhs.point.y) * progress)
        return State(point: point,
                     isInside: lhs.isInside,
                     stateBeganAt: lhs.stateBeganAt,
                     precedingStateDuration: lhs.precedingStateDuration,
                     lastInsidePoint: lhs.lastInsidePoint)
    }

    private func state(from sample: Sample) -> State {
        State(point: sample.point,
              isInside: sample.isInside,
              stateBeganAt: sample.stateBeganAt,
              precedingStateDuration: sample.precedingStateDuration,
              lastInsidePoint: sample.lastInsidePoint)
    }

    private static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1),
                y: min(max(point.y, 0), 1))
    }
}

/// Mutable only on RecordingEngine's serial recording queue, then converted
/// once into the immutable trajectory used by the editor and compositor.
final class VideoMouseTrajectoryCollector: @unchecked Sendable {
    private var samples: [VideoMouseRawSample] = []

    func append(_ sample: VideoMouseRawSample) {
        samples.append(sample)
    }

    func trajectory() -> VideoMouseTrajectory? {
        VideoMouseTrajectory(rawSamples: samples)
    }
}
