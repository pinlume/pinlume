import Cocoa

extension OverlayView {
    func drawWindowSnapHighlight() {
        let canDrawHighlight = state == .idle
            || (state == .selecting && selectionRect.width < 1 && selectionRect.height < 1)
        guard canDrawHighlight, windowSnapEnabled, let rect = hoveredWindowRect, !rect.isEmpty else {
            return
        }

        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).setClip()
            if usesExternalScreenshotPreview {
                context.cgContext.setBlendMode(.clear)
                NSBezierPath(rect: rect).fill()
            } else if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }
            context.restoreGraphicsState()
        }

        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        border.stroke()
    }
}
