import Testing
@testable import Keybumps

@Suite("Settings sidebar")
struct SettingsSidebarTests {
    @Test("General and Permissions come first, then Plugins, as in Raycast's settings")
    func groupsAppPagesThenPlugins() {
        #expect(SettingsSidebar.groups(matching: "") == [[.general, .permissions], [.plugins]])
        // Every plugin page shows inside Plugins.
        let pluginPagesAreInPlugins = SettingsSection.allCases.filter { $0.capability != nil }.allSatisfy(\.isInPlugins)
        #expect(pluginPagesAreInPlugins)
        #expect(SettingsSection.plugins.isInPlugins)
        #expect(!SettingsSection.general.isInPlugins)
    }

    @Test("Search finds pages and plugins by name and drops empty groups")
    func searchFiltersByName() {
        #expect(SettingsSidebar.groups(matching: "  clip ") == [[.clipboard]])
        #expect(SettingsSidebar.groups(matching: "PERM") == [[.permissions]])
        #expect(SettingsSidebar.groups(matching: "zzz").isEmpty)
        #expect(SettingsSidebar.groups(matching: "tim") == [[.timer]])
        #expect(SettingsSidebar.groups(matching: "plug") == [[.plugins]])
    }

    @Test("The Plugins table lists the default plugins, Quick Search first, then added ones, and filters by name or keyword")
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
