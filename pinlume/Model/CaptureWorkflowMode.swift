import Foundation

enum SelectableOCRToolbarAction: Equatable {
    case recognizeSelectableText
    case copyRecognizedText
    case pinSelectableText
}

enum CaptureWorkflowMode: Equatable {
    case standard
    case selectableOCR
    case screenTranslation

    var toolbarActions: [SelectableOCRToolbarAction] {
        switch self {
        case .standard:
            return []
        case .selectableOCR:
            return [.recognizeSelectableText, .copyRecognizedText, .pinSelectableText]
        case .screenTranslation:
            return []
        }
    }

    var allowsGlobalPinShortcut: Bool {
        self == .standard
    }
}

struct PendingCaptureWorkflow {
    private(set) var mode: CaptureWorkflowMode = .standard

    mutating func prepare(_ mode: CaptureWorkflowMode) {
        self.mode = mode
    }

    mutating func consume() -> CaptureWorkflowMode {
        defer { mode = .standard }
        return mode
    }

    mutating func reset() {
        mode = .standard
    }
}

enum SelectableOCRSessionPhase: Equatable {
    case idle
    case loading
    case active
}

struct SelectableOCRSession {
    private(set) var phase: SelectableOCRSessionPhase = .idle
    private var token = 0

    mutating func begin() -> Int {
        token &+= 1
        phase = .loading
        return token
    }

    @discardableResult
    mutating func activate(token expected: Int) -> Bool {
        guard phase == .loading, expected == token else { return false }
        phase = .active
        return true
    }

    @discardableResult
    mutating func fail(token expected: Int) -> Bool {
        guard phase == .loading, expected == token else { return false }
        reset()
        return true
    }

    mutating func reset() {
        token &+= 1
        phase = .idle
    }
}

enum SelectableOCRKeyRoute: Equatable {
    case escape
    case selectAllText
    case copyText
    case pin
    case blocked
}

enum SelectableOCRPointerRoute: Equatable {
    case resize
    case text
    case move
    case outside
}

enum SelectableOCRPointerGate {
    static func route(
        isHandle: Bool,
        isText: Bool,
        isInsideSelection: Bool
    ) -> SelectableOCRPointerRoute {
        if isHandle { return .resize }
        if isText { return .text }
        return isInsideSelection ? .move : .outside
    }
}

enum SelectableOCRInputGate {
    static func route(
        keyCode: UInt16,
        commandOnly: Bool,
        textSelectionActive: Bool
    ) -> SelectableOCRKeyRoute {
        if keyCode == 53 { return .escape }
        if textSelectionActive, (keyCode == 36 || keyCode == 76) { return .pin }
        guard commandOnly, textSelectionActive else { return .blocked }
        switch keyCode {
        case 0: return .selectAllText
        case 8: return .copyText
        default: return .blocked
        }
    }
}
