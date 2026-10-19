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

    @Test("A Plugins row shows the tab's Command-number while the tab can show, and the first shortcut and how many more")
    func pluginsRowKeys() {
        #expect(PluginsTable.tabKey(for: .timer, showsHotkeysTab: false) == "⌘6")
        #expect(PluginsTable.tabKey(for: .windowManagement, showsHotkeysTab: true) == "", "No tab")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, showsHotkeysTab: false) == "", "The Hotkeys tab is hidden")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, showsHotkeysTab: true) == "⌘9")
        #expect(PluginsTable.tabKey(for: .emojiPicker, showsHotkeysTab: false) == "⌘7")
        #expect(PluginsTable.tabKey(for: .translation, showsHotkeysTab: false) == "⌘8")
        #expect(PluginsTable.tabKey(for: .keystrokes, showsHotkeysTab: true) == "", "No tab")
        #expect(PluginsTable.tabKey(for: .screenshotTools, showsHotkeysTab: false) == "⌘3")

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
