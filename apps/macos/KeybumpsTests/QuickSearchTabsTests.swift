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

    @Test("An install with Quick Search turned off starts with the Search tab hidden, Quick Search on, and ⌘Space unassigned")
    func quickSearchOffHidesTheSearchTab() {
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory", "dictation"], forKey: "enabledCapabilities")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(!preferences.showsTab(.search))
        #expect(preferences.enabledCapabilities.contains(.quickSearch))
        #expect(defaults.stringArray(forKey: "enabledCapabilities")?.contains("quickSearch") == true)
        #expect(defaults.stringArray(forKey: "quickSearchHiddenTabs") == ["search"])
        #expect(defaults.bool(forKey: "didMoveQuickSearchSwitchToSearchTab"))
        #expect(preferences.capabilityShortcut(for: .quickSearch) == nil, "⌘Space stays free, as turning Quick Search off left it")
        #expect(preferences.paletteOpeningTab == .clipboard, "The menu bar's Open Quick Search and the Dock open the Clipboard tab")
        let relaunched = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(!relaunched.showsTab(.search), "and it stays hidden")
        #expect(relaunched.capabilityShortcut(for: .quickSearch) == nil, "and ⌘Space stays unassigned")
    }

    @Test("Where Quick Search was off, its shortcut is unassigned, whatever key it had; every other shortcut stays")
    func quickSearchOffUnassignsACustomShortcut() throws {
        let custom = ShortcutBinding(keyCode: 49, modifiers: 2048, displayName: "⌥ Space")
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory"], forKey: "enabledCapabilities")
        defaults.set(try JSONEncoder().encode(["quickSearch": custom, "clipboardHistory": DefaultShortcut.clipboard]), forKey: "capabilityShortcuts")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(preferences.capabilityShortcut(for: .quickSearch) == nil)
        #expect(preferences.capabilityShortcut(for: .clipboardHistory) == DefaultShortcut.clipboard)
    }

    @Test("⌘Space stays assigned where Quick Search was on, and on a fresh install", arguments: [
        ["quickSearch", "clipboardHistory"],
        nil,
    ] as [[String]?])
    func quickSearchOnKeepsItsShortcut(stored: [String]?) {
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: "enabledCapabilities") }
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
    }

    @Test("A key assigned after the move is never cleared, even if a later save lacks Quick Search")
    func assignedShortcutIsKept() {
        let defaults = InMemoryDefaults()
        defaults.set(["dictation"], forKey: "enabledCapabilities")
        let first = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(first.capabilityShortcut(for: .quickSearch) == nil)
        first.setCapabilityShortcut(DefaultShortcut.quickSearch, for: .quickSearch)

        // As a build from before #553 could save after a rollback, with Quick Search turned off there.
        defaults.set(["dictation"], forKey: "enabledCapabilities")
        let second = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(second.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
    }

    @Test("After the update, an install that had Quick Search off doesn't register ⌘Space, and the Clipboard tab keeps ⇧⌘Space")
    func upgradedInstallLeavesCommandSpaceFree() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsQuickSearchTabs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        defaults.set(CapabilityCatalog.defaultCapabilities.subtracting([.quickSearch]).map(\.rawValue), forKey: "enabledCapabilities")
        defaults.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
        let harness = WiringHarness(enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root, defaults: defaults)
        harness.model.start()

        #expect(harness.shortcuts()["quickSearch"] == nil, "⌘Space isn't registered")
        #expect(harness.shortcuts()["clipboardHistory"] != nil)
        #expect(harness.model.commandPalette.openingTab == .clipboard)
    }

    @Test("Every saved state the move can find: the Search tab hidden only where Quick Search was off, and the Hotkeys tab as it was", arguments: [
        (["quickSearch", "clipboardHistory"] as [String]?, false),
        (["quickSearch", "clipboardHistory"], true),
        (["clipboardHistory"], false),
        (["clipboardHistory"], true),
        (nil, false),
        (nil, true),
    ])
    func movePerSavedState(stored: [String]?, showsHotkeysTab: Bool) {
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: "enabledCapabilities") }
        defaults.set(showsHotkeysTab, forKey: "showsHotkeysTab")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        let quickSearchWasOff = stored.map { !$0.contains("quickSearch") } ?? false

        var expected: Set<CommandPaletteTab> = quickSearchWasOff ? [.search] : []
        if !showsHotkeysTab { expected.insert(.keyboardShortcutter) }
        #expect(preferences.hiddenTabs == expected)
        #expect(defaults.bool(forKey: "showsHotkeysTab") == showsHotkeysTab, "The Hotkeys tab's switch is left alone")
        #expect((preferences.capabilityShortcut(for: .quickSearch) == nil) == quickSearchWasOff)
        #expect(preferences.paletteOpeningTab == (quickSearchWasOff ? .clipboard : .search))
    }

    @Test("Where Quick Search was off with every other plugin off, the Search tab shows anyway, as the only tab")
    func quickSearchOffWithEveryPluginOff() {
        let defaults = InMemoryDefaults()
        defaults.set([String](), forKey: "enabledCapabilities")
        defaults.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(preferences.enabledCapabilities == [.quickSearch])
        #expect(!preferences.showsTab(.search), "It's saved hidden")
        #expect(preferences.visiblePaletteTabs(selected: .search) == [.search])
        #expect(preferences.paletteOpeningTab == .search, "The menu bar and the Dock still open a tab")
        #expect(preferences.paletteTabsHiddenFromTabBar == [.keyboardShortcutter])
        let row = QuickSearchTabList.rows(hidden: preferences.hiddenTabs, enabled: preferences.enabledCapabilities, compatibility: Self.mac15)
            .first { $0.tab == .search }
        #expect(row?.isShown == true)
        #expect(row?.isOnlyShownTab == true)
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

    @Test("A tab saved hidden is out of the tab bar, unless it shows anyway as the only tab, and Settings › Plugins shows its key as it is")
    func hiddenFromTabBar() {
        #expect(CommandPaletteTab.hiddenFromTabBar(hidden: [.search, .keyboardShortcutter], enabled: Self.everything, compatibility: Self.mac15) == [.search, .keyboardShortcutter])
        let onlyTab = CommandPaletteTab.hiddenFromTabBar(hidden: [.search, .keyboardShortcutter], enabled: [.quickSearch], compatibility: Self.mac15)
        #expect(onlyTab == [.keyboardShortcutter], "The Search tab shows as the only tab")
        #expect(PluginsTable.tabKey(for: .quickSearch, hiddenTabs: onlyTab) == "⌘1")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, hiddenTabs: onlyTab) == "")

        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.setShowsTab(.search, false)
        #expect(preferences.paletteTabsHiddenFromTabBar == [.search, .keyboardShortcutter])
        #expect(PluginsTable.tabKey(for: .quickSearch, hiddenTabs: preferences.paletteTabsHiddenFromTabBar) == "")
        preferences.enabledCapabilities = [.quickSearch]
        #expect(PluginsTable.tabKey(for: .quickSearch, hiddenTabs: preferences.paletteTabsHiddenFromTabBar) == "⌘1")
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

    @Test("A tab whose plugin is off says which, or that the plugin needs a newer macOS, with no show switch")
    func tabListPluginOff() {
        let rows = QuickSearchTabList.rows(hidden: [], enabled: [.quickSearch, .screenshotTools], compatibility: Self.mac14)
        let hotkeys = rows.first { $0.tab == .keyboardShortcutter }
        #expect(hotkeys?.pluginOff == .keyboardShortcutter)
        #expect(hotkeys?.hasShowSwitch == false)
        #expect(rows.first { $0.tab == .screenshots }?.pluginOff == .clipboardHistory, "Its screenshots are Clipboard History's on macOS 14")

        #expect(hotkeys?.note == "\(Capability.keyboardShortcutter.title) is turned off")
        #expect(rows.first { $0.tab == .translate }?.note == "Requires macOS 15", "Translation can't be turned on on macOS 14")

        let mac15 = QuickSearchTabList.rows(hidden: [], enabled: [.quickSearch, .screenshotTools], compatibility: Self.mac15)
        #expect(mac15.first { $0.tab == .screenshots }?.pluginOff == nil)
        #expect(mac15.first { $0.tab == .screenshots }?.note == nil)
        #expect(mac15.first { $0.tab == .screenshots }?.isShown == true)
        #expect(mac15.first { $0.tab == .translate }?.note == "\(Capability.translation.title) is turned off")
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
