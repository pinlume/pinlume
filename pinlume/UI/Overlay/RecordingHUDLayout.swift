import Cocoa

enum RecordingHUDLayout {
    private static let gap: CGFloat = 8
    private static let edgeInset: CGFloat = 4

    static func origin(
        hudSize: NSSize,
        recordingRect: NSRect,
        visibleFrame: NSRect?,
        avoiding: NSRect?
    ) -> NSPoint {
        let defaultOrigin = defaultOrigin(
            hudSize: hudSize,
            recordingRect: recordingRect,
            visibleFrame: visibleFrame
        )
        guard let visibleFrame,
              let avoiding,
              !avoiding.isEmpty,
              NSRect(origin: defaultOrigin, size: hudSize).intersects(avoiding)
        else {
            return defaultOrigin
        }

        let alignedY = clampedY(avoiding.minY, hudHeight: hudSize.height, in: visibleFrame)
        let centeredX = clampedX(avoiding.midX - hudSize.width / 2, hudWidth: hudSize.width, in: visibleFrame)
        let candidates = [
            NSPoint(x: avoiding.minX - hudSize.width - gap, y: alignedY),
            NSPoint(x: avoiding.maxX + gap, y: alignedY),
            NSPoint(x: centeredX, y: avoiding.maxY + gap),
            NSPoint(x: centeredX, y: avoiding.minY - hudSize.height - gap),
        ]

        for candidate in candidates {
            let frame = NSRect(origin: candidate, size: hudSize)
            if visibleFrame.contains(frame), !frame.intersects(avoiding) {
                return candidate
            }
        }
        return defaultOrigin
    }

    private static func defaultOrigin(
        hudSize: NSSize,
        recordingRect: NSRect,
        visibleFrame: NSRect?
    ) -> NSPoint {
        var origin = NSPoint(
            x: recordingRect.maxX - hudSize.width - gap,
            y: recordingRect.maxY + gap
        )
        guard let visibleFrame else { return origin }

        if origin.y + hudSize.height > visibleFrame.maxY {
            origin.y = recordingRect.minY - hudSize.height - gap
        }
        origin.x = clampedX(origin.x, hudWidth: hudSize.width, in: visibleFrame)
        origin.y = clampedY(origin.y, hudHeight: hudSize.height, in: visibleFrame)
        return origin
    }

    private static func clampedX(_ x: CGFloat, hudWidth: CGFloat, in visibleFrame: NSRect) -> CGFloat {
        max(visibleFrame.minX + edgeInset, min(x, visibleFrame.maxX - hudWidth - edgeInset))
    }

    private static func clampedY(_ y: CGFloat, hudHeight: CGFloat, in visibleFrame: NSRect) -> CGFloat {
        max(visibleFrame.minY + edgeInset, min(y, visibleFrame.maxY - hudHeight - edgeInset))
    }
}
