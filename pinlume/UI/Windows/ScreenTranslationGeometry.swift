import AppKit

enum ScreenTranslationGeometry {
    static func samplePixelRect(normalizedBox: CGRect, pixelSize: CGSize) -> CGRect {
        CGRect(x: normalizedBox.minX * pixelSize.width,
               y: (1 - normalizedBox.maxY) * pixelSize.height,
               width: normalizedBox.width * pixelSize.width,
               height: normalizedBox.height * pixelSize.height)
    }
    static func comparisonFrame(primary: NSRect, visibleFrame: NSRect) -> NSRect? {
        let candidates = [
            NSRect(x: primary.minX, y: primary.maxY, width: primary.width, height: primary.height),
            NSRect(x: primary.minX, y: primary.minY - primary.height, width: primary.width, height: primary.height),
            NSRect(x: primary.maxX, y: primary.minY, width: primary.width, height: primary.height),
            NSRect(x: primary.minX - primary.width, y: primary.minY, width: primary.width, height: primary.height),
        ]
        return candidates.first { visibleFrame.contains($0) }
    }
}
