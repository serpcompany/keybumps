import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// Quick Search's tab order (#553): Settings › Quick Search saves it, a tab's key is its place among
/// the tabs shown, and Left, Right, and ⌘Space follow it.
@MainActor
@Suite("Quick Search: tab order")
struct QuickSearchTabOrderTests {
    private static let mac15 = PluginCompatibility(macOSMajorVersion: 15)
    private static let everything = Set(Capability.allCases)
    private static let defaultOrder: [CommandPaletteTab] = [
        .search, .clipboard, .screenshots, .dictation, .snippets, .timers, .emoji, .translate, .keyboardShortcutter,
    ]

    // MARK: The saved order

    @Test("The default order is each tab's default position")
    func defaultOrder() {
        #expect(CommandPaletteTab.defaultOrder == Self.defaultOrder)
        #expect(CommandPaletteTab.allCases == Self.defaultOrder)
    }

    @Test("A saved order drops repeats and unknown tabs, and a tab it leaves out goes after it, in the default order")
    func orderedFillsIn() {
        #expect(CommandPaletteTab.ordered([]) == Self.defaultOrder)
        #expect(CommandPaletteTab.ordered([.snippets, .search, .snippets]) == [
            .snippets, .search, .clipboard, .screenshots, .dictation, .timers, .emoji, .translate, .keyboardShortcutter,
        ])

        let defaults = InMemoryDefaults()
        defaults.set(["translate", "notATab", "translate", "clipboard"], forKey: "quickSearchTabOrder")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(preferences.tabOrder == [
            .translate, .clipboard, .search, .screenshots, .dictation, .snippets, .timers, .emoji, .keyboardShortcutter,
        ])
    }

    @Test("Nothing is saved while the tabs are in the default order; a move is saved and read back, and Reset Order clears it")
    func persistence() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(preferences.tabOrder == Self.defaultOrder)
        #expect(preferences.isDefaultTabOrder)
        #expect(defaults.object(forKey: "quickSearchTabOrder") == nil)

        preferences.moveTab(.snippets, by: -1)
        #expect(!preferences.isDefaultTabOrder)
        #expect(defaults.stringArray(forKey: "quickSearchTabOrder") == [
            "search", "clipboard", "screenshots", "snippets", "dictation", "timers", "emoji", "translate", "keyboardShortcutter",
        ])
        #expect(AppPreferences(defaults: defaults, compatibility: Self.mac15).tabOrder == preferences.tabOrder, "Read back at launch")

        preferences.moveTab(.snippets, by: 1)
        #expect(preferences.isDefaultTabOrder, "Moved back by hand, it's the default again")
        #expect(defaults.object(forKey: "quickSearchTabOrder") == nil)

        preferences.moveTab(.translate, to: .search)
        preferences.resetTabOrder()
        #expect(preferences.tabOrder == Self.defaultOrder)
        #expect(preferences.isDefaultTabOrder)
        #expect(defaults.object(forKey: "quickSearchTabOrder") == nil)
    }

    @Test("Up and Down move a tab one place and stop at either end")
    func moveByOne() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.moveTab(.search, by: -1)
        #expect(preferences.isDefaultTabOrder, "The first tab can't move up")
        preferences.moveTab(.keyboardShortcutter, by: 1)
        #expect(preferences.isDefaultTabOrder, "The last tab can't move down")

        preferences.moveTab(.clipboard, by: -1)
        #expect(Array(preferences.tabOrder.prefix(3)) == [.clipboard, .search, .screenshots])
        preferences.moveTab(.clipboard, by: 20)
        #expect(preferences.tabOrder.last == .clipboard, "A long move stops at the end")
        #expect(preferences.tabOrder.count == Self.defaultOrder.count)
    }

    @Test("A dropped tab takes the place of the row it's dropped on, moving up or down")
    func moveToRow() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.moveTab(.search, to: .screenshots)
        #expect(Array(preferences.tabOrder.prefix(4)) == [.clipboard, .screenshots, .search, .dictation])
        preferences.moveTab(.translate, to: .clipboard)
        #expect(Array(preferences.tabOrder.prefix(4)) == [.translate, .clipboard, .screenshots, .search])
        let before = preferences.tabOrder
        preferences.moveTab(.translate, to: .translate)
        #expect(preferences.tabOrder == before, "Dropped on itself, nothing moves")
    }

    @Test("Reset Order puts back the order only: hidden tabs stay hidden")
    func resetKeepsShownTabs() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.enabledCapabilities = Self.everything
        preferences.setShowsTab(.search, false)
        preferences.setShowsTab(.keyboardShortcutter, true)
        preferences.moveTab(.keyboardShortcutter, to: .search)
        let hidden = preferences.hiddenTabs

        preferences.resetTabOrder()
        #expect(preferences.isDefaultTabOrder)
        #expect(preferences.hiddenTabs == hidden)
        #expect(!preferences.showsTab(.search))
        #expect(preferences.showsTab(.keyboardShortcutter))
    }

    // MARK: Tab keys

    @Test("A tab's key is its place among the tabs shown, which never skips a hidden tab or one whose plugin is off")
    func keysByPlace() {
        let shown: [CommandPaletteTab] = [.snippets, .search, .clipboard]
        #expect(CommandPaletteTab.tabKey(for: .snippets, among: shown) == "⌘1")
        #expect(CommandPaletteTab.tabKey(for: .clipboard, among: shown) == "⌘3")
        #expect(CommandPaletteTab.tabKey(for: .dictation, among: shown) == nil)
        #expect(CommandPaletteTab.matchingCommandKey("1", in: shown) == .snippets)
        #expect(CommandPaletteTab.matchingCommandKey("3", in: shown) == .clipboard)
        #expect(CommandPaletteTab.matchingCommandKey("4", in: shown) == nil)
        #expect(CommandPaletteTab.matchingCommandKey("0", in: shown) == nil)

        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.enabledCapabilities = [.quickSearch, .clipboardHistory, .snippets, .translation]
        preferences.moveTab(.translate, to: .search)
        preferences.setShowsTab(.search, false)
        #expect(preferences.shownPaletteTabs == [.translate, .clipboard, .snippets])
        #expect(preferences.shownPaletteTabs.map { CommandPaletteTab.tabKey(for: $0, among: preferences.shownPaletteTabs) }
            == ["⌘1", "⌘2", "⌘3"])
    }

    @Test("Only nine tabs have keys")
    func nineKeys() {
        #expect(CommandPaletteTab.tabKey(for: .keyboardShortcutter, among: Self.defaultOrder) == "⌘9")
        let tenth = Array(repeating: CommandPaletteTab.clipboard, count: 9) + [.search]
        #expect(CommandPaletteTab.tabKey(for: .search, among: tenth) == nil, "A tenth tab has no key")
    }

    @Test("⌘Space opens on the first tab shown in the order")
    func openingTabFollowsTheOrder() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        #expect(preferences.paletteOpeningTab == .search)
        preferences.moveTab(.dictation, to: .search)
        #expect(preferences.paletteOpeningTab == .dictation)
        preferences.moveTab(.keyboardShortcutter, to: .dictation)
        #expect(preferences.paletteOpeningTab == .dictation, "The Hotkeys tab is first, but hidden")
        preferences.resetTabOrder()
        #expect(preferences.paletteOpeningTab == .search)
    }

    @Test("The tab bar follows the order; a hidden tab that's open shows in its place, with no key")
    func tabBarFollowsTheOrder() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.moveTab(.snippets, to: .search)
        #expect(preferences.visiblePaletteTabs(selected: .snippets) == [.snippets, .search, .clipboard, .screenshots, .dictation, .timers])

        preferences.moveTab(.keyboardShortcutter, to: .clipboard)
        let open = preferences.visiblePaletteTabs(selected: .keyboardShortcutter)
        #expect(open == [.snippets, .search, .keyboardShortcutter, .clipboard, .screenshots, .dictation, .timers])
        let shown = preferences.shownPaletteTabs
        #expect(CommandPaletteTab.keyboardShortcutter.labelPresentation(among: shown) == CommandPaletteTabLabel(shortcut: nil, name: "Hotkeys"))
        #expect(CommandPaletteTab.clipboard.labelPresentation(among: shown).shortcut == "⌘3", "Keys don't count the hidden tab")
    }

    @Test("A Quick Search row that opens a tab shows the tab's key among the tabs shown")
    func rowShortcutByPlace() {
        let shown: [CommandPaletteTab] = [.dictation, .search, .clipboard]
        #expect(QuickSearchCommand.capability(.dictation).rowShortcut(enabledCapabilities: Self.everything, shownTabs: shown) == "⌘1")
        #expect(QuickSearchCommand.capability(.clipboardHistory).rowShortcut(enabledCapabilities: Self.everything, shownTabs: shown) == "⌘3")
        #expect(QuickSearchCommand.capability(.snippets).rowShortcut(enabledCapabilities: Self.everything, shownTabs: shown) == nil, "Not shown, so no key")
    }

    // MARK: Settings › Quick Search's tab list

    @Test("The tab list follows the order, with each tab's key among the tabs shown, and the ends can't move past")
    func tabListFollowsTheOrder() {
        let order = CommandPaletteTab.ordered([.timers, .search])
        let rows = QuickSearchTabList.rows(
            hidden: [.keyboardShortcutter],
            enabled: CapabilityCatalog.defaultCapabilities.union([.timer]),
            compatibility: Self.mac15,
            order: order
        )
        #expect(rows.map(\.tab) == order)
        #expect(rows.map(\.tabKey) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "—", "—", "—"])
        #expect(rows.first?.isFirst == true)
        #expect(rows.first?.isLast == false)
        #expect(rows.last?.isLast == true)
        #expect(rows.dropFirst().allSatisfy { !$0.isFirst })
        #expect(rows.dropLast().allSatisfy { !$0.isLast })
    }

    @Test("A dragged row carries its tab, and text dragged in from elsewhere moves nothing")
    func dragPayload() {
        for tab in CommandPaletteTab.allCases {
            #expect(QuickSearchTabList.tab(fromDragPayload: QuickSearchTabList.dragPayload(for: tab)) == tab)
        }
        #expect(QuickSearchTabList.tab(fromDragPayload: "search") == nil)
        #expect(QuickSearchTabList.tab(fromDragPayload: "keybumps.quickSearchTab:notATab") == nil)
        #expect(QuickSearchTabList.tab(fromDragPayload: "") == nil)
    }

    // MARK: The palette's keys

    @Test("In the palette, ⌘1 opens the first tab shown, and Left and Right follow the order")
    func paletteKeysFollowTheOrder() {
        let fixture = OrderPaletteFixture()
        defer { fixture.tearDown() }
        fixture.preferences.moveTab(.snippets, to: .search)
        let palette = fixture.palette

        palette.selectOnOpening(.dictation)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_1, "1", modifiers: .command)) == nil)
        #expect(palette.state.tab == .snippets)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_7, "7", modifiers: .command)) != nil, "Six tabs shown, so ⌘7 does nothing")
        #expect(palette.state.tab == .snippets)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_2, "2", modifiers: .command)) == nil)
        #expect(palette.state.tab == .search)

        palette.selectOnOpening(.snippets)
        #expect(palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(palette.state.tab == .snippets, "No wrap at the first tab")
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.tab == .search)
        #expect(palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(palette.state.tab == .snippets)
        #expect(palette.openingTab == .snippets)
    }

    @Test("In the palette, an open hidden tab takes no ⌘-number, and Left and Right reach the tabs beside it")
    func paletteKeysSkipAnOpenHiddenTab() {
        let fixture = OrderPaletteFixture()
        defer { fixture.tearDown() }
        // The Hotkeys tab starts hidden. Placed before Clipboard History, it's open in the tab bar
        // there, as when its capability command opens it, between the Search and Clipboard tabs.
        fixture.preferences.moveTab(.keyboardShortcutter, to: .clipboard)
        #expect(fixture.preferences.visiblePaletteTabs(selected: .keyboardShortcutter)
            == [.search, .keyboardShortcutter, .clipboard, .screenshots, .dictation, .snippets, .timers])
        let palette = fixture.palette

        palette.selectOnOpening(.keyboardShortcutter)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_3, "3", modifiers: .command)) == nil)
        #expect(palette.state.tab == .screenshots, "⌘3 is the third tab shown, not counting the open Hotkeys tab")
        #expect(!fixture.preferences.visiblePaletteTabs(selected: palette.state.tab).contains(.keyboardShortcutter),
                "Once you leave it, the Hotkeys tab is out of the tab bar")

        palette.selectOnOpening(.keyboardShortcutter)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_2, "2", modifiers: .command)) == nil)
        #expect(palette.state.tab == .clipboard, "⌘2 is the second tab shown")

        palette.selectOnOpening(.keyboardShortcutter)
        #expect(palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(palette.state.tab == .search, "Left reaches the tab before it in the order")

        palette.selectOnOpening(.keyboardShortcutter)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.tab == .clipboard, "Right reaches the tab after it in the order")
    }

    static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let isArrow = [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].contains(keyCode)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union(isArrow ? [.function, .numericPad] : []),
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }
}

/// A Command Palette over a named pasteboard and a temporary folder, with the plugins that ship on
/// (six tabs shown) and its own preferences, on a Mac that runs macOS 15.
@MainActor
private final class OrderPaletteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTabOrder-\(UUID().uuidString)"))
    let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 15))
    let palette: CommandPaletteController

    init() {
        let history = DictationHistoryService(recordingsDirectoryURL: folder.url.appendingPathComponent("recordings", isDirectory: true))
        palette = CommandPaletteController(
            clipboard: ClipboardHistoryService(
                storageURL: folder.url.appendingPathComponent("clipboard-history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: folder.url.appendingPathComponent("clipboard-media", isDirectory: true),
                sourceApps: .inert
            ),
            dictationHistory: history,
            dictationService: DictationService(language: "en-US", history: history, paster: InertTextPaster(), allowsSystemAccess: false),
            preferences: preferences,
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            search: QuickSearchModel.forTests(in: folder.url)
        )
    }

    func tearDown() {
        palette.dismiss()
        pasteboard.releaseGlobally()
        folder.remove()
    }
}
