import AppKit
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("SuperMac.openMainWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let mainWindowRouter: MainWindowRouter

    override init() {
        mainWindowRouter = .shared
        super.init()
    }

    init(mainWindowRouter: MainWindowRouter) {
        self.mainWindowRouter = mainWindowRouter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.configureWindowBehavior()
        UNUserNotificationCenter.current().delegate = self
    }

    static func configureWindowBehavior() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowRouter.open()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
