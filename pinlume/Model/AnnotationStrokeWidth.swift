import CoreGraphics

enum AnnotationStrokeWidth {
    static let minimum: CGFloat = 1
    static let maximum: CGFloat = 20

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}
