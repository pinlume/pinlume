import Foundation

/// State machine for a modifier-held pixel inspector.
///
/// A registered global shortcut may temporarily win while the modifier is
/// still physically down. In that case activation stays suppressed until the
/// matching modifier-up event arrives.
struct PixelInspectorHoldPolicy {
    enum Transition: Equatable {
        case unchanged
        case activated
        case deactivated
    }

    private(set) var isActive = false
    private(set) var isSuppressedUntilRelease = false
    private var modifierIsDown = false

    mutating func update(modifierIsDown: Bool, canActivate: Bool) -> Transition {
        self.modifierIsDown = modifierIsDown

        if !modifierIsDown {
            isSuppressedUntilRelease = false
            guard isActive else { return .unchanged }
            isActive = false
            return .deactivated
        }

        guard canActivate else {
            isSuppressedUntilRelease = true
            guard isActive else { return .unchanged }
            isActive = false
            return .deactivated
        }

        guard !isSuppressedUntilRelease else {
            guard isActive else { return .unchanged }
            isActive = false
            return .deactivated
        }

        guard !isActive else { return .unchanged }
        isActive = true
        return .activated
    }

    mutating func yieldToShortcut(modifierIsDown: Bool) -> Transition {
        self.modifierIsDown = self.modifierIsDown || modifierIsDown
        isSuppressedUntilRelease = self.modifierIsDown
        guard isActive else { return .unchanged }
        isActive = false
        return .deactivated
    }

    mutating func reset() {
        isActive = false
        isSuppressedUntilRelease = false
        modifierIsDown = false
    }
}
