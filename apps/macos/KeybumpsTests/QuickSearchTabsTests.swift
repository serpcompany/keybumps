import Foundation
import Testing
@testable import Keybumps

/// Settings › Quick Search (#553): Quick Search is always on, hiding the Search tab took the place
/// of turning it off, and the window opens on the first shown tab.
@MainActor
@Suite("Quick Search tabs")
struct QuickSearchTabsTests {
    private static let mac14 = PluginCompatibility(macOSMajorVersion: 14)
    private static let mac15 = PluginCompatibility(macOSMajorVersion: 15)
    private static let everything = Set(Capability.allCases)

    // MARK: Moving the Quick Search switch to the Search tab

    @Test("An install with Quick Search turned off starts with the Search tab hidden, and Quick Search on")
    func quickSearchOffHidesTheSearchTab() {
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory", "dictation"], forKey: "enabledCapabilities")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(!preferences.showsTab(.search))
        #expect(preferences.enabledCapabilities.contains(.quickSearch))
        #expect(defaults.stringArray(forKey: "enabledCapabilities")?.contains("quickSearch") == true)
        #expect(defaults.stringArray(forKey: "quickSearchHiddenTabs") == ["search"])
        #expect(defaults.bool(forKey: "didMoveQuickSearchSwitchToSearchTab"))
        #expect(preferences.paletteOpeningTab == .clipboard, "⌘Space opens on the Clipboard tab, as it did")
        #expect(!AppPreferences(defaults: defaults, compatibility: Self.mac15).showsTab(.search), "and it stays hidden")
    }

