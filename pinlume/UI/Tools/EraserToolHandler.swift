import Cocoa

/// Freehand transparent mask. It is composited into the annotation layer, so
/// it removes only the brushed pixels while preserving the screenshot below.
final class EraserToolHandler: AnnotationToolHandler {
    let tool: AnnotationTool = .eraser

    var cursor: NSCursor? {
        AnnotationCursorProvider.cursor(
            kind: .eraser,
            color: .systemGray,
            contrast: .lightOutline
        )
    }

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let annotation = Annotation(tool: .eraser, startPoint: point, endPoint: point, color: .clear, strokeWidth: max(18, canvas.currentStrokeWidth * 4))
        annotation.points = [point]
        canvas.beginLiveEraser(at: point)
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let previousPoint = annotation.points?.last ?? annotation.endPoint
        annotation.endPoint = point
        annotation.points?.append(point)
        canvas.eraseLiveAnnotationSegment(from: previousPoint, to: point, strokeWidth: annotation.strokeWidth)
        canvas.setNeedsDisplay()
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        if annotation.points?.count == 1, let point = annotation.points?.first {
            let endPoint = NSPoint(x: point.x + 0.1, y: point.y)
            annotation.points = [point, endPoint]
            canvas.eraseLiveAnnotationSegment(from: point, to: endPoint, strokeWidth: annotation.strokeWidth)
        }
        commitAnnotation(annotation, canvas: canvas)
    }
}
