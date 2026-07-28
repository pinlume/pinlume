import CoreGraphics

/// Chooses the display that owns a full-screen recording setup before the
/// asynchronous screenshot/overlay work begins. Keeping this decision as an
/// ID prevents multi-display routing from changing while the setup is in
/// flight.
enum FullScreenRecordingTarget {
    static func displayID(
        isMenuInvocation: Bool,
        mainDisplayID: CGDirectDisplayID?,
        pointerDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if isMenuInvocation {
            return mainDisplayID ?? pointerDisplayID
        }
        return pointerDisplayID ?? mainDisplayID
    }
}
