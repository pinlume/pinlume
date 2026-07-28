import Cocoa

/// Preferences for directional and modifier-driven interactions shared by the
/// capture overlay and pinned images. These are local interactions, not global
/// hotkeys, so they are only evaluated while Pinlume owns the focused canvas.
enum InteractionShortcutManager {
    enum Action: String, CaseIterable {
        case togglePixelInspector
        case togglePixelInspectorFormat
        case nudgeInspectorCursor
        case nudgeSelection
        case pinZoom
        case pinOpacity
        case closePin
        case compactPin

        var label: String {
            switch self {
            case .togglePixelInspector: return L("Hold to Show Magnifier")
            case .togglePixelInspectorFormat: return L("Switch Magnifier RGB/HEX")
            case .nudgeInspectorCursor: return L("Move Magnifier Sample Point 1 Pixel")
            case .nudgeSelection: return L("Move Selection 1 Pixel")
            case .pinZoom: return L("Pin Scroll Zoom")
            case .pinOpacity: return L("Pin Scroll Opacity")
            case .closePin: return L("Double-click to Close Pin")
            case .compactPin: return L("Double-click to Toggle Thumbnail")
            }
        }

        var defaultModifier: Modifier {
            Modifier(rawValue: SettingsProfileInteractionShortcutDefinitions.defaultModifiers[rawValue] ?? "none") ?? .none
        }
    }

    enum Modifier: String, CaseIterable {
        case none
        case command
        case option
        case shift
        case control

        var label: String {
            switch self {
            case .none: return L("None")
            case .command: return "Command"
            case .option: return "Option"
            case .shift: return "Shift"
            case .control: return "Control"
            }
        }

        var flags: NSEvent.ModifierFlags {
            switch self {
            case .none: return []
            case .command: return .command
            case .option: return .option
            case .shift: return .shift
            case .control: return .control
            }
        }
    }

    private static let keyPrefix = "interactionShortcutModifier."

    static func modifier(for action: Action) -> Modifier {
        guard let raw = UserDefaults.standard.string(forKey: keyPrefix + action.rawValue),
              let modifier = Modifier(rawValue: raw) else {
            return action.defaultModifier
        }
        return modifier
    }

    static func setModifier(_ modifier: Modifier, for action: Action) {
        UserDefaults.standard.set(modifier.rawValue, forKey: keyPrefix + action.rawValue)
    }

    /// Remove all per-action overrides so every interaction reads its default modifier.
    static func resetAllToDefaults() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: keyPrefix + action.rawValue)
        }
    }

    static func matchesArrow(_ event: NSEvent, action: Action) -> Bool {
        guard [123, 124, 125, 126].contains(event.keyCode) else { return false }
        return firstMatchingAction(for: event.modifierFlags, allowed: [.nudgeInspectorCursor, .nudgeSelection]) == action
    }

    static func matchesArrow(_ event: NSEvent, action: Action, whileHolding heldAction: Action) -> Bool {
        matchesArrow(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            action: action,
            whileHolding: heldAction
        )
    }

    static func matchesArrow(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        action: Action,
        whileHolding heldAction: Action
    ) -> Bool {
        guard [123, 124, 125, 126].contains(keyCode) else { return false }
        let expected = modifier(for: action).flags.union(modifier(for: heldAction).flags)
        return relevantModifiers(in: modifierFlags) == expected
    }

    static func firstArrowAction(_ flags: NSEvent.ModifierFlags) -> Action? {
        firstMatchingAction(for: flags, allowed: [.nudgeInspectorCursor, .nudgeSelection])
    }

    static func firstModifierAction(_ flags: NSEvent.ModifierFlags, among actions: Set<Action>) -> Action? {
        firstMatchingAction(for: flags, allowed: actions)
    }

    static func modifierIsDown(_ flags: NSEvent.ModifierFlags, action: Action) -> Bool {
        let modifier = modifier(for: action)
        guard modifier != .none else { return false }
        return firstMatchingAction(for: flags, allowed: conflictGroup(for: action)) == action
    }

    static func modifierIsHeld(_ flags: NSEvent.ModifierFlags, action: Action) -> Bool {
        let modifier = modifier(for: action)
        guard modifier != .none else { return false }
        return relevantModifiers(in: flags).contains(modifier.flags)
    }

    static func matchesModifiers(_ flags: NSEvent.ModifierFlags, action: Action) -> Bool {
        matchesModifiers(flags, action: action, among: [action])
    }

    static func matchesModifiers(_ flags: NSEvent.ModifierFlags, action: Action, among actions: Set<Action>) -> Bool {
        firstMatchingAction(for: flags, allowed: actions) == action
    }

    static func displayString(for action: Action) -> String {
        let modifier = modifier(for: action)
        switch action {
        case .togglePixelInspector, .togglePixelInspectorFormat:
            return modifier.label
        case .nudgeInspectorCursor, .nudgeSelection:
            return modifier == .none ? L("Arrow Keys") : "\(modifier.label) + \(L("Arrow Keys"))"
        case .pinZoom, .pinOpacity:
            return modifier == .none ? L("Mouse Wheel") : "\(modifier.label) + \(L("Mouse Wheel"))"
        case .closePin, .compactPin:
            return modifier == .none ? L("Double-click") : "\(modifier.label) + \(L("Double-click"))"
        }
    }

    private static func relevantModifiers(in flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .shift, .control])
    }

    private static func firstMatchingAction(for flags: NSEvent.ModifierFlags, allowed: Set<Action>) -> Action? {
        Action.allCases.first {
            allowed.contains($0) && relevantModifiers(in: flags) == modifier(for: $0).flags
        }
    }

    private static func conflictGroup(for action: Action) -> Set<Action> {
        switch action {
        case .togglePixelInspector, .togglePixelInspectorFormat:
            return [.togglePixelInspector, .togglePixelInspectorFormat]
        case .nudgeInspectorCursor, .nudgeSelection:
            return [.nudgeInspectorCursor, .nudgeSelection]
        case .pinZoom, .pinOpacity:
            return [.pinZoom, .pinOpacity]
        case .closePin, .compactPin:
            return [.closePin, .compactPin]
        }
    }
}
