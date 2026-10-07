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

    func width(selected: CommandPaletteTab, showsShortcuts: Bool) -> CGFloat {
        let bar = PaletteTabBar(tabs: CommandPaletteTab.allCases, selected: selected, showsShortcuts: showsShortcuts, select: { _ in })
        let controller = NSHostingController(rootView: bar)
        return controller.sizeThatFits(in: CGSize(width: Self.paletteWidth, height: 200)).width
    }

    @Test("Every tab, Hotkeys included, fits the palette, with or without ⌘ held")
    func fits() {
        #expect(CommandPaletteTab.allCases.count >= 9, "All tabs, so the bar is at its widest")
        for tab in CommandPaletteTab.allCases {
            for showsShortcuts in [false, true] {
                #expect(width(selected: tab, showsShortcuts: showsShortcuts) <= Self.paletteWidth,
                        "\(tab.rawValue), ⌘ held: \(showsShortcuts)")
            }
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
        func flags(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            try! #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
            ))
        }

        palette.handleFlagsChanged(flags(.command))
        #expect(palette.state.isCommandHeld)
        palette.handleFlagsChanged(flags([]))
        #expect(!palette.state.isCommandHeld)
        palette.handleFlagsChanged(flags(.command))
        palette.dismiss()
        #expect(!palette.state.isCommandHeld, "Closing with ⌘ still down doesn't leave the numbers up")
    }
}
