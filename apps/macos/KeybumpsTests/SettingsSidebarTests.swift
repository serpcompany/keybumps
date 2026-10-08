import Testing
@testable import Keybumps

@Suite("Settings sidebar")
struct SettingsSidebarTests {
    @Test("General, Permissions, Plugins, and Changelog come first, then a row per plugin: the default ones, then added ones")
    func groupsAppPagesThenPlugins() {
        #expect(SettingsSidebar.groups(matching: "") == [
            [.general, .permissions, .plugins, .changelog],
            [.search, .clipboard, .dictation, .screenshotTools, .keyboardShortcutter, .snippets, .windows],
            [.emojiPicker, .timer, .translation],
        ])
    }

    @Test("Search finds pages and plugins by name and drops empty groups")
    func searchFiltersByName() {
        #expect(SettingsSidebar.groups(matching: "  clip ") == [[.clipboard]])
        #expect(SettingsSidebar.groups(matching: "PERM") == [[.permissions]])
        #expect(SettingsSidebar.groups(matching: "zzz").isEmpty)
        #expect(SettingsSidebar.groups(matching: "tim") == [[.timer]])
        #expect(SettingsSidebar.groups(matching: "plug") == [[.plugins]])
        #expect(SettingsSidebar.groups(matching: "change") == [[.changelog]])
    }

    @Test("The Plugins page lists the default plugins, Quick Search first, then added ones, and filters by name or keyword")
    func pluginsTable() {
        #expect(PluginsTable.sections == [
            .init(title: "Default", plugins: [.search, .clipboard, .dictation, .screenshotTools, .keyboardShortcutter, .snippets, .windows]),
            .init(title: "Added", plugins: [.emojiPicker, .timer, .translation]),
        ])
        #expect(PluginsTable.sections(matching: "countdown") == [.init(title: "Added", plugins: [.timer])])
        #expect(PluginsTable.sections(matching: "translate") == [.init(title: "Added", plugins: [.translation])])
        #expect(PluginsTable.sections(matching: "DICT").map(\.plugins) == [[.dictation]])
        #expect(PluginsTable.sections(matching: "zzz").isEmpty)
    }

    @Test("A Plugins row shows the tab's Command-number while the tab can show, and the first shortcut and how many more")
    func pluginsRowKeys() {
        #expect(PluginsTable.tabKey(for: .timer, showsHotkeysTab: false) == "⌘6")
        #expect(PluginsTable.tabKey(for: .windowManagement, showsHotkeysTab: true) == "", "No tab")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, showsHotkeysTab: false) == "", "The Hotkeys tab is hidden")
        #expect(PluginsTable.tabKey(for: .keyboardShortcutter, showsHotkeysTab: true) == "⌘9")
        #expect(PluginsTable.tabKey(for: .emojiPicker, showsHotkeysTab: false) == "⌘7")
        #expect(PluginsTable.tabKey(for: .translation, showsHotkeysTab: false) == "⌘8")

        let key = ShortcutBinding(keyCode: 1, modifiers: 0, displayName: "⇧⌘2")
        #expect(PluginsTable.shortcutText(for: .screenshotTools) { _ in key } == "⇧⌘2 +2")
        #expect(PluginsTable.shortcutText(for: .screenshotTools) { $0 == .screenshotArea ? key : nil } == "⇧⌘2")
        #expect(PluginsTable.shortcutText(for: .timer) { _ in nil } == "", "Unassigned")
    }

    @Test("The default capabilities are the seven Keybumps was locked at; anything newer is added")
    func defaultCapabilities() {
        #expect(CapabilityCatalog.defaultCapabilities == [
            .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets
        ])
        #expect(!CapabilityCatalog.defaultCapabilities.contains(.timer))
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
