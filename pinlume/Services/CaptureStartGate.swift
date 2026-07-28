import Foundation

enum CaptureStartRequest {
    case screenshot
    case recording
}

enum CaptureStartGate {
    static func canBeginCapture(
        isCapturing: Bool,
        isRecording: Bool,
        request: CaptureStartRequest
    ) -> Bool {
        guard !isCapturing else { return false }
        return !isRecording || request == .screenshot
    }
}
