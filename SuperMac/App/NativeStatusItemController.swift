import AppKit

@MainActor
final class MainWindowRouter {
    static let shared = MainWindowRouter()

    private var opener: (() -> Void)?
    private let activate: () -> Void

    init(activate: (() -> Void)? = nil) {
        self.activate = activate ?? {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func configure(_ opener: @escaping () -> Void) {
        self.opener = opener
    }

    @discardableResult
    func open() -> Bool {
        guard let opener else { return false }
        opener()
        activate()
        return true
    }
}

@MainActor
final class NativeStatusItemController: NSObject {
    static let shared = NativeStatusItemController()

    private var statusItem: NSStatusItem?
    private let router: MainWindowRouter

    init(router: MainWindowRouter? = nil) {
        self.router = router ?? .shared
        super.init()
    }

    func configureOpenMainWindow(_ action: @escaping () -> Void) {
        router.configure(action)
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            StatusItemBranding.configure(
                button,
                target: self,
                action: #selector(showMenu(_:))
            )
        }

        statusItem = item
    }

    @objc private func showMenu(_ sender: NSStatusBarButton) {
        let menu = makeMenu()
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let updates = menu.addItem(withTitle: "Check for Updates (Not Configured)", action: nil, keyEquivalent: "")
        updates.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SuperMac", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc func openSettings() {
        if !router.open() {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
