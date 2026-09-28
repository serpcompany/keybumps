import AppKit

@MainActor
final class MainWindowRouter {
    /// The app's router. Before the main window has ever appeared (macOS can relaunch Keybumps at
    /// login with no window), it asks macOS to reopen the app so SwiftUI creates the window.
    static let shared = MainWindowRouter(openWithoutWindow: { router in
        router.requestWindowOnNextReopen()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    })

    private var opener: (() -> Void)?
    private let activate: () -> Void
    private let openWithoutWindow: ((MainWindowRouter) -> Void)?
    private var opensWindowOnNextReopen = false

    init(activate: (() -> Void)? = nil, openWithoutWindow: ((MainWindowRouter) -> Void)? = nil) {
        self.activate = activate ?? {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        self.openWithoutWindow = openWithoutWindow
    }

    func configure(_ opener: @escaping () -> Void) {
        self.opener = opener
    }

    @discardableResult
    func open() -> Bool {
        guard let opener else {
            guard let openWithoutWindow else { return false }
            openWithoutWindow(self)
            return true
        }
        opener()
        activate()
        return true
    }

    /// Whether the next app reopen should let SwiftUI create the main window instead of routing
    /// to Quick Search. Reading it clears it.
    func consumeReopenRequest() -> Bool {
        defer { opensWindowOnNextReopen = false }
        return opensWindowOnNextReopen
    }

    func requestWindowOnNextReopen() {
        opensWindowOnNextReopen = true
    }
}

@MainActor
final class QuickSearchRouter {
    static let shared = QuickSearchRouter()

    private var opener: (() -> Void)?

    func configure(_ opener: @escaping () -> Void) {
        self.opener = opener
    }

    @discardableResult
    func open() -> Bool {
        guard let opener else { return false }
        opener()
        return true
    }
}

@MainActor
final class AppShellRouter {
    static let shared = AppShellRouter()

    private var opener: ((AppShellDestination) -> Void)?
    private var pendingDestination: AppShellDestination?
    private var lastExplicitOpenAt = Date.distantPast
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var shouldSuppressGenericReopen: Bool {
        now().timeIntervalSince(lastExplicitOpenAt) < 1
    }

    func configure(_ opener: @escaping (AppShellDestination) -> Void) {
        self.opener = opener
        if let pendingDestination {
            self.pendingDestination = nil
            opener(pendingDestination)
        }
    }

    @discardableResult
    func open(_ destination: AppShellDestination) -> Bool {
        lastExplicitOpenAt = now()
        guard let opener else {
            pendingDestination = destination
            return true
        }
        opener(destination)
        return true
    }
}

@MainActor
final class NativeStatusItemController: NSObject, NSMenuDelegate {
    static let shared = NativeStatusItemController()

    private var statusItem: NSStatusItem?
    private let router: MainWindowRouter
    private var quickSearchIsVisible: () -> Bool = { false }
    private var setQuickSearchVisible: (Bool) -> Void = { _ in }
    private var quickSearchWasVisibleWhenMenuOpened = false
    private var updateSnapshot: () -> UpdateSnapshot = {
        UpdateSnapshot(status: .unavailable("Updates unavailable"), automaticallyChecks: false, canCheck: false, canRestart: false)
    }
    private var checkForUpdatesAction: () -> Void = {}
    private var restartToUpdateAction: () -> Void = {}

    init(router: MainWindowRouter? = nil) {
        self.router = router ?? .shared
        super.init()
    }

    func configureOpenMainWindow(_ action: @escaping () -> Void) {
        router.configure(action)
    }

    func configureQuickSearch(
        isVisible: @escaping () -> Bool,
        setVisible: @escaping (Bool) -> Void
    ) {
        quickSearchIsVisible = isVisible
        setQuickSearchVisible = setVisible
    }

    func configureUpdater(
        snapshot: @escaping () -> UpdateSnapshot,
        checkNow: @escaping () -> Void,
        restartWhenSafe: @escaping () -> Void
    ) {
        updateSnapshot = snapshot
        checkForUpdatesAction = checkNow
        restartToUpdateAction = restartWhenSafe
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            StatusItemBranding.configure(
                button,
                target: self,
                action: #selector(toggleQuickSearch)
            )
        }

        item.menu = makeMenu()
        statusItem = item
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Toggle Keybumps", action: #selector(toggleQuickSearch), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let version = menu.addItem(withTitle: AppVersionDisplay.title(), action: nil, keyEquivalent: "")
        version.isEnabled = false
        let snapshot = updateSnapshot()
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = snapshot.canCheck
        if snapshot.canRestart {
            let restart = menu.addItem(withTitle: "Restart to Update", action: #selector(restartToUpdate), keyEquivalent: "")
            restart.target = self
            restart.isEnabled = true
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keybumps", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func toggleQuickSearch() {
        setQuickSearchVisible(!quickSearchWasVisibleWhenMenuOpened)
    }

    func menuWillOpen(_ menu: NSMenu) {
        quickSearchWasVisibleWhenMenuOpened = quickSearchIsVisible()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    @objc func openSettings() {
        if !router.open() {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }
    @objc private func checkForUpdates() { checkForUpdatesAction() }
    @objc private func restartToUpdate() { restartToUpdateAction() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
