import Foundation

enum OverlaySavePresentationState {
    case visible
    case hiddenForSavePanel
    case dismissed
}

enum OverlaySavePresentationGeometry {
    static func stateAfterOpeningSavePanel() -> OverlaySavePresentationState {
        .hiddenForSavePanel
    }

    static func stateAfterSavePanelResponse(success: Bool) -> OverlaySavePresentationState {
        success ? .dismissed : .visible
    }
}
