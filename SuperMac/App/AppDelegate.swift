import AppKit
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("SuperMac.openMainWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.configureWindowBehavior()
        UNUserNotificationCenter.current().delegate = self
    }

    static func configureWindowBehavior() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NativeStatusItemController.shared.openSettings()
        return false
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
