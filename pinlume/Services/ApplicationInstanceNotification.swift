import Foundation

enum ApplicationInstanceNotification {
    static func duplicateLaunchNotificationName(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("com.xiegang.Pinlume.showAndOpenPrefs.\(bundleIdentifier)")
    }
}
