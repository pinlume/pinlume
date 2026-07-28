import Cocoa

/// Handles manual rectangular and brush-shaped pixelate/blur censoring.
/// Automatic text/PII/face/person redaction remains in the options row.
final class PixelateToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pixelate

    private static let defaultBrushWidth: CGFloat = 24
    private var liveBrushPreview: CensorLivePreview?
    private var renderer: CensorRenderer?
    private var currentShape = CensorShape(
        rawValue: UserDefaults.standard.integer(forKey: "censorShape")
    ) ?? .rectangle
    private var currentMode: CensorMode = {
        let stored = CensorMode(rawValue: UserDefaults.standard.integer(forKey: "censorMode")) ?? .pixelate
        return stored == .blur ? .blur : .pixelate
    }()
    private var currentStrength = CensorStrength.clamped(CGFloat(
        UserDefaults.standard.object(forKey: "censorStrength") as? Double
            ?? Double(CensorStrength.defaultValue)
    ))
    private var currentBrushWidth = max(4, CGFloat(
        UserDefaults.standard.object(forKey: "censorBrushWidth") as? Double
            ?? Double(PixelateToolHandler.defaultBrushWidth)
    ))

    func setShape(_ shape: CensorShape) { currentShape = shape }
    func setMode(_ mode: CensorMode) { currentMode = mode == .blur ? .blur : .pixelate }
    func setStrength(_ strength: CGFloat) { currentStrength = CensorStrength.clamped(strength) }

    func cursorForCanvas(_ canvas: AnnotationCanvas) -> NSCursor? {
        guard currentShape == .brush else { return nil }
        return AnnotationCursorProvider.cursor(
            kind: .censorBrush,
            color: .black,
            contrast: .lightOutline,
            diameter: currentBrushWidth * (2.0 / 3.0)
        )
    }

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        liveBrushPreview = nil
        renderer = canvas.screenshotImage.flatMap {
            CensorRenderer(sourceImage: $0, sourceBounds: canvas.captureDrawRect)
        }
        let shape = currentShape
        let mode = currentMode
        let strength = currentStrength
        let brushWidth = currentBrushWidth
        let annotation = Annotation(
            tool: .pixelate,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pixelate),
            strokeWidth: shape == .brush ? brushWidth : canvas.currentStrokeWidth
        )
        annotation.censorMode = mode
        annotation.censorShape = shape
        annotation.censorStrength = strength
        annotation.sourceImage = canvas.screenshotImage
        annotation.sourceImageBounds = canvas.captureDrawRect
        if shape == .brush {
            annotation.points = [point]
            if let renderer {
                let preview = CensorLivePreview(renderer: renderer)
                liveBrushPreview = preview
                annotation.bakedBlurNSImage = preview.appendSegment(
                    from: point,
                    to: point,
                    annotation: annotation
                )
            }
        }
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        if annotation.censorShape == .brush {
            let previousPoint = annotation.points?.last ?? point
            let spacing = max(2, min(annotation.strokeWidth * 0.25, 8))
            annotation.points = CensorBrushGeometry.sampledPoints(
                annotation.points ?? [],
                appending: point,
                minimumDistance: spacing
            )
            annotation.endPoint = point
            annotation.bakedBlurNSImage = liveBrushPreview?.appendSegment(
                from: previousPoint,
                to: point,
                annotation: annotation
            )
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
            return
        }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snapSquare(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else {
            clampedPoint = canvas.snapPoint(point, excluding: annotation)
        }

        annotation.endPoint = clampedPoint
        // Rectangle drawing reuses the exact final renderer, so the pixels shown
        // during the drag are the pixels that are committed on mouse-up.
        annotation.bakedBlurNSImage = renderer?.render(
            canvasRect: annotation.boundingRect,
            mode: annotation.censorMode,
            strength: annotation.censorStrength
        )
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        defer {
            liveBrushPreview = nil
            renderer = nil
        }
        let isBrush = annotation.censorShape == .brush
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)
        guard isBrush || dx > 2 || dy > 2 else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }

        if isBrush {
            annotation.bakedBlurNSImage = liveBrushPreview?.finalImage(in: annotation.boundingRect)
        }
        commitAnnotation(annotation, canvas: canvas)
    }
}
