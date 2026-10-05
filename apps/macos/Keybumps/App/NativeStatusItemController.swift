import AppKit
import Carbon.HIToolbox

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
    private var requestedSection: SettingsSection?

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

    /// Opens Settings on `section`, or where it was left when nil. An open window takes the page at
    /// once (`settingsSectionRequested`); a window created for it takes it when it appears. Either
    /// way it comes from `consumeRequestedSection()`, so it is shown once.
    @discardableResult
    func open(_ section: SettingsSection?) -> Bool {
        requestedSection = section
        let opened = open()
        if section != nil {
            NotificationCenter.default.post(name: .settingsSectionRequested, object: self)
        }
        return opened
    }

    /// The page Settings was asked to show and hasn't shown yet. Reading it clears it.
    func consumeRequestedSection() -> SettingsSection? {
        defer { requestedSection = nil }
        return requestedSection
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
final class NativeStatusItemController: NSObject, NSMenuDelegate {
    static let shared = NativeStatusItemController()

    private var statusItem: NSStatusItem?
    private let router: MainWindowRouter
    private var quickSearchIsVisible: () -> Bool = { false }
    private var setQuickSearchVisible: (Bool) -> Void = { _ in }
    private var quickSearchShortcut: () -> ShortcutBinding? = { nil }
    private var quickSearchWasVisibleWhenMenuOpened = false
    private var updateSnapshot: () -> UpdateSnapshot = {
        UpdateSnapshot(status: .unavailable("Updates unavailable"), automaticallyChecks: false, canCheck: false, canRestart: false)
    }
    private var checkForUpdatesAction: () -> Void = {}
    private var restartToUpdateAction: () -> Void = {}
    private var attention: MenuBarAttention?

    init(router: MainWindowRouter? = nil) {
        self.router = router ?? .shared
        super.init()
    }

    func configureOpenMainWindow(_ action: @escaping () -> Void) {
        router.configure(action)
    }

    func configureQuickSearch(
        isVisible: @escaping () -> Bool,
        setVisible: @escaping (Bool) -> Void,
        shortcut: @escaping () -> ShortcutBinding? = { nil }
    ) {
        quickSearchIsVisible = isVisible
        setQuickSearchVisible = setVisible
        quickSearchShortcut = shortcut
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

    /// The red dot's source: updates and capability modules set their reasons on it.
    func configureAttention(_ attention: MenuBarAttention) {
        self.attention = attention
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

    /// Shows or hides the red dot on the menu bar icon, and names its reasons for VoiceOver. Called
    /// whenever `MenuBarAttention` changes.
    func refreshAttentionDot() {
        guard let button = statusItem?.button else { return }
        let identifier = NSUserInterfaceItemIdentifier("attentionDot")
        let badge = button.subviews.first { $0.identifier == identifier }
        let productName = ReleaseLane.current.productName
        button.setAccessibilityLabel(attention?.accessibilityLabel(productName: productName) ?? productName)
        guard attention?.showsDot == true else {
            badge?.removeFromSuperview()
            return
        }
        guard badge == nil else { return }
        // The button's coordinates are flipped: y 1 is its top edge.
        let dot = NSView(frame: NSRect(x: button.bounds.maxX - 8, y: 1, width: 7, height: 7))
        dot.identifier = identifier
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.autoresizingMask = [.minXMargin, .maxYMargin]
        button.addSubview(dot)
    }

    /// Raycast's menu: open the app (with its hotkey), then About, updates, and Settings, then Quit.
    /// While an update waits, Restart to Update comes first.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = updateSnapshot()
        if snapshot.canRestart {
            let restart = menu.addItem(withTitle: "Restart to Update", action: #selector(restartToUpdate), keyEquivalent: "")
            restart.target = self
            restart.isEnabled = true
            restart.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }
        let open = menu.addItem(withTitle: "Open Keybumps", action: #selector(toggleQuickSearch), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        if let shortcut = quickSearchShortcut(), let key = Self.menuKeyEquivalent(for: shortcut) {
            open.keyEquivalent = key.character
            open.keyEquivalentModifierMask = key.modifiers
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Keybumps", action: #selector(showAbout), keyEquivalent: "").target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = snapshot.canCheck
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
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
    @objc private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    /// The key equivalent that displays a global shortcut beside a menu item; nil when the key
    /// has no single-character equivalent.
    static func menuKeyEquivalent(for binding: ShortcutBinding) -> (character: String, modifiers: NSEvent.ModifierFlags)? {
        let modifiers = NSEvent.ModifierFlags(carbonModifiers: binding.modifiers)
        if binding.keyCode == UInt32(kVK_Space) { return (" ", modifiers) }
        let key = binding.displayName.drop { "⌃⌥⇧⌘".contains($0) }
        guard key.count == 1 else { return nil }
        return (key.lowercased(), modifiers)
    }

    @objc private func checkForUpdates() { checkForUpdatesAction() }
    @objc private func restartToUpdate() { restartToUpdateAction() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

extension NSEvent.ModifierFlags {
    init(carbonModifiers: UInt32) {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        self = flags
    }
}
