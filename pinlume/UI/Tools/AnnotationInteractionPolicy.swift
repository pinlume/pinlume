import Foundation

/// One source of truth for the short editing session that follows annotation creation.
enum AnnotationInteractionPolicy {
    static func selectsAfterCommit(tool: AnnotationTool, censorShape: CensorShape?) -> Bool {
        switch tool {
        case .pencil, .marker, .eraser, .text:
            return false
        case .pixelate, .blur:
            return censorShape != .brush
        default:
            return true
        }
    }

    static func canReselect(tool: AnnotationTool) -> Bool {
        tool == .text
    }
}
