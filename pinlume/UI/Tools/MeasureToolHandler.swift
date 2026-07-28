import Cocoa

/// Handles measure (pixel ruler) tool interaction.
/// Draws a measurement line with shift-constrain to 45° angles and snap guides.
final class MeasureToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .measure

    private func clampedPoint(_ point: NSPoint, in rect: NSRect) -> NSPoint {
        let bounds = rect.standardized
        return NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let startPoint = clampedPoint(point, in: canvas.captureDrawRect)
        let annotation = Annotation(
            tool: .measure,
            startPoint: startPoint,
            endPoint: startPoint,
            color: canvas.opacityAppliedColor(for: .measure),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.measureInPoints = canvas.currentMeasureInPoints
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snap45(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else if canvas.allowsMeasureSnapGuides {
            clampedPoint = canvas.snapPoint(point, excluding: annotation)
        } else {
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        }

        annotation.endPoint = self.clampedPoint(clampedPoint, in: canvas.captureDrawRect)
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)
        guard dx > 2 || dy > 2 else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }
        commitAnnotation(annotation, canvas: canvas)
    }
}
