import AppKit

/// Contrast is a stable property of the active foreground color. It is never
/// derived from screenshot pixels while the pointer moves.
enum CursorContrastStyle: Int, Hashable {
    case none
    case darkOutline
    case lightOutline

    static func fixed(forForeground color: NSColor) -> CursorContrastStyle {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .lightOutline }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return luminance < 0.5 ? .lightOutline : .darkOutline
    }
}
