import Foundation

enum UploadGatewayGate {
    static func performAfterConfirmation(_ confirmed: Bool, transport: () -> Void) -> Bool {
        guard confirmed else { return false }
        transport()
        return true
    }
}
