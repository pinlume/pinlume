import AppKit

/// Semantic annotation cursors rendered once and reused. Background sampling is
/// owned by the canvas; this provider only turns a stable key into an NSCursor.
@MainActor
enum AnnotationCursorProvider {
    enum Kind: Int, Hashable {
        case drawingCrosshair
        case censorRectangle
        case censorBrush
        case eraser
        case markerCircle
        case markerPill
    }

    private struct Key: Hashable {
        let kind: Kind
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
        let contrast: CursorContrastStyle
        let diameter: Int
        let width: Int
        let backingScale: Int

        var isMarker: Bool {
            kind == .markerCircle || kind == .markerPill
        }
    }

    private struct LastRequest {
        let kind: Kind
        let color: NSColor
        let contrast: CursorContrastStyle
        let diameter: CGFloat
        let width: CGFloat
        let backingScale: Int
        let cursor: NSCursor
    }

    private static var cache: [Key: NSCursor] = [:]
    private static var cacheUsage: [Key] = []
    private static let maximumCacheEntries = 16
    private static let maximumMarkerCacheEntries = 2
    /// Marker width tops out at 120pt before view scaling and 960pt at the
    /// editor's supported 8x zoom, so 1024 covers the product range with margin.
    private static let markerMaximumDiameter = 1024
    /// Mouse tracking normally asks for the same cursor hundreds of times in a
    /// row. Keep that request before RGB conversion so the hot path does not
    /// allocate an sRGB color object merely to hit the dictionary cache.
    private static var lastRequest: LastRequest?

    static func cursor(
        kind: Kind,
        color: NSColor,
        contrast: CursorContrastStyle,
        diameter: CGFloat = 26,
        width: CGFloat? = nil,
        backingScaleFactor: CGFloat = 2
    ) -> NSCursor {
        let backingScale = backingScaleKey(backingScaleFactor)
        let resolvedWidth = width ?? diameter
        if let lastRequest,
           lastRequest.kind == kind,
           lastRequest.color.isEqual(color),
           lastRequest.contrast == contrast,
           lastRequest.diameter == diameter,
           lastRequest.width == resolvedWidth,
           lastRequest.backingScale == backingScale {
            return lastRequest.cursor
        }
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let isMarker = kind == .markerCircle || kind == .markerPill
        let minimumDiameter = isMarker ? 1 : 12
        let maximumDiameter = isMarker ? markerMaximumDiameter : 48
        let clampedDiameter = Int(max(
            CGFloat(minimumDiameter), min(CGFloat(maximumDiameter), diameter)
        ).rounded())
        let markerWidth = isMarker
            ? Int(max(1, min(CGFloat(markerMaximumDiameter), resolvedWidth)).rounded())
            : clampedDiameter
        let key = Key(
            kind: kind,
            red: UInt8(clamping: Int((rgb.redComponent * 255).rounded())),
            green: UInt8(clamping: Int((rgb.greenComponent * 255).rounded())),
            blue: UInt8(clamping: Int((rgb.blueComponent * 255).rounded())),
            alpha: UInt8(clamping: Int((rgb.alphaComponent * 255).rounded())),
            contrast: contrast,
            diameter: clampedDiameter,
            width: markerWidth,
            backingScale: backingScale
        )
        let cursor: NSCursor
        if let cached = cache[key] {
            cursor = cached
            touchCacheKey(key)
        } else {
            cursor = makeCursor(key: key, color: rgb)
            cache[key] = cursor
            touchCacheKey(key)
        }
        lastRequest = LastRequest(
            kind: kind,
            color: color,
            contrast: contrast,
            diameter: diameter,
            width: resolvedWidth,
            backingScale: backingScale,
            cursor: cursor
        )
        return cursor
    }

    private static func touchCacheKey(_ key: Key) {
        cacheUsage.removeAll { $0 == key }
        cacheUsage.append(key)
        while cacheUsage.filter(\.isMarker).count > maximumMarkerCacheEntries,
              let oldestMarker = cacheUsage.firstIndex(where: \.isMarker) {
            cache.removeValue(forKey: cacheUsage.remove(at: oldestMarker))
        }
        while cacheUsage.count > maximumCacheEntries {
            cache.removeValue(forKey: cacheUsage.removeFirst())
        }
    }

