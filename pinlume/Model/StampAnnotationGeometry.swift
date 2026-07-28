import Cocoa

/// Geometry used exclusively by the stamp tool's rotation and aspect-locked resize controls.
enum StampAnnotationGeometry {
    enum ResizeHandle {
        case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
    }

    static func rotate(_ point: NSPoint, around center: NSPoint, by angle: CGFloat) -> NSPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return NSPoint(
            x: center.x + dx * cos(angle) - dy * sin(angle),
            y: center.y + dx * sin(angle) + dy * cos(angle)
        )
    }

    static func unrotate(_ point: NSPoint, around center: NSPoint, by angle: CGFloat) -> NSPoint {
        rotate(point, around: center, by: -angle)
    }

    /// The rotation handle starts directly above the stamp, so that location is zero radians.
    static func rotation(forRotationHandle point: NSPoint, around center: NSPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x) - .pi / 2
    }

    /// Expands the stamp's local edit rectangle through the center of its rotation point.
    static func previewExclusionRect(for rect: NSRect, rotationHandleOffset: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + rotationHandleOffset)
    }

    /// Keeps the source image's aspect ratio while preserving the edge opposite the dragged handle.
    static func aspectLockedRect(base: NSRect, proposed: NSRect, handle: ResizeHandle) -> NSRect {
        let baseWidth = max(base.width, 1)
        let baseHeight = max(base.height, 1)
        let minimumScale = max(10 / baseWidth, 10 / baseHeight)

        let scale: CGFloat
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            scale = max(minimumScale, proposed.width / baseWidth, proposed.height / baseHeight)
        case .left, .right:
            scale = max(minimumScale, proposed.width / baseWidth)
        case .top, .bottom:
            scale = max(minimumScale, proposed.height / baseHeight)
        }

        let width = baseWidth * scale
        let height = baseHeight * scale
        switch handle {
        case .topLeft:
            return NSRect(x: base.maxX - width, y: base.minY, width: width, height: height)
        case .topRight:
            return NSRect(x: base.minX, y: base.minY, width: width, height: height)
        case .bottomLeft:
            return NSRect(x: base.maxX - width, y: base.maxY - height, width: width, height: height)
        case .bottomRight:
            return NSRect(x: base.minX, y: base.maxY - height, width: width, height: height)
        case .left:
            return NSRect(x: base.maxX - width, y: base.midY - height / 2, width: width, height: height)
        case .right:
            return NSRect(x: base.minX, y: base.midY - height / 2, width: width, height: height)
        case .top:
            return NSRect(x: base.midX - width / 2, y: base.minY, width: width, height: height)
        case .bottom:
            return NSRect(x: base.midX - width / 2, y: base.maxY - height, width: width, height: height)
        }
    }
}
