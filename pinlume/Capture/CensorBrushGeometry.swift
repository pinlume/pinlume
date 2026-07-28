import Cocoa

enum CensorShape: Int {
    case rectangle
    case brush
}

enum CensorStrength {
    /// The toolbar deliberately exposes a small, predictable range.  The value
    /// is a visual level, not a raw Core Image radius or pixel block size.
    static let minimumLevel: CGFloat = 1
    static let maximumLevel: CGFloat = 10
    static let defaultValue: CGFloat = 6

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(maximumLevel, max(minimumLevel, value.rounded()))
    }

    /// Maps ten evenly-spaced visible levels onto the old useful 1...5 range.
    /// Values saved by 0.1.19 above ten therefore become the new maximum.
    static func effectiveStrength(for level: CGFloat) -> CGFloat {
        let normalized = (clamped(level) - minimumLevel) / (maximumLevel - minimumLevel)
        return 1 + normalized * 4
    }

    /// Pixel blocks are expressed in visual points, then converted to source
    /// pixels. This keeps the grain consistent across 1x and Retina displays.
    /// Level one intentionally matches the former level-six Retina result.
    static func pixelBlockSize(for value: CGFloat, pixelScale: CGFloat = 1) -> Int {
        let normalized = (clamped(value) - minimumLevel) / (maximumLevel - minimumLevel)
        let logicalBlockSize = 2.5 + normalized * 13.5
        return max(2, Int((logicalBlockSize * max(1, pixelScale)).rounded()))
    }

    static func blurRadius(for value: CGFloat, cropSize: CGSize) -> Double {
        let base = max(10.0, Double(min(cropSize.width, cropSize.height)) * 0.03)
        let scaled = base * Double(effectiveStrength(for: value) / defaultValue)
        return min(Double(min(cropSize.width, cropSize.height)) * 0.2, scaled)
    }
}

enum CensorBrushGeometry {
    static func expandedBounds(points: [NSPoint], width: CGFloat) -> NSRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let radius = max(width, 1) / 2
        return NSRect(
            x: minX - radius,
            y: minY - radius,
            width: maxX - minX + radius * 2,
            height: maxY - minY + radius * 2
        )
    }

    /// Retains the leading cap and endpoint while dropping redundant high-rate
    /// mouse samples, so long brush strokes do not make every preview redraw
    /// traverse an unbounded number of nearly-identical points.
    static func sampledPoints(_ points: [NSPoint], appending point: NSPoint, minimumDistance: CGFloat) -> [NSPoint] {
        guard let last = points.last else { return [point] }
        guard points.count > 1, hypot(last.x - point.x, last.y - point.y) < minimumDistance else {
            return points + [point]
        }
        var result = points
        result[result.index(before: result.endIndex)] = point
        return result
    }

    static func makeMask(size: NSSize, points: [NSPoint], width: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0, let first = points.first else { return nil }
        let pixelWidth = max(1, Int(size.width.rounded(.up)))
        let pixelHeight = max(1, Int(size.height.rounded(.up)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        if points.count == 1 {
            let radius = max(width, 1) / 2
            context.fillEllipse(in: CGRect(
                x: first.x - radius,
                y: first.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        } else {
            let path = CGMutablePath()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.addPath(path)
            context.setLineWidth(max(width, 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        return context.makeImage()
    }
}
