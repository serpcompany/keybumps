import AppKit
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("SuperMac.openMainWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let quickSearchRouter: QuickSearchRouter
    private let appShellRouter: AppShellRouter

    override init() {
        quickSearchRouter = .shared
        appShellRouter = .shared
        super.init()
    }

    init(
        quickSearchRouter: QuickSearchRouter,
        appShellRouter: AppShellRouter? = nil
    ) {
        self.quickSearchRouter = quickSearchRouter
        self.appShellRouter = appShellRouter ?? .shared
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
            guard let self,
                  !self.appShellRouter.shouldSuppressGenericReopen else { return }
            self.quickSearchRouter.open()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateInstallationSafetyPolicy.shared.isSafeToInstall ? .terminateNow : .terminateCancel
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        _ = handleNotificationResponse(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    @discardableResult
    func handleNotificationResponse(userInfo: [AnyHashable: Any]) -> Bool {
        guard let rawDestination = userInfo[NativeNotificationPayload.destinationKey] as? String,
              let destination = AppShellDestination(rawValue: rawDestination) else { return false }
        return appShellRouter.open(destination)
    }
}
