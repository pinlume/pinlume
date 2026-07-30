import Foundation

enum PinOpacityPolicy {
    static func displayedOpacity(storedOpacity: CGFloat, isCompact: Bool) -> CGFloat {
        isCompact ? 1 : clamped(storedOpacity)
    }

    static func adjustedOpacity(storedOpacity: CGFloat, by delta: CGFloat, isCompact: Bool) -> CGFloat? {
        guard !isCompact else { return nil }
        return clamped(storedOpacity + delta)
    }

    private static func clamped(_ opacity: CGFloat) -> CGFloat {
        min(1, max(0.10, opacity))
    }
}
