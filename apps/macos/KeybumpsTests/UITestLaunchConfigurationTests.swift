import Foundation
import Testing
@testable import Keybumps

struct UITestLaunchConfigurationTests {
    private let executable = "/Applications/Keybumps.app/Contents/MacOS/Keybumps"

    @Test func productionLaunchIsNotUITesting() {
        let configuration = UITestLaunchConfiguration(arguments: [executable])
        #expect(!configuration.isUITesting)
        #expect(configuration.permissions == nil)
        #expect(configuration.openPalette == nil)
        #expect(configuration.openSettings == nil)
        #expect(!configuration.closesSettings)
        #expect(!configuration.disablesHotKeys)
        #expect(!configuration.seedsClipboardImage)
        #expect(!configuration.seedsRecentKeybumps)
        #expect(!configuration.seedsSnippets)
    }

    @Test func otherFlagsAreIgnoredWithoutThePermissionsFlag() {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBOpenPalette", "clipboard", "-KBOpenSettings", "general", "-KBCloseSettings", "YES",
            "-KBDisableHotKeys",
        ])
        #expect(configuration == UITestLaunchConfiguration(arguments: [executable]))
    }

    @Test(arguments: [
        ("granted", UITestLaunchConfiguration.PermissionMode.granted),
        ("denied", .denied),
    ])
    func parsesPermissionMode(raw: String, expected: UITestLaunchConfiguration.PermissionMode) {
        let configuration = UITestLaunchConfiguration(arguments: [executable, "-KBUITestPermissions", raw])
        #expect(configuration.isUITesting)
        #expect(configuration.permissions == expected)
    }

    @Test(arguments: ["", "maybe", "-KBDisableHotKeys"])
    func rejectsUnknownOrMissingPermissionMode(raw: String) {
        let configuration = UITestLaunchConfiguration(arguments: [executable, "-KBUITestPermissions", raw])
        #expect(!configuration.isUITesting)
    }

    @Test func permissionsFlagWithoutValueIsNotUITesting() {
        #expect(!UITestLaunchConfiguration(arguments: [executable, "-KBUITestPermissions"]).isUITesting)
    }

    @Test(arguments: CommandPaletteTab.allCases)
    func parsesEveryPaletteTab(tab: CommandPaletteTab) {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "granted", "-KBOpenPalette", tab.rawValue,
        ])
        #expect(configuration.openPalette == tab)
    }

    @Test(arguments: SettingsSection.allCases)
    func parsesEverySettingsSectionCaseInsensitively(section: SettingsSection) {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "denied", "-KBOpenSettings", section.launchToken.uppercased(),
        ])
        #expect(configuration.openSettings == section)
    }

    @Test func ignoresUnknownPaletteTabAndSettingsSection() {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "granted", "-KBOpenPalette", "nope", "-KBOpenSettings", "Quick Search",
        ])
        #expect(configuration.isUITesting)
        #expect(configuration.openPalette == nil)
        #expect(configuration.openSettings == nil)
    }

    @Test(arguments: [
        (["-KBDisableHotKeys"], true),
        (["-KBDisableHotKeys", "YES"], true),
        (["-KBDisableHotKeys", "-KBOpenPalette", "search"], true),
        (["-KBDisableHotKeys", "NO"], false),
        ([], false),
    ])
    func parsesBooleanFlags(extra: [String], expected: Bool) {
        let configuration = UITestLaunchConfiguration(
            arguments: [executable, "-KBUITestPermissions", "granted"] + extra
        )
        #expect(configuration.disablesHotKeys == expected)
    }

    @Test(arguments: [(["-KBCloseSettings", "YES"], true), (["-KBCloseSettings", "NO"], false), ([], false)])
    func parsesCloseSettings(extra: [String], expected: Bool) {
        let configuration = UITestLaunchConfiguration(
            arguments: [executable, "-KBUITestPermissions", "granted", "-KBOpenPalette", "search"] + extra
        )
        #expect(configuration.closesSettings == expected)
    }

    @Test func parsesClipboardImageSeed() {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "granted", "-KBUITestSeedClipboardImage",
        ])
        #expect(configuration.seedsClipboardImage)
    }

    @Test func parsesRecentKeybumpsSeed() {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "granted", "-KBUITestSeedRecentKeybumps", "YES",
        ])
        #expect(configuration.seedsRecentKeybumps)
        #expect(!UITestLaunchConfiguration(arguments: [executable, "-KBUITestSeedRecentKeybumps", "YES"]).seedsRecentKeybumps)
    }

    @Test func parsesSnippetsSeed() {
        let configuration = UITestLaunchConfiguration(arguments: [
            executable, "-KBUITestPermissions", "granted", "-KBUITestSeedSnippets", "YES",
        ])
        #expect(configuration.seedsSnippets)
        #expect(!UITestLaunchConfiguration(arguments: [executable, "-KBUITestSeedSnippets", "YES"]).seedsSnippets)
    }

    @Test func settingsLaunchTokensAreUniqueAndStable() {
        let tokens = SettingsSection.allCases.map(\.launchToken)
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens == [
            "search", "clipboard", "screenshotTools", "dictation",
            "windows", "keyboardShortcutter", "snippets", "permissions", "general", "account",
        ])
    }

    @Test func settingsNavigationStartsAtRequestedSection() {
        #expect(SettingsNavigationHistory().selection == .permissions)
        var navigation = SettingsNavigationHistory(selection: .general)
        #expect(navigation.selection == .general)
        #expect(!navigation.canGoBack)
        navigation.navigate(to: .dictation)
        navigation.goBack()
        #expect(navigation.selection == .general)
    }
}

@MainActor
struct UITestFakeCompositionTests {
    @Test func dictationWithoutAudioCaptureFailsBeforeOpeningTheMicrophone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsDictationGate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DictationService(
            language: "en-US",
            history: DictationHistoryService(recordingsDirectoryURL: root),
            allowsSystemAccess: false
        )

        service.start()

        #expect(service.phase == .failed("Audio capture is unavailable in this session."))
    }
}
