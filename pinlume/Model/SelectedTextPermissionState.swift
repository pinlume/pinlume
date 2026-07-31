import Foundation

enum SelectedTextPermissionAction: Equatable {
    case none
    case requestSystemPermission
    case explainClipboardFallback
}

struct SelectedTextPermissionState: Equatable {
    var initialRequestWasMade = false
    var isAwaitingInitialResult = false
    var userPreference: Bool?
    var hasShownTranslationExplanation = false

    mutating func beginInitialRequest(isAuthorized: Bool) -> SelectedTextPermissionAction {
        guard userPreference != false else { return .none }
        if isAuthorized {
            initialRequestWasMade = true
            isAwaitingInitialResult = false
            return .none
        }
        guard !initialRequestWasMade else { return .none }
        initialRequestWasMade = true
        isAwaitingInitialResult = true
        return .requestSystemPermission
    }

    mutating func reconcile(isAuthorized: Bool) {
        if isAwaitingInitialResult {
            isAwaitingInitialResult = false
        }
    }

    mutating func setUserPreference(enabled: Bool) {
        userPreference = enabled
        if !enabled {
            isAwaitingInitialResult = false
        }
    }

    mutating func settingsEnableAction(isAuthorized: Bool) -> SelectedTextPermissionAction {
        setUserPreference(enabled: true)
        initialRequestWasMade = true
        isAwaitingInitialResult = !isAuthorized
        return isAuthorized ? .none : .requestSystemPermission
    }

    mutating func translationWindowAction(isAuthorized: Bool) -> SelectedTextPermissionAction {
        reconcile(isAuthorized: isAuthorized)
        guard !isAuthorized,
              userPreference != false,
              !hasShownTranslationExplanation
        else { return .none }
        hasShownTranslationExplanation = true
        return .explainClipboardFallback
    }

    func isEffectivelyEnabled(isAuthorized: Bool) -> Bool {
        isAuthorized && userPreference != false
    }
}
