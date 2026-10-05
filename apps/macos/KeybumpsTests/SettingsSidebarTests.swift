import Testing
@testable import Keybumps

@Suite("Settings sidebar")
struct SettingsSidebarTests {
    @Test("General, Permissions, and Plugins come first, then a row per plugin: the default ones, then added ones")
    func groupsAppPagesThenPlugins() {
        #expect(SettingsSidebar.groups(matching: "") == [
            [.general, .permissions, .plugins],
            [.search, .clipboard, .dictation, .screenshotTools, .keyboardShortcutter, .snippets, .windows],
            [.timer],
        ])
    }

    @Test("Search finds pages and plugins by name and drops empty groups")
    func searchFiltersByName() {
        #expect(SettingsSidebar.groups(matching: "  clip ") == [[.clipboard]])
        #expect(SettingsSidebar.groups(matching: "PERM") == [[.permissions]])
        #expect(SettingsSidebar.groups(matching: "zzz").isEmpty)
        #expect(SettingsSidebar.groups(matching: "tim") == [[.timer]])
        #expect(SettingsSidebar.groups(matching: "plug") == [[.plugins]])
    }

    @Test("The Plugins page lists the default plugins, Quick Search first, then added ones, and filters by name or keyword")
    func pluginsTable() {
        #expect(PluginsTable.sections == [
            .init(title: "Default", plugins: [.search, .clipboard, .dictation, .screenshotTools, .keyboardShortcutter, .snippets, .windows]),
            .init(title: "Added", plugins: [.timer]),
        ])
        #expect(PluginsTable.sections(matching: "countdown") == [.init(title: "Added", plugins: [.timer])])
        #expect(PluginsTable.sections(matching: "DICT").map(\.plugins) == [[.dictation]])
        #expect(PluginsTable.sections(matching: "zzz").isEmpty)
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
