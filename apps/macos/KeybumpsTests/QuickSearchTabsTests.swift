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

    @Test("An install with Quick Search turned off starts with the Search tab hidden, Quick Search on, and ⌘Space still Quick Search's")
    func quickSearchOffHidesTheSearchTab() {
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory", "dictation"], forKey: "enabledCapabilities")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(!preferences.showsTab(.search))
        #expect(preferences.enabledCapabilities.contains(.quickSearch))
        #expect(defaults.stringArray(forKey: "enabledCapabilities")?.contains("quickSearch") == true)
        #expect(defaults.stringArray(forKey: "quickSearchHiddenTabs") == ["search"])
        #expect(defaults.bool(forKey: "didMoveQuickSearchSwitchToSearchTab"))
        #expect(preferences.takesCommandSpaceFromSpotlightOnLaunch, "The next launch takes ⌘Space from Spotlight once")
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch, "⌘Space stays Quick Search's (owner's decision on #553)")
        #expect(defaults.data(forKey: "capabilityShortcuts") == nil, "The default is never saved")
        #expect(preferences.paletteOpeningTab == .clipboard, "⌘Space, the menu bar's Open Quick Search and the Dock open the Clipboard tab")
        let relaunched = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(!relaunched.showsTab(.search), "and it stays hidden")
        #expect(relaunched.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch, "and ⌘Space stays assigned")
    }

    @Test("Where Quick Search was off, a key saved for it stays assigned to it, and every other shortcut stays")
    func quickSearchOffKeepsACustomShortcut() throws {
        let custom = ShortcutBinding(keyCode: 49, modifiers: 2048, displayName: "⌥ Space")
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory"], forKey: "enabledCapabilities")
        defaults.set(try JSONEncoder().encode(["quickSearch": custom, "clipboardHistory": DefaultShortcut.clipboard]), forKey: "capabilityShortcuts")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(!preferences.showsTab(.search))
        #expect(preferences.capabilityShortcut(for: .quickSearch) == custom)
        #expect(preferences.capabilityShortcut(for: .clipboardHistory) == DefaultShortcut.clipboard)
        #expect(AppPreferences(defaults: defaults, compatibility: Self.mac15).capabilityShortcut(for: .quickSearch) == custom, "and after a relaunch")
    }

    @Test("⌘Space stays assigned whether Quick Search was on or off, and on a fresh install", arguments: [
        ["quickSearch", "clipboardHistory"],
        ["clipboardHistory"],
        nil,
    ] as [[String]?])
    func quickSearchKeepsItsShortcut(stored: [String]?) {
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: "enabledCapabilities") }
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
    }

    @Test("A Quick Search shortcut the person unassigned before the update stays unassigned")
    func unassignedShortcutStaysUnassigned() throws {
        let defaults = InMemoryDefaults()
        defaults.set(["clipboardHistory"], forKey: "enabledCapabilities")
        defaults.set(try JSONEncoder().encode(["clipboardHistory": DefaultShortcut.clipboard]), forKey: "capabilityShortcuts")
        let preferences = AppPreferences(defaults: defaults, compatibility: Self.mac15)

        #expect(preferences.capabilityShortcut(for: .quickSearch) == nil)
        #expect(preferences.capabilityShortcut(for: .clipboardHistory) == DefaultShortcut.clipboard)
    }

    @Test("After the update, an install that had Quick Search off registers its key, ⌘Space or the one saved, and the window opens on the Clipboard tab", arguments: [
        nil,
        ShortcutBinding(keyCode: 49, modifiers: 2048, displayName: "⌥ Space"),
    ] as [ShortcutBinding?])
    func upgradedInstallRegistersItsShortcut(saved: ShortcutBinding?) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsQuickSearchTabs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        defaults.set(CapabilityCatalog.defaultCapabilities.subtracting([.quickSearch]).map(\.rawValue), forKey: "enabledCapabilities")
        defaults.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
        if let saved {
            var shortcuts = AppPreferences(defaults: InMemoryDefaults()).capabilityShortcuts
            shortcuts["quickSearch"] = saved
            defaults.set(try JSONEncoder().encode(shortcuts), forKey: "capabilityShortcuts")
            defaults.set(CapabilityShortcut.allCases.map(\.rawValue), forKey: "knownCapabilityShortcuts")
        }
        let harness = WiringHarness(enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root, defaults: defaults)
        harness.model.start()

        let expected = saved ?? DefaultShortcut.quickSearch
        #expect(harness.shortcuts()["quickSearch"] == "\(expected.displayName) [\(expected.keyCode)/\(expected.modifiers)]", "Quick Search's key is registered")
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
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch, "⌘Space stays Quick Search's either way")
        #expect(preferences.takesCommandSpaceFromSpotlightOnLaunch == quickSearchWasOff)
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
        #expect(preferences.shownPaletteTabs == [.search])
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

    @Test("Settings › Plugins shows a tab's key as the tab bar has it: a dash while it's hidden or its plugin is off, and nothing for a plugin without a tab")
    func pluginsTabKey() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.mac15)
        preferences.enabledCapabilities = Self.everything
        preferences.setShowsTab(.search, false)
        let shown = preferences.shownPaletteTabs
        #expect(shown.first == .clipboard)
        #expect(PluginsTable.tabKey(for: .quickSearch, shownTabs: shown) == "—")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, shownTabs: shown) == "—", "The Hotkeys tab starts hidden")
        #expect(PluginsTable.tabKey(for: .clipboardHistory, shownTabs: shown) == "⌘1", "Keys never skip a hidden tab")
        #expect(PluginsTable.tabKey(for: .windowManagement, shownTabs: shown) == "")

        preferences.enabledCapabilities = [.quickSearch]
        #expect(PluginsTable.tabKey(for: .quickSearch, shownTabs: preferences.shownPaletteTabs) == "⌘1", "The Search tab shows anyway as the only tab")
        #expect(PluginsTable.tabKey(for: .clipboardHistory, shownTabs: preferences.shownPaletteTabs) == "—", "Its plugin is off")
    }

    // MARK: Settings › Quick Search's tab list

    @Test("The tab list shows every tab in the default order, its tab key while shown, and a show switch on each tab whose plugin is on")
    func tabListRows() {
        let rows = QuickSearchTabList.rows(
            hidden: [.keyboardShortcutter],
            enabled: CapabilityCatalog.defaultCapabilities,
            compatibility: Self.mac15
        )
        #expect(rows.map(\.tab) == CommandPaletteTab.allCases)
        #expect(rows.map(\.tabKey) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "—", "—", "—", "—"])
        #expect(rows.filter(\.hasShowSwitch).map(\.tab) == [.search, .clipboard, .screenshots, .dictation, .snippets, .keyboardShortcutter])
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

/// The update takes ⌘Space from Spotlight once where Quick Search was off (owner's decision on
/// #553), with first-time setup's step.
@MainActor
@Suite("Quick Search takes ⌘Space from Spotlight after the update")
struct QuickSearchSpotlightAfterUpdateTests {
    final class FakeSpotlightResolver: SpotlightShortcutConflictResolving {
        var statusResult: SpotlightShortcutConflictStatus
        let resolution: SpotlightShortcutResolution
        private(set) var checks: [ShortcutBinding] = []
        private(set) var disables: [ShortcutBinding] = []

        init(status: SpotlightShortcutConflictStatus, resolution: SpotlightShortcutResolution = .resolved) {
            statusResult = status
            self.resolution = resolution
        }

        func status(for binding: ShortcutBinding) -> SpotlightShortcutConflictStatus {
            checks.append(binding)
            return statusResult
        }

        func disableIfConflicting(_ binding: ShortcutBinding) -> SpotlightShortcutResolution {
            disables.append(binding)
            return resolution
        }
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsQuickSearchSpotlight-\(UUID().uuidString)", isDirectory: true)

    /// What an install saved before #553 with every default plugin on but Quick Search.
    private static func quickSearchOffInstall() -> InMemoryDefaults {
        let defaults = InMemoryDefaults()
        defaults.set(CapabilityCatalog.defaultCapabilities.subtracting([.quickSearch]).map(\.rawValue), forKey: "enabledCapabilities")
        defaults.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
        return defaults
    }

    private func launch(_ defaults: InMemoryDefaults, resolver: FakeSpotlightResolver) -> WiringHarness {
        let harness = WiringHarness(
            enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root,
            defaults: defaults, spotlightShortcutResolver: resolver
        )
        harness.model.start()
        return harness
    }

    @Test("Where Spotlight has ⌘Space, the first launch turns it off once and clears the flag")
    func conflictResolvedOnce() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let resolver = FakeSpotlightResolver(status: .conflict)
        let harness = launch(defaults, resolver: resolver)

        #expect(resolver.disables == [DefaultShortcut.quickSearch])
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"))
        #expect(!harness.model.preferences.takesCommandSpaceFromSpotlightOnLaunch)
        #expect(harness.model.quickSearchShortcutConflictStatus == .noConflict)
        #expect(harness.model.quickSearchSpotlightRecovery == nil)
        #expect(harness.shortcuts()["quickSearch"] != nil, "⌘Space registers after Spotlight lets it go")
    }

    @Test("Where Spotlight's shortcut can't be turned off, Settings › Quick Search shows first-time setup's manual recovery")
    func failureShowsManualRecovery() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let guidance = "Open System Settings and turn off Spotlight's shortcut."
        let resolver = FakeSpotlightResolver(status: .conflict, resolution: .failed(manualRecovery: guidance))
        let harness = launch(defaults, resolver: resolver)

        #expect(resolver.disables.count == 1)
        #expect(harness.model.quickSearchShortcutConflictStatus == .unavailable(manualRecovery: guidance))
        #expect(harness.model.quickSearchSpotlightRecovery == guidance)
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"), "It isn't tried again on the next launch")
    }

    @Test("Where Spotlight doesn't use Quick Search's keys, nothing changes")
    func noConflictChangesNothing() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let resolver = FakeSpotlightResolver(status: .noConflict)
        let harness = launch(defaults, resolver: resolver)

        #expect(resolver.checks == [DefaultShortcut.quickSearch])
        #expect(resolver.disables.isEmpty)
        #expect(harness.model.quickSearchShortcutConflictStatus == .noConflict)
        #expect(harness.model.quickSearchSpotlightRecovery == nil)
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"))
    }

    @Test("A second launch doesn't take ⌘Space again, even if Spotlight has it back")
    func secondLaunchDoesNothing() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        _ = launch(defaults, resolver: FakeSpotlightResolver(status: .conflict))

        let again = FakeSpotlightResolver(status: .conflict)
        let harness = launch(defaults, resolver: again)
        #expect(again.checks.isEmpty)
        #expect(again.disables.isEmpty)
        #expect(harness.model.quickSearchSpotlightRecovery == nil)
    }

    @Test("An install that had Quick Search on, and a fresh one after setup, never check Spotlight at launch", arguments: [
        ["quickSearch", "clipboardHistory"],
        nil,
    ] as [[String]?])
    func quickSearchOnInstallUnchanged(stored: [String]?) {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryDefaults()
        if let stored { defaults.set(stored, forKey: "enabledCapabilities") }
        let resolver = FakeSpotlightResolver(status: .conflict)
        _ = launch(defaults, resolver: resolver)

        #expect(resolver.checks.isEmpty)
        #expect(resolver.disables.isEmpty)
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"))
    }

    @Test("Before first-time setup finishes, setup takes ⌘Space instead, and the flag is dropped")
    func setupNotFinishedLeavesItToSetup() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let resolver = FakeSpotlightResolver(status: .conflict)
        let harness = WiringHarness(
            enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root,
            didCompleteOnboarding: false, defaults: defaults, spotlightShortcutResolver: resolver
        )
        harness.model.start()

        #expect(resolver.disables.isEmpty)
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"))
    }

    @Test("While Locked, the flag waits, and runs once after a license is activated")
    func lockedWaitsForLicense() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let resolver = FakeSpotlightResolver(status: .conflict)
        let licensing = FixedLicenseController(state: .unlicensed)
        let harness = WiringHarness(
            enabled: CapabilityCatalog.defaultCapabilities, missing: nil, root: root,
            defaults: defaults, licensing: licensing, spotlightShortcutResolver: resolver
        )
        harness.model.start()

        #expect(resolver.checks.isEmpty, "⌘Space would open nothing while Locked")
        #expect(defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"), "It waits for a license")

        await licensing.activate(key: "KEYBUMPS-TEST")
        #expect(resolver.disables == [DefaultShortcut.quickSearch])
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"))
        #expect(harness.shortcuts()["quickSearch"] != nil, "⌘Space registers after Spotlight lets it go")

        await licensing.deactivate()
        await licensing.activate(key: "KEYBUMPS-TEST")
        #expect(resolver.checks.count == 1, "It runs once")
        #expect(resolver.disables.count == 1)
    }

    @Test("Where Spotlight's shortcuts can't be read, the flag is used up and nothing changes")
    func unreadableUsesUpTheFlag() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let resolver = FakeSpotlightResolver(status: .unavailable(manualRecovery: "Spotlight's shortcuts can't be read."))
        let harness = launch(defaults, resolver: resolver)

        #expect(resolver.checks == [DefaultShortcut.quickSearch])
        #expect(resolver.disables.isEmpty)
        #expect(!defaults.bool(forKey: "takesCommandSpaceFromSpotlightOnLaunch"), "It isn't tried again on the next launch")
        #expect(harness.model.quickSearchShortcutConflictStatus == .noConflict)
        #expect(harness.model.quickSearchSpotlightRecovery == nil)
    }

    @Test("Where Spotlight's shortcuts can't be read on Check Again, the note from the failure stays")
    func checkAgainUnreadableKeepsTheNote() {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = Self.quickSearchOffInstall()
        let guidance = "Open System Settings and turn off Spotlight's shortcut."
        let resolver = FakeSpotlightResolver(status: .conflict, resolution: .failed(manualRecovery: guidance))
        let harness = launch(defaults, resolver: resolver)
        #expect(harness.model.quickSearchSpotlightRecovery == guidance)

        resolver.statusResult = .unavailable(manualRecovery: "Spotlight's shortcuts can't be read.")
        harness.model.checkQuickSearchSpotlightAgain()
        #expect(resolver.checks.count == 2)
        #expect(resolver.disables.count == 1)
        #expect(harness.model.quickSearchShortcutConflictStatus == .unavailable(manualRecovery: guidance))
        #expect(harness.model.quickSearchSpotlightRecovery == guidance)

        resolver.statusResult = .noConflict
        harness.model.checkQuickSearchSpotlightAgain()
        #expect(harness.model.quickSearchSpotlightRecovery == nil, "Once Spotlight lets ⌘Space go, the note goes")
    }
}
