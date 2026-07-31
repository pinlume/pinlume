import Foundation

enum OverlaySavePresentationState {
    case visible
    case hiddenForSavePanel
    case dismissed
}

enum OverlaySavePresentationGeometry {
    struct PanelPlan: Equatable {
        let keepsOverlayWindowVisible: Bool
        let usesOverlayWindowAsSheetHost: Bool
    }

    static func panelPlan() -> PanelPlan {
        PanelPlan(
            keepsOverlayWindowVisible: false,
            usesOverlayWindowAsSheetHost: false
        )
    }

    static func stateAfterOpeningSavePanel() -> OverlaySavePresentationState {
        .hiddenForSavePanel
    }

    static func stateAfterSavePanelResponse(success: Bool) -> OverlaySavePresentationState {
        success ? .dismissed : .visible
    }
}
