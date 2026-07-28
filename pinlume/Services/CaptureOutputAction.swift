import Foundation

/// The shared output choice for Return and Quick Capture. Legacy raw values
/// remain stable so existing installations keep their chosen behaviour.
enum CaptureOutputAction: Int, CaseIterable {
    case saveToFolder = 0
    case copyToClipboard = 1
    case saveAndCopy = 2
    case doNothing = 3
    case pinToScreen = 4

    static let userDefaultsKey = "quickCaptureMode"

    static func current(in defaults: UserDefaults = .standard) -> CaptureOutputAction {
        guard defaults.object(forKey: userDefaultsKey) != nil else { return .copyToClipboard }
        return CaptureOutputAction(rawValue: defaults.integer(forKey: userDefaultsKey)) ?? .copyToClipboard
    }

    var copiesToClipboard: Bool {
        self == .copyToClipboard || self == .saveAndCopy
    }

    var savesToFolder: Bool {
        self == .saveToFolder || self == .saveAndCopy
    }

    var pinsToScreen: Bool {
        self == .pinToScreen
    }
}
