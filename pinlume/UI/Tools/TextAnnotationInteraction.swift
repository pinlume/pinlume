import AppKit

enum TextAnnotationHitTarget: Equatable {
    case outside
    case interior
    case border
    case rotate
    case fontSize
}

struct TextAnnotationCorners {
    let topLeft: NSPoint
    let topRight: NSPoint
    let bottomRight: NSPoint
    let bottomLeft: NSPoint
}

struct TextAnnotationControlRects {
    let rotate: NSRect
    let fontSize: NSRect
}

struct TextAnnotationFrameSegment: Equatable {
    let start: NSPoint
    let end: NSPoint
}

enum TextAnnotationInteraction {
    static let controlVisualSize: CGFloat = 12
    static let controlHitSize: CGFloat = 24
    static let controlSize = controlVisualSize
    static let controlHitSlop = (controlHitSize - controlVisualSize) / 2
    static let requiredChromePadding = controlHitSize / 2
    static let borderOuterHitWidth: CGFloat = 6
    static let borderInnerHitWidth: CGFloat = 4
    static let hoverPadding: CGFloat = 6

    static func rotatedCorners(of rect: NSRect, rotation: CGFloat) -> TextAnnotationCorners {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return TextAnnotationCorners(
            topLeft: rotate(NSPoint(x: rect.minX, y: rect.maxY), around: center, by: rotation),
            topRight: rotate(NSPoint(x: rect.maxX, y: rect.maxY), around: center, by: rotation),
            bottomRight: rotate(NSPoint(x: rect.maxX, y: rect.minY), around: center, by: rotation),
            bottomLeft: rotate(NSPoint(x: rect.minX, y: rect.minY), around: center, by: rotation)
        )
    }

    static func controlRects(
        for rect: NSRect,
        rotation: CGFloat,
        size: CGFloat = controlSize
    ) -> TextAnnotationControlRects {
        let corners = rotatedCorners(of: rect, rotation: rotation)
        return TextAnnotationControlRects(
            rotate: centeredRect(at: corners.topRight, size: size),
            fontSize: centeredRect(at: corners.bottomRight, size: size)
        )
    }

    static func target(
        at point: NSPoint,
        rect: NSRect,
        rotation: CGFloat
    ) -> TextAnnotationHitTarget {
        guard rect.width > 0, rect.height > 0 else { return .outside }
        let controls = controlRects(for: rect, rotation: rotation)
        if controls.rotate.insetBy(dx: -controlHitSlop, dy: -controlHitSlop).contains(point) {
            return .rotate
        }
        if controls.fontSize.insetBy(dx: -controlHitSlop, dy: -controlHitSlop).contains(point) {
            return .fontSize
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let localPoint = rotate(point, around: center, by: -rotation)
        let outer = rect.insetBy(dx: -borderOuterHitWidth, dy: -borderOuterHitWidth)
        guard outer.contains(localPoint) else { return .outside }
        let inner = rect.insetBy(dx: borderInnerHitWidth, dy: borderInnerHitWidth)
        if inner.width <= 0 || inner.height <= 0 || !inner.contains(localPoint) {
            return .border
        }
        return .interior
    }

    static func hoverContains(
        _ point: NSPoint,
        rect: NSRect,
        rotation: CGFloat
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let controls = controlRects(for: rect, rotation: rotation)
        if controls.rotate.insetBy(dx: -controlHitSlop, dy: -controlHitSlop).contains(point)
            || controls.fontSize.insetBy(dx: -controlHitSlop, dy: -controlHitSlop).contains(point) {
            return true
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let localPoint = rotate(point, around: center, by: -rotation)
        return rect.insetBy(dx: -hoverPadding, dy: -hoverPadding).contains(localPoint)
    }

    /// Returns the four frame edges with the upper-right and lower-right
    /// corners shortened so the two centered SF Symbols never have a line
    /// running through them.
    static func frameSegments(
        for rect: NSRect,
        controlClearance: CGFloat
    ) -> [TextAnnotationFrameSegment] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let clearance = max(
            0,
            min(controlClearance, rect.width / 2, rect.height / 2)
        )
        return [
            TextAnnotationFrameSegment(
                start: NSPoint(x: rect.minX, y: rect.maxY),
                end: NSPoint(x: rect.maxX - clearance, y: rect.maxY)
            ),
            TextAnnotationFrameSegment(
                start: NSPoint(x: rect.maxX, y: rect.maxY - clearance),
                end: NSPoint(x: rect.maxX, y: rect.minY + clearance)
            ),
            TextAnnotationFrameSegment(
                start: NSPoint(x: rect.maxX - clearance, y: rect.minY),
                end: NSPoint(x: rect.minX, y: rect.minY)
            ),
            TextAnnotationFrameSegment(
                start: NSPoint(x: rect.minX, y: rect.minY),
                end: NSPoint(x: rect.minX, y: rect.maxY)
            ),
        ]
    }

    static func adjustedRotation(
        original: CGFloat,
        startAngle: CGFloat,
        currentAngle: CGFloat
    ) -> CGFloat {
        normalizeAngle(original + normalizeAngle(currentAngle - startAngle))
    }

    static func scaledFontSize(
        original: CGFloat,
        startDistance: CGFloat,
        currentDistance: CGFloat
    ) -> CGFloat {
        guard startDistance > 0.001 else { return min(200, max(8, original.rounded())) }
        let scaled = (original * currentDistance / startDistance).rounded()
        return min(200, max(8, scaled))
    }

    static func angle(from center: NSPoint, to point: NSPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    static func distance(from a: NSPoint, to b: NSPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func centeredRect(at point: NSPoint, size: CGFloat) -> NSRect {
        NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private static func rotate(_ point: NSPoint, around center: NSPoint, by angle: CGFloat) -> NSPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return NSPoint(
            x: center.x + dx * cos(angle) - dy * sin(angle),
            y: center.y + dx * sin(angle) + dy * cos(angle)
        )
    }

    private static func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        var result = angle.truncatingRemainder(dividingBy: fullTurn)
        if result >= .pi - 0.000_000_001 {
            result -= fullTurn
        } else if result < -.pi {
            result += fullTurn
        }
        return result
    }
}