    static func thinOutlineThickness(backingScaleFactor: CGFloat) -> CGFloat {
        let scale = backingScaleFactor.isFinite ? max(1, backingScaleFactor) : 2
        return max(0.3, 0.6 / scale)
    }

    private static func backingScaleKey(_ backingScaleFactor: CGFloat) -> Int {
        let scale = backingScaleFactor.isFinite ? max(1, min(4, backingScaleFactor)) : 2
        return Int((scale * 100).rounded())
    }

    private static func makeCursor(key: Key, color: NSColor) -> NSCursor {
        let isMarker = key.kind == .markerCircle || key.kind == .markerPill
        let canvas: CGFloat = (key.kind == .censorBrush || isMarker)
            ? CGFloat(max(key.diameter, key.width) + 6)
            : 28
        let center = canvas / 2
        let thinOutlineThickness = thinOutlineThickness(
            backingScaleFactor: CGFloat(key.backingScale) / 100
        )
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let outline: NSColor? = switch key.contrast {
            case .darkOutline: .black
            case .lightOutline: .white
            case .none: nil
            }

            func stroke(
                _ path: NSBezierPath,
                width: CGFloat = 1.5,
                outlineThickness: CGFloat = 0.5,
                foregroundColor: NSColor? = nil
            ) {
                if let outline {
                    outline.setStroke()
                    path.lineWidth = width + outlineThickness * 2
                    path.stroke()
                }
                (foregroundColor ?? color).setStroke()
                path.lineWidth = width
                path.stroke()
            }

            switch key.kind {
            case .drawingCrosshair, .censorRectangle:
                let segmentGap: CGFloat = 4
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: center, y: 3))
                path.line(to: NSPoint(x: center, y: center - segmentGap))
                path.move(to: NSPoint(x: center, y: center + segmentGap))
                path.line(to: NSPoint(x: center, y: canvas - 3))
                path.move(to: NSPoint(x: 3, y: center))
                path.line(to: NSPoint(x: center - segmentGap, y: center))
                path.move(to: NSPoint(x: center + segmentGap, y: center))
                path.line(to: NSPoint(x: canvas - 3, y: center))
                stroke(path, width: 1, outlineThickness: thinOutlineThickness)
                let dotRect = NSRect(
                    x: center - 0.5, y: center - 0.5, width: 1, height: 1
                )
                let dot = NSBezierPath(ovalIn: dotRect)
                if let outline {
                    outline.setFill()
                    NSBezierPath(ovalIn: dotRect.insetBy(
                        dx: -thinOutlineThickness,
                        dy: -thinOutlineThickness
                    )).fill()
                }
                color.setFill()
                dot.fill()

            case .censorBrush:
                let diameter = CGFloat(key.diameter)
                let ring = NSBezierPath(ovalIn: NSRect(
                    x: center - diameter / 2,
                    y: center - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
                stroke(ring, width: 1)
                NSColor(white: 0.55, alpha: 0.45).setFill()
                ring.fill()

            case .eraser:
                let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 8, width: 16, height: 12), xRadius: 3, yRadius: 3)
                var transform = AffineTransform(translationByX: center, byY: center)
                transform.rotate(byDegrees: -35)
                transform.translate(x: -center, y: -center)
                body.transform(using: transform)
                if let outline {
                    outline.setStroke()
                    body.lineWidth = 1
                    body.stroke()
                }
                color.setFill()
                body.fill()
                NSColor.white.withAlphaComponent(0.75).setStroke()
                body.lineWidth = 0.5
                body.stroke()

            case .markerCircle, .markerPill:
                let height = CGFloat(key.diameter)
                let width = CGFloat(key.width)
                let brushRect = NSRect(
                    x: center - width / 2,
                    y: center - height / 2,
                    width: width,
                    height: height
                )
                let brush = key.kind == .markerPill
                    ? NSBezierPath(
                        roundedRect: brushRect,
                        xRadius: width / 2,
                        yRadius: width / 2
                    )
                    : NSBezierPath(ovalIn: brushRect)
                let isPill = key.kind == .markerPill
                color.withAlphaComponent(isPill ? 0.45 : 0.35).setFill()
                brush.fill()
                stroke(
                    brush,
                    width: 1,
                    outlineThickness: thinOutlineThickness,
                    foregroundColor: color.withAlphaComponent(isPill ? 0.8 : 0.7)
                )
            }
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }
}
