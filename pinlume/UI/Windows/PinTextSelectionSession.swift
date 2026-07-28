import Foundation

enum PinTextSelectionPhase: Equatable {
    case inactive
    case loading
    case active
}

enum PinTextSelectionPointerRoute: Equatable {
    case text
    case exitSelection
    case movePin
}

enum PinTextSelectionPointerGate {
    static func route(isText: Bool, keepsOCRActive: Bool) -> PinTextSelectionPointerRoute {
        if isText { return .text }
        return keepsOCRActive ? .movePin : .exitSelection
    }
}

struct PinTextSelectionSession {
    private(set) var phase: PinTextSelectionPhase = .inactive
    private var currentToken = 0

    var suspendsPinInteraction: Bool {
        phase != .inactive
    }

    mutating func beginLoading() -> Int {
        currentToken &+= 1
        phase = .loading
        return currentToken
    }

    @discardableResult
    mutating func activate(ifCurrent token: Int) -> Bool {
        guard phase == .loading, token == currentToken else { return false }
        phase = .active
        return true
    }

    @discardableResult
    mutating func fail(ifCurrent token: Int) -> Bool {
        guard phase == .loading, token == currentToken else { return false }
        exit()
        return true
    }

    mutating func exit() {
        currentToken &+= 1
        phase = .inactive
    }

    func shouldExit(forKeyCode keyCode: UInt16) -> Bool {
        suspendsPinInteraction && keyCode == 53
    }
}
