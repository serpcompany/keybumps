import Testing
import SwiftUI
@testable import Keybumps

@Suite("Settings sidebar")
struct SettingsSidebarTests {
    private static let allPlugins: [SettingsSection] = [
        .search, .clipboard, .dictation, .emojiPicker, .keystrokes, .screenshotTools, .keyboardShortcutter, .snippets,
        .timer, .translation, .windows,
    ]

    @Test("General, Permissions, and Changelog come first, then, under a Plugins header, All Plugins and every plugin, Quick Search first, then by name (#559)")
    func groupsAppPagesThenPlugins() {
        let groups = SettingsSidebar.groups(matching: "")
        #expect(groups.map(\.title) == [nil, "Plugins"])
        #expect(groups.map(\.sections) == [[.general, .permissions, .changelog], [.plugins] + Self.allPlugins])
        #expect(SettingsSection.plugins.sidebarTitle == "All Plugins", "Its row reads All Plugins under the Plugins header")
        #expect(SettingsSection.plugins.rawValue == "Plugins", "and its page keeps the name Plugins")
        #expect(SettingsSection.timer.sidebarTitle == "Timer")
    }

    @Test("Search finds pages and plugins by name and drops empty groups")
    func searchFiltersByName() {
        #expect(SettingsSidebar.groups(matching: "  clip ").map(\.sections) == [[.clipboard]])
        #expect(SettingsSidebar.groups(matching: "PERM").map(\.sections) == [[.permissions]])
        #expect(SettingsSidebar.groups(matching: "zzz").isEmpty)
        #expect(SettingsSidebar.groups(matching: "tim").map(\.sections) == [[.timer]])
        #expect(SettingsSidebar.groups(matching: "plug") == [.init(title: "Plugins", sections: [.plugins])])
        #expect(SettingsSidebar.groups(matching: "all plugins").map(\.sections) == [[.plugins]], "by the name its row shows")
        #expect(SettingsSidebar.groups(matching: "change").map(\.sections) == [[.changelog]])
    }

    @Test("Search also finds a plugin's page by its search keywords, such as ScreenGrabs by its former names (#490)")
    func searchFindsPluginsByKeyword() {
        #expect(SettingsSidebar.groups(matching: "screenshot").map(\.sections) == [[.screenshotTools]])
        #expect(SettingsSidebar.groups(matching: "Screencast").map(\.sections) == [[.screenshotTools]])
        #expect(SettingsSidebar.groups(matching: "record").flatMap(\.sections).contains(.screenshotTools))
        #expect(SettingsSidebar.groups(matching: "recordings").map(\.sections) == [[.dictation, .screenshotTools]])
        #expect(SettingsSidebar.groups(matching: "countdown").map(\.sections) == [[.timer]])
    }

