import Testing
@testable import Keybumps

@Suite("Settings sidebar")
struct SettingsSidebarTests {
    @Test("App pages come first, then capabilities alphabetically, as in Raycast's Settings")
    func groupsAppPagesThenCapabilitiesAlphabetically() {
        let groups = SettingsSidebar.groups(matching: "")
        #expect(groups == [
            [.general, .permissions],
            [.clipboard, .dictation, .keyboardShortcutter, .search, .screenshotTools, .windows]
        ])
        // The account row sits above the groups, as in Raycast.
        #expect(Set(groups.flatMap { $0 }) == Set(SettingsSection.allCases).subtracting([.account]))
    }

    @Test("Search filters pages by name and drops empty groups")
    func searchFiltersByName() {
        #expect(SettingsSidebar.groups(matching: "  clip ") == [[.clipboard]])
        #expect(SettingsSidebar.groups(matching: "PERM") == [[.permissions]])
        #expect(SettingsSidebar.groups(matching: "zzz").isEmpty)
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
