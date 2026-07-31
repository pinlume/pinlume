import Foundation

enum GlobalPinShortcutSource: Equatable {
    case transparentAnnotation
    case ordinarySelection
    case clipboard
    case blocked
}

enum GlobalPinShortcutRouting {
    static func route(
        hasTransparentAnnotationSession: Bool,
        hasOrdinarySelection: Bool,
        workflowAllowsOrdinaryPin: Bool
    ) -> GlobalPinShortcutSource {
        if hasTransparentAnnotationSession { return .transparentAnnotation }
        guard workflowAllowsOrdinaryPin else { return .blocked }
        return hasOrdinarySelection ? .ordinarySelection : .clipboard
    }
}

enum TransparentOutputAction {
    case copy
    case pin
    case save
}

enum TransparentOutputLifecycle {
    static func shouldFinish(
        action: TransparentOutputAction,
        saveSucceeded: Bool
    ) -> Bool {
        switch action {
        case .copy, .pin:
            return true
        case .save:
            return saveSucceeded
        }
    }
}

enum TransparentSessionCommandRoute: Equatable {
    case copy
    case save
    case passThrough
}

enum TransparentSessionCommandRouting {
    static func route(
        keyCode: UInt16,
        commandHeld: Bool,
        shiftHeld: Bool,
        optionHeld: Bool,
        controlHeld: Bool,
        isTextEditing: Bool
    ) -> TransparentSessionCommandRoute {
        guard commandHeld, !shiftHeld, !optionHeld, !controlHeld else {
            return .passThrough
        }
        switch keyCode {
        case 8 where !isTextEditing:
            return .copy
        case 1:
            return .save
        default:
            return .passThrough
        }
    }
}