    @Test("The Plugins section starts unfolded, and its fold is kept with the other preferences")
    @MainActor
    func pluginsFold() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.foldsSettingsSidebarPlugins)
        preferences.foldsSettingsSidebarPlugins = true
        #expect(AppPreferences(defaults: defaults).foldsSettingsSidebarPlugins)
    }

    @Test("The Plugins page lists every plugin in one list, Quick Search first, then by name, and filters by name or keyword (#559)")
    func pluginsTable() {
        #expect(PluginsTable.plugins == Self.allPlugins)
        #expect(PluginsTable.plugins(matching: "countdown") == [.timer])
        #expect(PluginsTable.plugins(matching: "translate") == [.translation])
        #expect(PluginsTable.plugins(matching: "keycastr") == [.keystrokes])
        #expect(PluginsTable.plugins(matching: "DICT") == [.dictation])
        #expect(PluginsTable.plugins(matching: "zzz").isEmpty)
    }

    @Test("A plugin row's Open on keybumps.app goes to its own page there, named as the website names it")
    func pluginPageLinks() {
        let slugs = Dictionary(uniqueKeysWithValues: Capability.allCases.map {
            ($0, PluginLinks.page(for: $0).absoluteString)
        })
        #expect(slugs == [
            .quickSearch: "https://keybumps.app/plugins/quick-search/",
            .clipboardHistory: "https://keybumps.app/plugins/clipboard-history/",
            .screenshotTools: "https://keybumps.app/plugins/screengrabs/",
            .dictation: "https://keybumps.app/plugins/dictation/",
            .windowManagement: "https://keybumps.app/plugins/window-manager/",
            .keyboardShortcutter: "https://keybumps.app/plugins/shortcut-coach/",
            .snippets: "https://keybumps.app/plugins/snippets/",
            .timer: "https://keybumps.app/plugins/timer/",
            .emojiPicker: "https://keybumps.app/plugins/emoji-picker/",
            .translation: "https://keybumps.app/plugins/translation/",
            .keystrokes: "https://keybumps.app/plugins/keystrokes/",
        ])
    }

    @Test("A Plugins row shows its tab's key, its place among the tabs shown, or a dash while it isn't shown, and the first shortcut and how many more")
    func pluginsRowKeys() {
        // The tabs of the plugins that ship on, with the Hotkeys tab hidden, as it starts.
        let shown: [CommandPaletteTab] = [.search, .clipboard, .screenshots, .dictation, .snippets, .timers]
        #expect(PluginsTable.tabKey(for: .timer, shownTabs: shown) == "⌘6")
        #expect(PluginsTable.tabKey(for: .windowManagement, shownTabs: shown) == "", "No tab")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, shownTabs: shown) == "—", "The Hotkeys tab is hidden")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, shownTabs: shown + [.keyboardShortcutter]) == "⌘7")
        #expect(PluginsTable.tabKey(for: .emojiPicker, shownTabs: shown) == "—", "Emoji ships off")
        #expect(PluginsTable.tabKey(for: .translation, shownTabs: shown + [.translate]) == "⌘7")
        #expect(PluginsTable.tabKey(for: .keystrokes, shownTabs: shown) == "", "No tab")
        #expect(PluginsTable.tabKey(for: .screenshotTools, shownTabs: shown) == "⌘3")
        // Hiding the Search tab took the place of turning Quick Search off (#553); the tabs after it move up.
        #expect(PluginsTable.tabKey(for: .quickSearch, shownTabs: shown) == "⌘1")
        let searchHidden = Array(shown.dropFirst())
        #expect(PluginsTable.tabKey(for: .quickSearch, shownTabs: searchHidden) == "—", "The Search tab is hidden")
        #expect(PluginsTable.tabKey(for: .clipboardHistory, shownTabs: searchHidden) == "⌘1")

        let key = ShortcutBinding(keyCode: 1, modifiers: 0, displayName: "⇧⌘2")
        // ScreenGrabs' three screenshot hotkeys and Record Screen; the recording shortcuts work only while recording.
        #expect(PluginsTable.shortcutText(for: .screenshotTools) { _ in key } == "⇧⌘2 +3")
        #expect(PluginsTable.shortcutText(for: .screenshotTools) { $0 == .screenshotAreaAndEdit ? key : nil } == "⇧⌘2")
        #expect(PluginsTable.shortcutText(for: .timer) { _ in nil } == "", "Unassigned")
    }

    @Test("The default capabilities are the seven Keybumps was locked at; anything newer is added")
    func defaultCapabilities() {
        #expect(CapabilityCatalog.defaultCapabilities == [
            .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets
        ])
        #expect(!CapabilityCatalog.defaultCapabilities.contains(.timer))
    }

    @Test("Icon tiles and the avatar grow with System Settings' sidebar icon size, as the list's own text does")
    func rowSizes() {
        #expect(SettingsSidebar.iconSize(for: .small) < SettingsSidebar.iconSize(for: .medium))
        #expect(SettingsSidebar.iconSize(for: .medium) < SettingsSidebar.iconSize(for: .large))
        #expect(SettingsSidebar.avatarSize(for: .small) < SettingsSidebar.avatarSize(for: .medium))
        #expect(SettingsSidebar.avatarSize(for: .medium) < SettingsSidebar.avatarSize(for: .large))
        #expect(SettingsSidebar.avatarSize(for: .medium) > SettingsSidebar.iconSize(for: .medium), "The account row stands out")
    }

    @Test("VoiceOver counts permissions on Permissions, and a plugin's row says it needs attention")
    func attentionLabels() {
        #expect(SettingsSidebar.attentionLabel(2, for: .permissions) == "2 permission items need attention")
        #expect(SettingsSidebar.attentionLabel(1, for: .screenshotTools) == "Needs attention")
        #expect(SettingsSidebar.attentionLabel(1, for: .updateAvailable) == "1 update")
    }

    // MARK: Update Available (#559)

    @Test("The Update Available row shows exactly while the menu bar icon shows its update dot, and opens Changelog (#559)")
    @MainActor
    func updateRowFollowsTheUpdateDot() {
        func snapshot(_ status: UpdateStatus, canRestart: Bool = false) -> UpdateSnapshot {
            var snapshot = UpdateSnapshot(status: .idle, automaticallyChecks: true, canCheck: true, canRestart: canRestart)
            snapshot.setStatus(status)
            return snapshot
        }
        let waiting = [
            snapshot(.available(version: "0.0.3-beta.31")),
            snapshot(.downloading(version: "0.0.3-beta.31")),
            snapshot(.readyToRestart(version: "0.0.3-beta.31"), canRestart: true),
            snapshot(.renewalRequired(version: "0.0.4")),
        ]
        for update in waiting {
            #expect(SettingsSidebar.showsUpdateRow(update), "\(update.status)")
            #expect(SettingsSidebar.showsUpdateRow(update) == MenuBarAttention.updateIsWaiting(update), "one source with the dot")
        }
        var failedAfterFinding = snapshot(.available(version: "0.0.3-beta.31"))
        failedAfterFinding.setStatus(.failed("offline"))
        #expect(SettingsSidebar.showsUpdateRow(failedAfterFinding), "a failed check keeps the update it found")

        for nothing in [snapshot(.idle), snapshot(.current), snapshot(.checking), snapshot(.failed("offline")), snapshot(.unavailable("Debug"))] {
            #expect(!SettingsSidebar.showsUpdateRow(nothing), "\(nothing.status)")
        }

        #expect(SettingsSection.updateAvailable.page == .changelog, "choosing the row opens Changelog")
        #expect(SettingsSection.changelog.page == .changelog)
        #expect(SettingsSection.dictation.page == .dictation)
        #expect(SettingsSection.updateAvailable.sidebarTitle == "Update Available")
    }

    @Test("Update Available isn't a page: it's in no group, not in the pages Quick Search and launch tokens list, and no search finds it")
    func updateRowIsNotAPage() {
        #expect(!SettingsSection.allCases.contains(.updateAvailable))
        #expect(!SettingsSidebar.groups(matching: "").flatMap(\.sections).contains(.updateAvailable))
        #expect(!SettingsSidebar.groups(matching: "update").flatMap(\.sections).contains(.updateAvailable))
        #expect(SettingsSection(launchToken: "updateAvailable") == nil)
    }

    @Test("While an update waits, its row has a red 1, and it goes when the update installs or is skipped (#559)")
    @MainActor
    func updateRowBadge() {
        let updater = FakeUpdateController()
        let model = AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: ManualActionDetector(monitor: UpdaterTestPointerMonitor(), permissions: UpdaterTestPermissions()),
            updater: updater
        )
        #expect(!SettingsSidebar.showsUpdateRow(model.updateSnapshot))
        #expect(model.settingsAttentionCount(for: .updateAvailable) == 0)

        updater.emit(.available(version: "0.0.3-beta.31"))
        #expect(SettingsSidebar.showsUpdateRow(model.updateSnapshot))
        #expect(model.settingsAttentionCount(for: .updateAvailable) == 1)
        #expect(model.menuBarAttention.showsDot, "with the menu bar icon's dot")
        #expect(model.settingsAttentionCount(for: .changelog) == 0, "the badge is on the Update Available row only")

        updater.emit(.idle)
        #expect(!SettingsSidebar.showsUpdateRow(model.updateSnapshot))
        #expect(model.settingsAttentionCount(for: .updateAvailable) == 0)
    }

    // MARK: Reopening (#559)

    @Test("Settings reopens on the page last open, and on Permissions only while a permission is missing (#559)")
    func openingPage() {
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: nil) == .general, "first open")
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: .dictation) == .dictation)
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: .changelog) == .changelog)
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: .account) == .account)
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 2, lastPage: .dictation) == .permissions)
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 1, lastPage: nil) == .permissions)
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: .permissions) == .general,
                "not Permissions with nothing missing")
        #expect(SettingsNavigationHistory.openingPage(missingPermissionCount: 0, lastPage: .updateAvailable) == .changelog)
    }

    @Test("The page last open is kept with the other preferences, and a page this version doesn't have reads as none")
    @MainActor
    func lastPageIsKept() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.lastSettingsPage == nil)
        preferences.lastSettingsPage = .timer
        #expect(AppPreferences(defaults: defaults).lastSettingsPage == .timer)
        preferences.lastSettingsPage = .changelog
        #expect(AppPreferences(defaults: defaults).lastSettingsPage == .changelog)

        defaults.set("aPageFromALaterVersion", forKey: "lastSettingsPage")
        #expect(AppPreferences(defaults: defaults).lastSettingsPage == nil)
        #expect(SettingsNavigationHistory.openingPage(
            missingPermissionCount: 0,
            lastPage: AppPreferences(defaults: defaults).lastSettingsPage
        ) == .general)
    }

    @Test("Forward returns through screens left with Back, and a new visit clears it")
    func forwardHistory() {
        var navigation = SettingsNavigationHistory()
        navigation.navigate(to: .dictation)
        navigation.navigate(to: .general)
        navigation.goBack()
        #expect(navigation.selection == .dictation)
        #expect(navigation.canGoForward)
        navigation.goForward()
        #expect(navigation.selection == .general)
        #expect(!navigation.canGoForward)

        navigation.goBack()
        navigation.navigate(to: .windows)
        #expect(!navigation.canGoForward)
    }
}
