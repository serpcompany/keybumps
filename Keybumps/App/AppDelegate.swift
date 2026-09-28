import AppKit
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("Keybumps.openMainWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let quickSearchRouter: QuickSearchRouter
    private let appShellRouter: AppShellRouter
    private let mainWindowRouter: MainWindowRouter
    private let confirmQuit: ([String]) -> Bool

    override init() {
        quickSearchRouter = .shared
        appShellRouter = .shared
        mainWindowRouter = .shared
        confirmQuit = Self.presentQuitConfirmation
        super.init()
    }

    /// Tests inject `confirmQuit`; by default it declines, so tests never show a dialog.
    init(
        quickSearchRouter: QuickSearchRouter,
        appShellRouter: AppShellRouter? = nil,
        mainWindowRouter: MainWindowRouter? = nil,
        confirmQuit: @escaping ([String]) -> Bool = { _ in false }
    ) {
        self.quickSearchRouter = quickSearchRouter
        self.appShellRouter = appShellRouter ?? .shared
        self.mainWindowRouter = mainWindowRouter ?? .shared
        self.confirmQuit = confirmQuit
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
        // Settings asked for the window before it ever existed: let SwiftUI create it.
        if mainWindowRouter.consumeReopenRequest() { return true }
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
        Self.terminateReply(
            reasons: UpdateInstallationSafetyPolicy.shared.quitConfirmationReasons,
            confirm: confirmQuit
        )
    }

    /// Quits at once unless work would be lost; then asks instead of silently refusing.
    static func terminateReply(reasons: [String], confirm: ([String]) -> Bool) -> NSApplication.TerminateReply {
        guard !reasons.isEmpty else { return .terminateNow }
        return confirm(reasons) ? .terminateNow : .terminateCancel
    }

    private static func presentQuitConfirmation(reasons: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit Keybumps?"
        alert.informativeText = (reasons + ["Quitting now will lose it."]).joined(separator: " ")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
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
              let destination = AppShellDestination.decode(rawDestination) else { return false }
        return appShellRouter.open(destination)
    }
}
