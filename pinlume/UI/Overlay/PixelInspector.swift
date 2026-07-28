import Cocoa

enum PixelInspectorDisplayMode: String {
    case hex
    case rgb

    mutating func toggle() {
        self = self == .hex ? .rgb : .hex
    }
}

struct PixelInspectorSample {
    let color: NSColor
    let hex: String
    let rgb: String
    let imagePoint: NSPoint
    let imagePixel: NSPoint
}

enum PixelInspector {
    static let previewSourceSize = NSSize(width: 19, height: 13)

    static func sample(
        image: NSImage,
        viewPoint: NSPoint,
        imageRect: NSRect
    ) -> PixelInspectorSample? {
        guard imageRect.width > 0, imageRect.height > 0,
              imageRect.contains(viewPoint),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let normalizedX = (viewPoint.x - imageRect.minX) / imageRect.width
        let normalizedY = (viewPoint.y - imageRect.minY) / imageRect.height
        let imagePoint = NSPoint(
            x: normalizedX * image.size.width,
            y: normalizedY * image.size.height
        )
        let cgX = min(cgImage.width - 1, max(0, Int(normalizedX * CGFloat(cgImage.width))))
        let cgY = min(cgImage.height - 1, max(0, Int((1 - normalizedY) * CGFloat(cgImage.height))))

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            cgImage,
            in: CGRect(
                x: -CGFloat(cgX),
                y: -(CGFloat(cgImage.height) - 1 - CGFloat(cgY)),
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        )
        guard let data = context.data else { return nil }
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        let alpha = CGFloat(pointer[3]) / 255
        guard alpha > 0 else { return nil }
        let r = UInt8(min(255, CGFloat(pointer[0]) / alpha))
        let g = UInt8(min(255, CGFloat(pointer[1]) / alpha))
        let b = UInt8(min(255, CGFloat(pointer[2]) / alpha))
        let color = NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
        return PixelInspectorSample(
            color: color,
            hex: String(format: "#%02X%02X%02X", r, g, b),
            rgb: "\(r), \(g), \(b)",
            imagePoint: imagePoint,
            imagePixel: NSPoint(x: cgX, y: cgY)
        )
    }

    static func nudgedViewPoint(
        from point: NSPoint,
        keyCode: UInt16,
        image: NSImage,
        imageRect: NSRect
    ) -> NSPoint {
        let step = viewStepForImagePixel(image: image, imageRect: imageRect)
        let delta: NSPoint
        switch keyCode {
        case 123: delta = NSPoint(x: -step.width, y: 0)
        case 124: delta = NSPoint(x: step.width, y: 0)
        case 125: delta = NSPoint(x: 0, y: -step.height)
        default: delta = NSPoint(x: 0, y: step.height)
        }
        let maxPoint = NSPoint(
            x: max(imageRect.minX, imageRect.maxX - step.width),
            y: max(imageRect.minY, imageRect.maxY - step.height)
        )
        return NSPoint(
            x: min(max(point.x + delta.x, imageRect.minX), maxPoint.x),
            y: min(max(point.y + delta.y, imageRect.minY), maxPoint.y)
        )
    }

    static func warpMouse(toScreenPoint screenPoint: NSPoint) {
        let union = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        guard !union.isNull else { return }
        let quartzPoint = CGPoint(x: screenPoint.x, y: union.maxY - screenPoint.y)
        CGWarpMouseCursorPosition(quartzPoint)
    }

    private static func viewStepForImagePixel(image: NSImage, imageRect: NSRect) -> NSSize {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0,
              cgImage.height > 0
        else {
            return NSSize(width: 1, height: 1)
        }
        return NSSize(
            width: imageRect.width / CGFloat(cgImage.width),
            height: imageRect.height / CGFloat(cgImage.height)
        )
    }

    static func drawCrosshair(at point: NSPoint, bounds: NSRect) {
        NSColor.black.withAlphaComponent(0.9).setStroke()
        let horizontal = NSBezierPath()
        horizontal.lineWidth = 0.5
        horizontal.move(to: NSPoint(x: bounds.minX, y: point.y))
        horizontal.line(to: NSPoint(x: bounds.maxX, y: point.y))
        horizontal.stroke()

        let vertical = NSBezierPath()
        vertical.lineWidth = 0.5
        vertical.move(to: NSPoint(x: point.x, y: bounds.minY))
        vertical.line(to: NSPoint(x: point.x, y: bounds.maxY))
        vertical.stroke()
    }
}

