import AppKit
import SwiftUI
import Testing
@testable import Keybumps

/// The palette's icon tab bar (#182): it always fits the palette, the open tab shows its name, and
/// ⌘-numbers show only while ⌘ is held.
@MainActor
@Suite("Command Palette: tab bar")
struct PaletteTabBarTests {
    /// The palette window's content width (`CommandPaletteController.makePanel`).
    static let paletteWidth: CGFloat = 1040

    func idealSize<V: View>(_ view: V) -> CGSize {
        NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    func bar(_ tabs: [CommandPaletteTab], selected: CommandPaletteTab, showsShortcuts: Bool) -> PaletteTabBar {
        PaletteTabBar(tabs: tabs, selected: selected, showsShortcuts: showsShortcuts, select: { _ in })
    }

    /// The bar's padding, spacing, and brand mark: its width without tabs.
    var chromeWidth: CGFloat { idealSize(bar([], selected: .search, showsShortcuts: false)).width }

    @Test("Every tab, Hotkeys included, fits the palette as icons, with or without ⌘ held")
    func fits() {
        #expect(CommandPaletteTab.allCases.count >= 9, "All tabs, so the bar is at its widest")
        for tab in CommandPaletteTab.allCases {
            for showsShortcuts in [false, true] {
                let icons = idealSize(bar(CommandPaletteTab.allCases, selected: tab, showsShortcuts: showsShortcuts).tabRow(namesSelected: false))
                #expect(icons.width + chromeWidth <= Self.paletteWidth, "\(tab.rawValue), ⌘ held: \(showsShortcuts)")
            }
        }
    }

    @Test("With the plugins that start on, the open tab shows its name, with or without ⌘ held")
    func defaultTabsShowTheOpenName() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: .search, enabled: preferences.enabledCapabilities)
        for tab in tabs {
            for showsShortcuts in [false, true] {
                // `ViewThatFits` keeps the named row when its full width fits.
                let named = idealSize(bar(tabs, selected: tab, showsShortcuts: showsShortcuts))
                #expect(named.width <= Self.paletteWidth, "\(tab.rawValue), ⌘ held: \(showsShortcuts)")
            }
        }
    }

    @Test("Holding ⌘ doesn't change the bar's height, so the content below stays put")
    func commandKeepsHeight() {
        let tabs = CommandPaletteTab.allCases
        #expect(idealSize(bar(tabs, selected: .search, showsShortcuts: true)).height
            == idealSize(bar(tabs, selected: .search, showsShortcuts: false)).height)
    }

    @Test("Every tab's icon is a symbol this Mac has")
    func iconsExist() {
        for tab in CommandPaletteTab.allCases {
            #expect(NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil) != nil, "\(tab.rawValue): \(tab.systemImage)")
        }
    }

    @Test("⌘ shows the numbers while the palette has the keys, and closing the palette hides them")
    func commandShowsNumbers() throws {
        let folder = TemporaryFolder()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTabBar-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); folder.remove() }
        let history = DictationHistoryService(recordingsDirectoryURL: folder.url.appendingPathComponent("recordings", isDirectory: true))
        let palette = CommandPaletteController(
            clipboard: ClipboardHistoryService(
                storageURL: folder.url.appendingPathComponent("clipboard-history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: folder.url.appendingPathComponent("clipboard-media", isDirectory: true),
                sourceApps: .inert
            ),
            dictationHistory: history,
            dictationService: DictationService(language: "en-US", history: history, paster: InertTextPaster(), allowsSystemAccess: false),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            search: QuickSearchModel.forTests(in: folder.url)
        )
        func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
            ))
        }

        palette.handleFlagsChanged(try flags(.command))
        #expect(palette.state.isCommandHeld)
        palette.handleFlagsChanged(try flags([]))
        #expect(!palette.state.isCommandHeld)
        palette.handleFlagsChanged(try flags([.command, .capsLock]))
        #expect(palette.state.isCommandHeld, "Caps Lock doesn't stop ⌘-numbers, as it doesn't stop ⌘ keys")
        palette.handleFlagsChanged(try flags([.command, .shift]))
        #expect(!palette.state.isCommandHeld, "⇧⌘-number doesn't switch tabs, so it shows no numbers")
        palette.handleFlagsChanged(try flags(.command))
        palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(!palette.state.isCommandHeld, "⌘ let go in another app doesn't leave the numbers up")
        palette.handleFlagsChanged(try flags(.command))
        palette.dismiss()
        #expect(!palette.state.isCommandHeld, "Closing with ⌘ still down doesn't leave the numbers up")
    }
}
