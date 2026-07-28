import Cocoa

/// Vector-only payload passed from a transparent annotation session to its Pin.
/// `cropRect` stays in the source screen's overlay coordinate space.
@MainActor
struct TransparentAnnotationPinPayload {
    let screen: NSScreen
    let cropRect: NSRect
    let annotations: [Annotation]
}

/// Keeps the final crop and compact Pin geometry in one place. It never renders
/// pixels: partial annotations stay editable and are clipped by the Pin canvas.
@MainActor
enum TransparentAnnotationGeometry {

    static func retainedAnnotations(_ annotations: [Annotation], cropRect: NSRect) -> [Annotation] {
        annotations.filter { !$0.visibleBounds.intersection(cropRect).isEmpty }
    }

    static func visibleAnnotationBounds(_ annotations: [Annotation], cropRect: NSRect) -> NSRect {
        annotations.reduce(NSRect.null) { bounds, annotation in
            bounds.union(annotation.visibleBounds.intersection(cropRect))
        }
    }

    /// A transparent Pin never grows past the user-confirmed selection. When
    /// visible vectors occupy less space, trim only the empty margin so the
    /// floating surface stays tight without reintroducing safety padding.
    static func pinContentBounds(for payload: TransparentAnnotationPinPayload) -> NSRect {
        let visibleBounds = visibleAnnotationBounds(payload.annotations, cropRect: payload.cropRect)
        return visibleBounds.isNull || visibleBounds.isEmpty ? payload.cropRect : visibleBounds
    }

    /// A transparent Pin is positioned by the final selection. Re-entering at
    /// a moved Pin therefore needs to translate the source crop and vectors by
    /// the same delta before opening the full-size transparent selection session.
    static func payloadPositioned(
        atCompactPinOrigin pinOrigin: NSPoint,
        from payload: TransparentAnnotationPinPayload
    ) -> TransparentAnnotationPinPayload {
        let bounds = pinContentBounds(for: payload)
        guard !bounds.isEmpty else { return payload }
        let naturalOrigin = NSPoint(
            x: payload.screen.frame.minX + bounds.minX,
            y: payload.screen.frame.minY + bounds.minY
        )
        let delta = NSPoint(x: pinOrigin.x - naturalOrigin.x, y: pinOrigin.y - naturalOrigin.y)
        guard delta != .zero else { return payload }
        return TransparentAnnotationPinPayload(
            screen: payload.screen,
            cropRect: payload.cropRect.offsetBy(dx: delta.x, dy: delta.y),
            annotations: payload.annotations.map { annotation in
                translatedAnnotation(annotation, dx: delta.x, dy: delta.y)
            }
        )
    }

    /// Pixel output is only for Copy/Save. Pins keep their cloned vector
    /// annotations instead, so text and shapes remain editable there.
    static func renderOutputImage(
        annotations: [Annotation],
        cropRect: NSRect
    ) -> NSImage? {
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        let retained = retainedAnnotations(annotations, cropRect: cropRect)
        guard !retained.isEmpty else { return nil }
        let translated = translateForPin(retained, contentBounds: cropRect, padding: 0)
        return NSImage(size: cropRect.size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            translated.forEach { $0.draw(in: context) }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    static func translateForPin(
        _ annotations: [Annotation],
        contentBounds: NSRect,
        padding: CGFloat
    ) -> [Annotation] {
        annotations.map {
            translatedAnnotation(
                $0,
                dx: -contentBounds.minX + padding,
                dy: -contentBounds.minY + padding
            )
        }
    }

    /// This is a coordinate-space translation, not an annotation drag. A
    /// rooted loupe's source circle therefore must move with its lens.
    private static func translatedAnnotation(_ source: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        let annotation = source.clone()
        annotation.move(dx: dx, dy: dy)
        if let sourceRect = source.loupeSourceRect {
            annotation.loupeSourceRect = sourceRect.offsetBy(dx: dx, dy: dy)
        }
        return annotation
    }
}
