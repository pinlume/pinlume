import AppKit

/// Process-wide cursor resources rendered once for pointer tracking.
@MainActor
enum AppCursor {
    static let diagonalNWSE: NSCursor = {
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        )?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    static let diagonalNESW: NSCursor = {
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthEastSouthWestCursor")
        )?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    static let rotation: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let base = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Rotate"
            ) else { return false }
            let pointConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .black)
            let symbol = base.withSymbolConfiguration(pointConfig.applying(colorConfig)) ?? base
            symbol.draw(
                in: NSRect(x: 4, y: 4, width: 20, height: 20),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
    }()

    static let move: NSCursor = makeMoveCursor()

    private static func makeMoveCursor() -> NSCursor {
        let size = NSSize(width: 30, height: 30)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            func triangle(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                return path
            }

            // One centered symbol: extending the shafts changes its size without
            // scaling the solid arrowheads or their stroke thickness.
            func insetTriangle(_ points: [CGPoint], by amount: CGFloat) -> CGPath {
                let center = CGPoint(
                    x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                    y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
                )
                let inset = points.map { point -> CGPoint in
                    let dx = center.x - point.x
                    let dy = center.y - point.y
                    let distance = max(hypot(dx, dy), 0.001)
                    return CGPoint(
                        x: point.x + dx / distance * amount,
                        y: point.y + dy / distance * amount
                    )
                }
                return triangle(inset)
            }

            let outerParts: [CGPath] = [
                CGPath(rect: CGRect(x: 8, y: 14, width: 14, height: 2), transform: nil),
                CGPath(rect: CGRect(x: 14, y: 8, width: 2, height: 14), transform: nil),
                triangle([
                    CGPoint(x: 4, y: 15), CGPoint(x: 9, y: 11.25), CGPoint(x: 9, y: 18.75)
                ]),
                triangle([
                    CGPoint(x: 26, y: 15), CGPoint(x: 21, y: 11.25), CGPoint(x: 21, y: 18.75)
                ]),
                triangle([
                    CGPoint(x: 15, y: 26),
                    CGPoint(x: 11.25, y: 21),
                    CGPoint(x: 18.75, y: 21)
                ]),
                triangle([
                    CGPoint(x: 15, y: 4),
                    CGPoint(x: 11.25, y: 9),
                    CGPoint(x: 18.75, y: 9)
                ])
            ]

            let innerParts: [CGPath] = [
                CGPath(rect: CGRect(x: 8, y: 14, width: 14, height: 2).insetBy(dx: 0.5, dy: 0.5), transform: nil),
                CGPath(rect: CGRect(x: 14, y: 8, width: 2, height: 14).insetBy(dx: 0.5, dy: 0.5), transform: nil),
                insetTriangle([
                    CGPoint(x: 4, y: 15), CGPoint(x: 9, y: 11.25), CGPoint(x: 9, y: 18.75)
                ], by: 0.5),
                insetTriangle([
                    CGPoint(x: 26, y: 15), CGPoint(x: 21, y: 11.25), CGPoint(x: 21, y: 18.75)
                ], by: 0.5),
                insetTriangle([
                    CGPoint(x: 15, y: 26),
                    CGPoint(x: 11.25, y: 21),
                    CGPoint(x: 18.75, y: 21)
                ], by: 0.5),
                insetTriangle([
                    CGPoint(x: 15, y: 4),
                    CGPoint(x: 11.25, y: 9),
                    CGPoint(x: 18.75, y: 9)
                ], by: 0.5)
            ]

            context.setFillColor(NSColor.white.cgColor)
            for part in outerParts {
                context.addPath(part)
                context.fillPath()
            }
            context.setFillColor(NSColor.black.cgColor)
            for part in innerParts {
                context.addPath(part)
                context.fillPath()
            }
            return rect.width > 0
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 15, y: 15))
    }
}
