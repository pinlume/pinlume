import Foundation

enum SettingsProfileRuntimeError: Error, Equatable {
    case globalHotkeyConflict([Int])
    case toolShortcutConflict([String])
    case invalidToolShortcut(String)
    case interactionShortcutConflict([String])
}

struct SettingsProfileRuntimeRefreshActions {
    let reregisterGlobalHotkeys: () -> Void
    let rebuildStatusMenu: () -> Void
}

extension Notification.Name {
    static let settingsProfileDidApply = Notification.Name("Pinlume.settingsProfileDidApply")
}

/// Validates shortcut ownership before settings are written, then performs the
/// two shared app-level refreshes exactly once after a successful transaction.
@MainActor
final class SettingsProfileRuntimeCoordinator {
    private let refreshActions: SettingsProfileRuntimeRefreshActions

    init(refreshActions: SettingsProfileRuntimeRefreshActions) {
        self.refreshActions = refreshActions
    }

    func preflightHotkeys(_ payload: SettingsProfilePayload) throws {
        try validateGlobalHotkeys(in: payload)
        try validateToolShortcuts(in: payload)
        try validateInteractionShortcuts(in: payload)
    }

    func refreshAfterApply() {
        refreshActions.reregisterGlobalHotkeys()
        refreshActions.rebuildStatusMenu()
        NotificationCenter.default.post(name: .settingsProfileDidApply, object: nil)
    }

    private func validateGlobalHotkeys(in payload: SettingsProfilePayload) throws {
        var owners: [GlobalHotkey: Int] = [:]
        var conflictSlots = Set<Int>()

        for definition in SettingsProfileHotkeyDefinition.all {
            let prefix = "hotkey.\(definition.slot)"
            let keyCode = integerValue(for: "\(prefix).keyCode", in: payload) ?? definition.defaultKeyCode
            let modifiers = integerValue(for: "\(prefix).modifiers", in: payload) ?? definition.defaultModifiers
            let disabled = boolValue(for: "\(prefix).disabled", in: payload) ?? definition.defaultDisabled
            guard !disabled,
                  modifiers != 0 || SettingsProfileHotkeyDefinition.functionKeyCodes.contains(keyCode)
            else { continue }

            let shortcut = GlobalHotkey(keyCode: keyCode, modifiers: modifiers)
            if let owner = owners[shortcut] {
                conflictSlots.insert(owner)
                conflictSlots.insert(definition.slot)
            } else {
                owners[shortcut] = definition.slot
            }
        }

        guard conflictSlots.isEmpty else {
            throw SettingsProfileRuntimeError.globalHotkeyConflict(conflictSlots.sorted())
        }
    }

    private func validateToolShortcuts(in payload: SettingsProfilePayload) throws {
        var configured = SettingsProfileToolShortcutDefinitions.defaultKeys
        if case .stringMap(let values)? = payload.values["overlayToolShortcuts"] {
            for (actionID, shortcut) in values where configured[actionID] != nil {
                configured[actionID] = shortcut
            }
        }

        var owners: [String: String] = [:]
        var conflicts = Set<String>()
        for actionID in configured.keys.sorted() {
            let shortcut = configured[actionID] ?? ""
            guard !shortcut.isEmpty else { continue }
            guard shortcut.count == 1 else {
                throw SettingsProfileRuntimeError.invalidToolShortcut(actionID)
            }
            let normalizedShortcut = shortcut.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if let owner = owners[normalizedShortcut] {
                conflicts.insert(owner)
                conflicts.insert(actionID)
            } else {
                owners[normalizedShortcut] = actionID
            }
        }

        guard conflicts.isEmpty else {
            throw SettingsProfileRuntimeError.toolShortcutConflict(conflicts.sorted())
        }
    }

    private func validateInteractionShortcuts(in payload: SettingsProfilePayload) throws {
        var configured = SettingsProfileInteractionShortcutDefinitions.defaultModifiers
        for actionID in configured.keys {
            let key = "interactionShortcutModifier.\(actionID)"
            if case .string(let modifier)? = payload.values[key] {
                configured[actionID] = modifier
            }
        }

        for group in SettingsProfileInteractionShortcutDefinitions.conflictGroups {
            var owners: [String: String] = [:]
            var conflicts = Set<String>()
            for actionID in group {
                guard let modifier = configured[actionID] else { continue }
                if let owner = owners[modifier] {
                    conflicts.insert(owner)
                    conflicts.insert(actionID)
                } else {
                    owners[modifier] = actionID
                }
            }
            if !conflicts.isEmpty {
                throw SettingsProfileRuntimeError.interactionShortcutConflict(conflicts.sorted())
            }
        }
    }

    private func integerValue(for key: String, in payload: SettingsProfilePayload) -> Int? {
        guard case .integer(let value)? = payload.values[key] else { return nil }
        return value
    }

    private func boolValue(for key: String, in payload: SettingsProfilePayload) -> Bool? {
        guard case .bool(let value)? = payload.values[key] else { return nil }
        return value
    }
}

private struct GlobalHotkey: Hashable {
    let keyCode: Int
    let modifiers: Int
}
