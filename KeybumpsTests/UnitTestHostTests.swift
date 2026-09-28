import AppKit
import Carbon.HIToolbox
import Testing
@testable import Keybumps

@MainActor
@Suite("Unit-test host")
struct UnitTestHostTests {
    @Test("Windows created during unit tests stay invisible and click-through")
    func windowsStayOffScreen() {
        #expect(UnitTestHost.isActive)
        let presenter = PresentationWindowController()
        presenter.show(event: .sample, style: .topRightToast)
        defer { presenter.dismissAll() }

        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.hideDuringUnitTests()
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 && $0.level != .normal }.isEmpty)
    }
}

@MainActor
@Suite("Status item menu")
struct StatusItemMenuTests {
    @Test("Open Keybumps shows the Quick Search hotkey, as Raycast shows its own")
    func openItemShowsTheHotkey() throws {
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureQuickSearch(isVisible: { false }, setVisible: { _ in }, shortcut: { DefaultShortcut.quickSearch })
        let open = try #require(controller.makeMenu().item(withTitle: "Open Keybumps"))
        #expect(open.keyEquivalent == " ")
        #expect(open.keyEquivalentModifierMask == [.command])
    }

    @Test("Single-character keys and Space get a displayed equivalent; others show none")
    func keyEquivalents() {
        #expect(NativeStatusItemController.menuKeyEquivalent(for: DefaultShortcut.clipboard)?.modifiers == [.command, .shift])
        let letter = ShortcutBinding(keyCode: 32, modifiers: UInt32(optionKey | controlKey), displayName: "⌃⌥U")
        #expect(NativeStatusItemController.menuKeyEquivalent(for: letter)?.character == "u")
        let arrow = ShortcutBinding(keyCode: 123, modifiers: UInt32(controlKey), displayName: "⌃←")
        #expect(NativeStatusItemController.menuKeyEquivalent(for: arrow)?.character == "←")
        let named = ShortcutBinding(keyCode: 53, modifiers: UInt32(cmdKey), displayName: "⌘Escape")
        #expect(NativeStatusItemController.menuKeyEquivalent(for: named) == nil)
    }
}
