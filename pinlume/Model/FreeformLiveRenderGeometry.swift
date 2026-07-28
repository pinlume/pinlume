import AppKit

/// Geometry shared by the pin-only live freeform redraw path.
/// Persistent rendering still draws the complete annotation.
enum FreeformLiveRenderGeometry {
    static func dirtyRect(
        from start: NSPoint,
        to end: NSPoint,
        effectiveWidth: CGFloat,
        extraPadding: CGFloat = 3
    ) -> NSRect {
        let padding = max(0, effectiveWidth) / 2 + max(0, extraPadding)
        return NSRect(
            x: min(start.x, end.x) - padding,
            y: min(start.y, end.y) - padding,
            width: abs(end.x - start.x) + padding * 2,
            height: abs(end.y - start.y) + padding * 2
        )
    }

    /// Returns contiguous point ranges whose line segments can affect `clipRect`.
    /// Each range contains both endpoints so line joins remain intact.
    static func intersectingPointRanges(
        points: [NSPoint],
        clipRect: NSRect,
        strokeRadius: CGFloat
    ) -> [Range<Int>] {
        guard points.count >= 2, !clipRect.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(2)
        var activeStart: Int?
        let padding = max(0, strokeRadius)

        for endIndex in 1..<points.count {
            let segmentRect = dirtyRect(
                from: points[endIndex - 1],
                to: points[endIndex],
                effectiveWidth: padding * 2,
                extraPadding: 0
            )
            if segmentRect.intersects(clipRect) {
                if activeStart == nil { activeStart = endIndex - 1 }
            } else if let start = activeStart {
                ranges.append(start..<endIndex)
                activeStart = nil
            }
        }

        if let start = activeStart {
            ranges.append(start..<points.count)
        }
        return ranges
    }
}
