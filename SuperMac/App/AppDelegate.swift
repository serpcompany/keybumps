import AppKit
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("SuperMac.openMainWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let quickSearchRouter: QuickSearchRouter

    override init() {
        quickSearchRouter = .shared
        super.init()
    }

    init(quickSearchRouter: QuickSearchRouter) {
        self.quickSearchRouter = quickSearchRouter
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
        DispatchQueue.main.async { [weak self] in
            self?.quickSearchRouter.open()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationTerminationGuard.shared.isSafeToTerminate ? .terminateNow : .terminateCancel
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