final class PixelInspectorPanelController {
    private let panel: NSPanel
    private let inspectorView = PixelInspectorPanelView(frame: .zero)
    private var currentSample: PixelInspectorSample?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PixelInspectorPanelView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.contentView = inspectorView
    }

    func show(
        image: NSImage,
        viewPoint: NSPoint,
        imageRect: NSRect,
        screenPoint: NSPoint,
        visibleFrame: NSRect,
        displayMode: PixelInspectorDisplayMode
    ) {
        guard let sample = PixelInspector.sample(image: image, viewPoint: viewPoint, imageRect: imageRect) else {
            hide()
            return
        }
        currentSample = sample
        inspectorView.image = image
        inspectorView.sample = sample
        inspectorView.displayMode = displayMode

        let size = PixelInspectorPanelView.preferredSize
        let gap: CGFloat = 14
        var origin = NSPoint(x: screenPoint.x + gap, y: screenPoint.y - size.height - gap)
        if origin.x + size.width > visibleFrame.maxX - 8 {
            origin.x = screenPoint.x - size.width - gap
        }
        if origin.y < visibleFrame.minY + 8 {
            origin.y = screenPoint.y + gap
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        inspectorView.needsDisplay = true
    }

    func hide() {
        currentSample = nil
        panel.orderOut(nil)
    }

    func copyCurrentValue(displayMode: PixelInspectorDisplayMode) -> String? {
        guard let currentSample else { return nil }
        let value = displayMode == .hex ? currentSample.hex : currentSample.rgb
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        return value
    }

    deinit {
        panel.orderOut(nil)
    }
}

private final class PixelInspectorPanelView: NSView {
    static let preferredSize = NSSize(width: 152, height: 196)
    var image: NSImage?
    var sample: PixelInspectorSample?
    var displayMode: PixelInspectorDisplayMode = .hex

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let sample else { return }
        let zoomRect = NSRect(x: 0, y: 92, width: 152, height: 104)
        drawZoomedImage(image: image, sample: sample, in: zoomRect)
        drawLabel(sample: sample, mode: displayMode, in: NSRect(x: 0, y: 0, width: 152, height: 92))
    }

    private func drawZoomedImage(image: NSImage, sample: PixelInspectorSample, in rect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(rect: rect).fill()
        let sourceWidth = PixelInspector.previewSourceSize.width
        let sourceHeight = PixelInspector.previewSourceSize.height
        let selectedImagePoint = NSPoint(
            x: floor(sample.imagePoint.x),
            y: floor(sample.imagePoint.y)
        )
        let source = NSRect(
            x: selectedImagePoint.x - floor(sourceWidth / 2),
            y: selectedImagePoint.y - floor(sourceHeight / 2),
            width: sourceWidth,
            height: sourceHeight
        )
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: rect, from: source, operation: .copy, fraction: 1)

        NSColor.black.withAlphaComponent(0.75).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let pixelSize = rect.width / sourceWidth
        let selected = NSRect(
            x: rect.midX - pixelSize / 2,
            y: rect.midY - pixelSize / 2,
            width: pixelSize,
            height: pixelSize
        )
        ToolbarLayout.accentColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: selected.midY - 1, width: selected.minX - rect.minX, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: selected.maxX, y: selected.midY - 1, width: rect.maxX - selected.maxX, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: selected.midX - 1, y: rect.minY, width: 2, height: selected.minY - rect.minY)).fill()
        NSBezierPath(rect: NSRect(x: selected.midX - 1, y: selected.maxY, width: 2, height: rect.maxY - selected.maxY)).fill()

        NSColor.black.setStroke()
        let centerPath = NSBezierPath(rect: selected.insetBy(dx: 0.5, dy: 0.5))
        centerPath.lineWidth = 1.5
        centerPath.stroke()
    }

    private func drawLabel(sample: PixelInspectorSample, mode: PixelInspectorDisplayMode, in rect: NSRect) {
        NSColor(calibratedWhite: 0.10, alpha: 0.84).setFill()
        NSBezierPath(rect: rect).fill()

        let value = mode == .hex ? sample.hex : "RGB(\(sample.rgb))"
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let hintSmallAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]

        let coordinate = "(\(Int(sample.imagePixel.x)), \(Int(sample.imagePixel.y)))"
        drawCentered(coordinate, in: NSRect(x: rect.minX, y: rect.maxY - 23, width: rect.width, height: 16), attributes: valueAttrs)

        let valueSize = (value as NSString).size(withAttributes: valueAttrs)
        let swatchSize: CGFloat = 15
        let gap: CGFloat = 7
        let groupWidth = swatchSize + gap + valueSize.width
        let groupMinX = rect.midX - groupWidth / 2
        let swatch = NSRect(x: groupMinX, y: rect.maxY - 43, width: swatchSize, height: swatchSize)
        sample.color.setFill()
        NSBezierPath(rect: swatch).fill()
        NSColor.white.setStroke()
        NSBezierPath(rect: swatch.insetBy(dx: -0.5, dy: -0.5)).stroke()

        (value as NSString).draw(at: NSPoint(x: swatch.maxX + gap, y: rect.maxY - 44), withAttributes: valueAttrs)
        drawCentered(L("Press C to copy color"), in: NSRect(x: rect.minX, y: rect.minY + 32, width: rect.width, height: 14), attributes: hintAttrs)
        drawCentered(
            String(
                format: L("Release %@ to hide magnifier"),
                InteractionShortcutManager.displayString(for: .togglePixelInspector)
            ),
            in: NSRect(x: rect.minX, y: rect.minY + 17, width: rect.width, height: 14),
            attributes: hintSmallAttrs
        )
        drawCentered(
            String(
                format: L("Press %@ to switch RGB/HEX"),
                InteractionShortcutManager.displayString(for: .togglePixelInspectorFormat)
            ),
            in: NSRect(x: rect.minX, y: rect.minY + 3, width: rect.width, height: 14),
            attributes: hintSmallAttrs
        )
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let size = (text as NSString).size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}
