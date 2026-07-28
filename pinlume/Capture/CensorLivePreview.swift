import Cocoa

/// Incremental brush output backed by one block-aligned bitmap. New mouse
/// samples process and composite only their travelled segment.
@MainActor
final class CensorLivePreview {
    private static let backingBlock: CGFloat = 128

    private let renderer: CensorRenderer
    private let scale: CGFloat
    private var backingRect: NSRect = .zero
    private var backingContext: CGContext?

    init(renderer: CensorRenderer) {
        self.renderer = renderer
        scale = renderer.pixelScale
    }

    func appendSegment(from start: NSPoint, to end: NSPoint, annotation: Annotation) -> NSImage? {
        let strokeRect = annotation.boundingRect
        guard strokeRect.width > 0, strokeRect.height > 0 else { return nil }
        ensureBacking(covering: alignedBackingRect(for: strokeRect))

        let segmentBounds = CensorBrushGeometry.expandedBounds(
            points: [start, end], width: annotation.strokeWidth
        )
        let padding = processingPadding(for: annotation, segmentBounds: segmentBounds)
        let sourceRect = segmentBounds.insetBy(dx: -padding, dy: -padding)
            .intersection(annotation.sourceImageBounds)
        guard sourceRect.width > 0, sourceRect.height > 0,
              let processed = renderer.render(
                canvasRect: sourceRect,
                mode: annotation.censorMode,
                strength: annotation.censorStrength
              ),
              let segment = makeMaskedSegment(
                processed: processed,
                sourceRect: sourceRect,
                start: start,
                end: end,
                width: annotation.strokeWidth
              ),
              let backingContext
        else { return snapshot(croppedTo: strokeRect) }

        backingContext.saveGState()
        backingContext.setBlendMode(.normal)
        backingContext.draw(segment, in: CGRect(
            x: sourceRect.minX - backingRect.minX,
            y: sourceRect.minY - backingRect.minY,
            width: sourceRect.width,
            height: sourceRect.height
        ))
        backingContext.restoreGState()
        return snapshot(croppedTo: strokeRect)
    }

    func finalImage(in canvasRect: NSRect) -> NSImage? {
        snapshot(croppedTo: canvasRect)
    }

    private func alignedBackingRect(for rect: NSRect) -> NSRect {
        let block = Self.backingBlock
        let minX = floor(rect.minX / block) * block
        let minY = floor(rect.minY / block) * block
        let maxX = ceil(rect.maxX / block) * block
        let maxY = ceil(rect.maxY / block) * block
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func ensureBacking(covering requiredRect: NSRect) {
        let nextRect = backingRect.isEmpty ? requiredRect : backingRect.union(requiredRect)
        guard nextRect != backingRect else { return }
        guard let nextContext = makeContext(size: nextRect.size) else { return }
        copyPreviousPixels(to: nextContext, nextRect: nextRect)
        backingRect = nextRect
        backingContext = nextContext
    }

    private func copyPreviousPixels(to nextContext: CGContext, nextRect: NSRect) {
        guard let previous = backingContext?.makeImage(), !backingRect.isEmpty else { return }
        nextContext.draw(previous, in: CGRect(
            x: backingRect.minX - nextRect.minX,
            y: backingRect.minY - nextRect.minY,
            width: backingRect.width,
            height: backingRect.height
        ))
    }

    private func makeContext(size: NSSize) -> CGContext? {
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func processingPadding(for annotation: Annotation, segmentBounds: NSRect) -> CGFloat {
        guard annotation.censorMode == .blur else {
            let pixelBlock = CensorStrength.pixelBlockSize(
                for: annotation.censorStrength,
                pixelScale: scale
            )
            return max(2, CGFloat(pixelBlock) / scale)
        }
        let pixelSize = NSSize(
            width: segmentBounds.width * scale,
            height: segmentBounds.height * scale
        )
        let radius = CensorStrength.blurRadius(
            for: annotation.censorStrength,
            cropSize: pixelSize
        )
        return max(2, CGFloat(radius) * 3 / scale)
    }

    private func makeMaskedSegment(
        processed: NSImage,
        sourceRect: NSRect,
        start: NSPoint,
        end: NSPoint,
        width: CGFloat
    ) -> CGImage? {
        guard let context = makeContext(size: sourceRect.size) else { return nil }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        processed.draw(
            in: NSRect(origin: .zero, size: sourceRect.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let localPoints = [
            NSPoint(x: start.x - sourceRect.minX, y: start.y - sourceRect.minY),
            NSPoint(x: end.x - sourceRect.minX, y: end.y - sourceRect.minY),
        ]
        let maskPoints = hypot(start.x - end.x, start.y - end.y) < 0.1
            ? [localPoints[0]]
            : localPoints
        guard let mask = CensorBrushGeometry.makeMask(
            size: NSSize(
                width: sourceRect.width * scale,
                height: sourceRect.height * scale
            ),
            points: maskPoints.map { NSPoint(x: $0.x * scale, y: $0.y * scale) },
            width: width * scale
        ) else { return nil }
        context.saveGState()
        context.setBlendMode(.destinationIn)
        context.draw(mask, in: CGRect(
            x: 0, y: 0,
            width: sourceRect.width,
            height: sourceRect.height
        ))
        context.restoreGState()
        return context.makeImage()
    }

    private func snapshot(croppedTo canvasRect: NSRect) -> NSImage? {
        guard let image = backingContext?.makeImage(),
              !backingRect.isEmpty,
              canvasRect.width > 0,
              canvasRect.height > 0
        else { return nil }
        let crop = CGRect(
            x: (canvasRect.minX - backingRect.minX) * scale,
            y: (backingRect.maxY - canvasRect.maxY) * scale,
            width: canvasRect.width * scale,
            height: canvasRect.height * scale
        ).integral.intersection(CGRect(
            x: 0, y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        guard crop.width > 0, crop.height > 0,
              let cropped = image.cropping(to: crop)
        else { return nil }
        // Detach the visible crop from the mutable backing store. Keeping a
        // cropped view of `image` alive would force CoreGraphics to copy the
        // entire growing backing buffer on the next segment (copy-on-write).
        guard let detachedContext = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        detachedContext.draw(cropped, in: CGRect(
            x: 0, y: 0,
            width: CGFloat(cropped.width),
            height: CGFloat(cropped.height)
        ))
        guard let detached = detachedContext.makeImage() else { return nil }
        return NSImage(cgImage: detached, size: canvasRect.size)
    }
}