    @Test("An install with Quick Search on, or a fresh install, shows the Search tab", arguments: [
        ["quickSearch", "clipboardHistory"],
        nil,
    ] as [[String]?])
    func quickSearchOnShowsTheSearchTab(stored: [String]?) {
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: "enabledCapabilities") }
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(preferences.showsTab(.search))
        #expect(preferences.paletteOpeningTab == .search)
        #expect(defaults.bool(forKey: "didMoveQuickSearchSwitchToSearchTab"))
    }

    @Test("The move runs once: a Search tab shown again stays shown, whatever is saved later")
    func moveRunsOnce() {
        let defaults = InMemoryDefaults()
        defaults.set(["dictation"], forKey: "enabledCapabilities")
        let first = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(!first.showsTab(.search))
        first.setShowsTab(.search, true)

        // As a build from before #553 could save after a rollback, with Quick Search turned off there.
        defaults.set(["dictation"], forKey: "enabledCapabilities")
        let second = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(second.showsTab(.search))
        #expect(second.enabledCapabilities.contains(.quickSearch))
    }

    @Test("Hidden tabs are kept across launches, the Hotkeys tab's under the key it always had")
    func hiddenTabsPersist() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(preferences.hiddenTabs == [.keyboardShortcutter], "The Hotkeys tab starts hidden")

        preferences.setShowsTab(.keyboardShortcutter, true)
        preferences.setShowsTab(.search, false)
        #expect(defaults.bool(forKey: "showsHotkeysTab"), "where builds before #553 read it")
        #expect(defaults.stringArray(forKey: "quickSearchHiddenTabs") == ["search"])
        #expect(AppPreferences(defaults: defaults, compatibility: Self.mac15).hiddenTabs == [.search])
    }

    // MARK: Always on

    @Test("Quick Search can't be turned off: it stays on whatever is set or saved")
    func quickSearchIsAlwaysOn() {
        #expect(CapabilityCatalog.alwaysOnCapabilities == [.quickSearch])
        #expect(Capability.quickSearch.descriptor.settingsPage?.disableExplanation(on: Self.mac15) == nil, "No switch, so no tooltip for one")

        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.setCapability(.quickSearch, enabled: false)
        #expect(preferences.enabledCapabilities.contains(.quickSearch))
        preferences.enabledCapabilities = []
        #expect(preferences.enabledCapabilities == [.quickSearch])
    }

    @Test("Turning Quick Search off does nothing, so ⌘Space stays registered, and it opens on the first shown tab")
    func appKeepsQuickSearchOn() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsQuickSearchTabs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root)
        harness.model.start()
        let quickSearchShortcut = harness.shortcuts()["quickSearch"]
        #expect(quickSearchShortcut != nil)

        harness.model.setCapability(.quickSearch, enabled: false)
        #expect(harness.model.preferences.enabledCapabilities.contains(.quickSearch))
        #expect(harness.shortcuts()["quickSearch"] == quickSearchShortcut)

        #expect(harness.model.commandPalette.openingTab == .search)
        harness.model.preferences.setShowsTab(.search, false)
        #expect(harness.model.commandPalette.openingTab == .clipboard)
        #expect(harness.shortcuts()["quickSearch"] == quickSearchShortcut, "Hiding the Search tab keeps ⌘Space")
    }

    // MARK: Which tabs show

    @Test("Quick Search opens on the first shown tab: the Search tab unless it's hidden")
    func opensOnFirstShownTab() {
        #expect(CommandPaletteTab.openingTab(hidden: [], enabled: Self.everything, compatibility: Self.mac15) == .search)
        #expect(CommandPaletteTab.openingTab(hidden: [.search], enabled: Self.everything, compatibility: Self.mac15) == .clipboard)
        #expect(CommandPaletteTab.openingTab(hidden: [.search, .clipboard], enabled: Self.everything, compatibility: Self.mac15) == .screenshots)

        let noClipboard = Self.everything.subtracting([.clipboardHistory])
        #expect(
            CommandPaletteTab.openingTab(hidden: [.search], enabled: noClipboard, compatibility: Self.mac15) == .screenshots,
            "The ScreenGrabs tab lists its recordings on macOS 15"
        )
        #expect(
            CommandPaletteTab.openingTab(hidden: [.search], enabled: noClipboard, compatibility: Self.mac14) == .dictation,
            "and shows only Clipboard History's screenshots on macOS 14"
        )
    }

    @Test("One tab always stays shown: the Search tab, when every other is hidden or its plugin is off")
    func oneTabStaysShown() {
        #expect(CommandPaletteTab.shownTabs(hidden: [.search], enabled: [.quickSearch], compatibility: Self.mac15) == [.search])
        #expect(CommandPaletteTab.openingTab(hidden: [.search], enabled: [.quickSearch], compatibility: Self.mac15) == .search)
        #expect(CommandPaletteTab.shownTabs(
            hidden: [.search, .keyboardShortcutter],
            enabled: [.quickSearch, .keyboardShortcutter],
            compatibility: Self.mac15
        ) == [.search])
        #expect(CommandPaletteTab.shownTabs(
            hidden: [.search],
            enabled: [.quickSearch, .keyboardShortcutter],
            compatibility: Self.mac15
        ) == [.keyboardShortcutter])
    }

    @Test("A hidden tab stays in the tab bar while it's open, and leaves it after")
    func openHiddenTabStaysVisible() {
        let hidden: Set<CommandPaletteTab> = [.search, .keyboardShortcutter]
        let open = CommandPaletteTab.visibleTabs(hidden: hidden, selected: .keyboardShortcutter, enabled: Self.everything, compatibility: Self.mac15)
        #expect(open.contains(.keyboardShortcutter))
        #expect(!open.contains(.search))
        let left = CommandPaletteTab.visibleTabs(hidden: hidden, selected: .clipboard, enabled: Self.everything, compatibility: Self.mac15)
        #expect(!left.contains(.keyboardShortcutter))
        #expect(left.first == .clipboard)
    }

    // MARK: Settings › Quick Search's tab list

    @Test("The tab list shows every tab in tab-key order, its tab key while shown, and show switches on the Search and Hotkeys tabs")
    func tabListRows() {
        let rows = QuickSearchTabList.rows(
            hidden: [.keyboardShortcutter],
            enabled: CapabilityCatalog.defaultCapabilities,
            compatibility: Self.mac15
        )
        #expect(rows.map(\.tab) == CommandPaletteTab.allCases)
        #expect(rows.map(\.tabKey) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "—", "—", "—", "—"])
        #expect(rows.filter(\.hasShowSwitch).map(\.tab) == [.search, .keyboardShortcutter])
        #expect(rows.allSatisfy { !$0.isOnlyShownTab })

        let hotkeys = rows.first { $0.tab == .keyboardShortcutter }
        #expect(hotkeys?.isShown == false)
        #expect(hotkeys?.pluginOff == nil, "It's hidden, not off")
        let timers = rows.first { $0.tab == .timers }
        #expect(timers?.pluginOff == .timer)
        #expect(timers?.hasShowSwitch == false)
    }

    @Test("A tab whose plugin is off says which, with no show switch")
    func tabListPluginOff() {
        let rows = QuickSearchTabList.rows(hidden: [], enabled: [.quickSearch, .screenshotTools], compatibility: Self.mac14)
        let hotkeys = rows.first { $0.tab == .keyboardShortcutter }
        #expect(hotkeys?.pluginOff == .keyboardShortcutter)
        #expect(hotkeys?.hasShowSwitch == false)
        #expect(rows.first { $0.tab == .screenshots }?.pluginOff == .clipboardHistory, "Its screenshots are Clipboard History's on macOS 14")

        let mac15 = QuickSearchTabList.rows(hidden: [], enabled: [.quickSearch, .screenshotTools], compatibility: Self.mac15)
        #expect(mac15.first { $0.tab == .screenshots }?.pluginOff == nil)
        #expect(mac15.first { $0.tab == .screenshots }?.isShown == true)
    }

    @Test("The only shown tab's switch can't turn off, even the Search tab's while it's saved hidden")
    func tabListOnlyShownTab() {
        let onlySearch = QuickSearchTabList.rows(
            hidden: [.keyboardShortcutter],
            enabled: [.quickSearch, .keyboardShortcutter],
            compatibility: Self.mac15
        )
        #expect(onlySearch.first { $0.tab == .search }?.isOnlyShownTab == true)
        #expect(onlySearch.first { $0.tab == .keyboardShortcutter }?.isOnlyShownTab == false)

        let fallback = QuickSearchTabList.rows(
            hidden: [.search, .keyboardShortcutter],
            enabled: [.quickSearch, .keyboardShortcutter],
            compatibility: Self.mac15
        )
        let search = fallback.first { $0.tab == .search }
        #expect(search?.isShown == true)
        #expect(search?.isOnlyShownTab == true)
        #expect(search?.tabKey == "⌘1")
    }
}
