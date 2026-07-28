import AppKit

@MainActor
final class TextAnnotationLineMetricsDelegate: NSObject, @preconcurrency NSLayoutManagerDelegate {
    var fallbackFont: NSFont

    init(fallbackFont: NSFont) {
        self.fallbackFont = fallbackFont
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let metrics = TextAnnotationLayout.stableLineMetrics(
            in: layoutManager,
            glyphRange: glyphRange,
            fallbackFont: fallbackFont
        )
        lineFragmentRect.pointee.size.height = metrics.height
        lineFragmentUsedRect.pointee.size.height = metrics.height
        baselineOffset.pointee = metrics.baseline
        return true
    }
}

@MainActor
enum TextAnnotationLayout {
    static let textInset = NSSize(width: 4, height: 4)
    static let minimumWidth: CGFloat = 20

    static func intrinsicSize(
        usedRect: NSRect,
        extraLineFragmentRect: NSRect,
        inset: NSSize,
        lineHeight: CGFloat
    ) -> NSSize {
        // With an unbounded text container, TextKit exposes the container's
        // sentinel width through the empty extra line fragment. It describes
        // caret height/origin, not laid-out glyph width.
        let contentWidth = max(0, usedRect.maxX)
        let contentHeight = max(
            lineHeight,
            usedRect.maxY,
            extraLineFragmentRect.maxY
        )
        return NSSize(
            width: max(minimumWidth, ceil(contentWidth) + inset.width * 2),
            height: ceil(contentHeight) + inset.height * 2
        )
    }

    static func measure(_ text: NSAttributedString, fallbackFont: NSFont) -> NSSize {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let lineMetrics = TextAnnotationLineMetricsDelegate(fallbackFont: fallbackFont)
        let container = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.delegate = lineMetrics
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        return intrinsicSize(
            usedRect: layoutManager.usedRect(for: container),
            extraLineFragmentRect: layoutManager.extraLineFragmentRect,
            inset: textInset,
            lineHeight: layoutManager.defaultLineHeight(for: fallbackFont)
        )
    }

    static func render(_ text: NSAttributedString, size: NSSize) -> NSImage {
        let inset = textInset
        let fallbackFont = (text.length > 0
            ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : nil)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return NSImage(size: size, flipped: true) { _ in
            let storage = NSTextStorage(attributedString: text)
            let layoutManager = NSLayoutManager()
            let lineMetrics = TextAnnotationLineMetricsDelegate(fallbackFont: fallbackFont)
            let container = NSTextContainer(
                containerSize: NSSize(
                    width: max(0, size.width - inset.width * 2),
                    height: max(0, size.height - inset.height * 2)
                )
            )
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.delegate = lineMetrics
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let origin = NSPoint(x: inset.width, y: inset.height)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            return true
        }
    }

    static func stableLineMetrics(
        in layoutManager: NSLayoutManager,
        glyphRange: NSRange,
        fallbackFont: NSFont
    ) -> (height: CGFloat, baseline: CGFloat) {
        var height = ceil(layoutManager.defaultLineHeight(for: fallbackFont))
        var baseline = round(fallbackFont.ascender)

        guard glyphRange.length > 0, let storage = layoutManager.textStorage else {
            return (height, baseline)
        }
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        guard characterRange.length > 0,
              NSMaxRange(characterRange) <= storage.length else {
            return (height, baseline)
        }

        storage.enumerateAttribute(.font, in: characterRange) { value, _, _ in
            guard let font = value as? NSFont else { return }
            let candidateHeight = ceil(layoutManager.defaultLineHeight(for: font))
            let candidateBaseline = round(font.ascender)
            if candidateHeight > height {
                height = candidateHeight
                baseline = candidateBaseline
            } else if candidateHeight == height {
                baseline = max(baseline, candidateBaseline)
            }
        }
        return (height, baseline)
    }

    /// Places a new one-line editor so the system I-beam's center aligns with
    /// the insertion caret, instead of treating the pointer like an arrow tip.
    static func initialFrame(caretCenter: NSPoint, size: NSSize, inset: NSSize) -> NSRect {
        NSRect(
            x: caretCenter.x - inset.width,
            y: caretCenter.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func rect(
        preservingRotatedTopLeftOf oldRect: NSRect,
        newSize: NSSize,
        rotation: CGFloat
    ) -> NSRect {
        let oldCenter = NSPoint(x: oldRect.midX, y: oldRect.midY)
        let oldTopLeftOffset = rotate(
            NSPoint(x: -oldRect.width / 2, y: oldRect.height / 2),
            by: rotation
        )
        let fixedTopLeft = NSPoint(
            x: oldCenter.x + oldTopLeftOffset.x,
            y: oldCenter.y + oldTopLeftOffset.y
        )

        let newTopLeftOffset = rotate(
            NSPoint(x: -newSize.width / 2, y: newSize.height / 2),
            by: rotation
        )
        let newCenter = NSPoint(
            x: fixedTopLeft.x - newTopLeftOffset.x,
            y: fixedTopLeft.y - newTopLeftOffset.y
        )
        return NSRect(
            x: newCenter.x - newSize.width / 2,
            y: newCenter.y - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
    }

    private static func rotate(_ point: NSPoint, by angle: CGFloat) -> NSPoint {
        NSPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }
}
