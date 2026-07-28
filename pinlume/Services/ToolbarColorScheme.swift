import AppKit
import Foundation

struct ToolbarColorTriplet {
    let accent: NSColor
    let icon: NSColor
    let background: NSColor

    init(accent: UInt32, icon: UInt32, background: UInt32) {
        self.accent = Self.color(accent)
        self.icon = Self.color(icon)
        self.background = Self.color(background)
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum ToolbarColorSchemeID: String, CaseIterable {
    case graphiteBlue
    case midnightIndigo
    case deepTeal
    case amber
    case forest
    case mono
    case custom
}

struct ToolbarColorScheme {
    static let userDefaultsKey = "toolbarColorSchemeID"
    static let defaultID: ToolbarColorSchemeID = .graphiteBlue

    let id: ToolbarColorSchemeID
    let name: String
    let light: ToolbarColorTriplet
    let dark: ToolbarColorTriplet

    static let all: [ToolbarColorScheme] = [
        .init(
            id: .graphiteBlue,
            name: "Graphite Blue",
            light: .init(accent: 0x3C76F4, icon: 0x1F2937, background: 0xF8FAFC),
            dark: .init(accent: 0x3C76F4, icon: 0xE5E7EB, background: 0x111827)
        ),
        .init(
            id: .midnightIndigo,
            name: "Midnight Indigo",
            light: .init(accent: 0x4F46E5, icon: 0x1F2937, background: 0xF7F7FF),
            dark: .init(accent: 0xA5B4FC, icon: 0xEEF2FF, background: 0x17172B)
        ),
        .init(
            id: .deepTeal,
            name: "Deep Teal",
            light: .init(accent: 0x0F766E, icon: 0x1F2937, background: 0xF0FDFA),
            dark: .init(accent: 0x2DD4BF, icon: 0xCCFBF1, background: 0x102522)
        ),
        .init(
            id: .amber,
            name: "Amber",
            light: .init(accent: 0xB45309, icon: 0x292524, background: 0xFFFBEB),
            dark: .init(accent: 0xFBBF24, icon: 0xFFF7ED, background: 0x241A0E)
        ),
        .init(
            id: .forest,
            name: "Forest",
            light: .init(accent: 0x15803D, icon: 0x1F2937, background: 0xF3FBF5),
            dark: .init(accent: 0x4ADE80, icon: 0xDCFCE7, background: 0x102217)
        ),
        .init(
            id: .mono,
            name: "Monochrome",
            light: .init(accent: 0x475569, icon: 0x1F2937, background: 0xF8FAFC),
            dark: .init(accent: 0xCBD5E1, icon: 0xE2E8F0, background: 0x111827)
        ),
    ]

    static func scheme(for id: ToolbarColorSchemeID) -> ToolbarColorScheme? {
        all.first { $0.id == id }
    }

    static func currentID(in defaults: UserDefaults = .standard) -> ToolbarColorSchemeID {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let id = ToolbarColorSchemeID(rawValue: rawValue)
        else { return .custom }
        return id
    }

    static func bootstrapIfNeeded(
        in defaults: UserDefaults = .standard,
        appearance: NSAppearance
    ) {
        guard defaults.string(forKey: userDefaultsKey) == nil else {
            applyCurrentAppearance(in: defaults, appearance: appearance)
            return
        }
        let hasLegacyColors = ["toolbarAccentColor", "toolbarIconColor", "toolbarBgColor"].contains {
            defaults.object(forKey: $0) != nil
        }
        defaults.set((hasLegacyColors ? ToolbarColorSchemeID.custom : defaultID).rawValue, forKey: userDefaultsKey)
        applyCurrentAppearance(in: defaults, appearance: appearance)
    }

    static func select(
        _ id: ToolbarColorSchemeID,
        in defaults: UserDefaults = .standard,
        appearance: NSAppearance
    ) {
        defaults.set(id.rawValue, forKey: userDefaultsKey)
        applyCurrentAppearance(in: defaults, appearance: appearance)
    }

    static func selectCustom(in defaults: UserDefaults = .standard) {
        defaults.set(ToolbarColorSchemeID.custom.rawValue, forKey: userDefaultsKey)
    }

    static func applyCurrentAppearance(
        in defaults: UserDefaults = .standard,
        appearance: NSAppearance
    ) {
        guard let scheme = scheme(for: currentID(in: defaults)) else { return }
        apply(scheme.colors(for: appearance), in: defaults)
    }

    func colors(for appearance: NSAppearance) -> ToolbarColorTriplet {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    private static func apply(_ colors: ToolbarColorTriplet, in defaults: UserDefaults) {
        save(colors.accent, forKey: "toolbarAccentColor", in: defaults)
        save(colors.icon, forKey: "toolbarIconColor", in: defaults)
        save(colors.background, forKey: "toolbarBgColor", in: defaults)
        NotificationCenter.default.post(name: Notification.Name("toolbarColorsDidChange"), object: nil)
    }

    private static func save(_ color: NSColor, forKey key: String, in defaults: UserDefaults) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) else { return }
        defaults.set(data, forKey: key)
    }
}
