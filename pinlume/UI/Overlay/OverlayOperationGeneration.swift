import Foundation

struct OverlayOperationToken: Equatable {
    let captureSession: UInt
    let operation: UInt
}

struct OverlayOperationGeneration {
    private(set) var captureSession: UInt = 0
    private(set) var operation: UInt = 0

    mutating func beginCaptureSession() {
        captureSession &+= 1
        operation &+= 1
    }

    mutating func beginOperation() -> OverlayOperationToken {
        operation &+= 1
        return OverlayOperationToken(captureSession: captureSession, operation: operation)
    }

    mutating func invalidateOperations() { operation &+= 1 }

    func contains(_ token: OverlayOperationToken) -> Bool {
        token.captureSession == captureSession && token.operation == operation
    }
}
