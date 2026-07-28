import Cocoa

enum ApplicationAppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let userDefaultsKey = "applicationAppearance"

    static func current(in defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let preference = Self(rawValue: rawValue)
        else { return .system }
        return preference
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    static func applyCurrent() {
        NSApp.appearance = current().appearanceName.flatMap { NSAppearance(named: $0) }
    }
}
