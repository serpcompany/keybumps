import AppKit

@MainActor
final class NativeStatusItemController: NSObject {
    static let shared = NativeStatusItemController()

    private var statusItem: NSStatusItem?

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
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let updates = menu.addItem(withTitle: "Check for Updates (Not Configured)", action: nil, keyEquivalent: "")
        updates.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SuperMac", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettings() { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
