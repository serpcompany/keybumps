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
final class NativeStatusItemController: NSObject {
    static let shared = NativeStatusItemController()

    private var statusItem: NSStatusItem?
    private let router: MainWindowRouter
    private let quickSearchRouter: QuickSearchRouter

    init(
        router: MainWindowRouter? = nil,
        quickSearchRouter: QuickSearchRouter? = nil
    ) {
        self.router = router ?? .shared
        self.quickSearchRouter = quickSearchRouter ?? .shared
        super.init()
    }

    func configureOpenMainWindow(_ action: @escaping () -> Void) {
        router.configure(action)
    }

    func configureOpenQuickSearch(_ action: @escaping () -> Void) {
        quickSearchRouter.configure(action)
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            StatusItemBranding.configure(
                button,
                target: self,
                action: #selector(handleStatusItemClick(_:))
            )
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.openQuickSearch()
            }
        }
    }

    private func showMenu(from sender: NSStatusBarButton) {
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Quick Search", action: #selector(openQuickSearch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let updates = menu.addItem(withTitle: "Check for Updates (Not Configured)", action: nil, keyEquivalent: "")
        updates.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SuperMac", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc func openQuickSearch() {
        quickSearchRouter.open()
    }

    @objc func openSettings() {
        if !router.open() {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
