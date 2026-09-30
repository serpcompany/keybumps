import Foundation
import Testing
@testable import Keybumps

/// Keybumps Settings as Quick Search offers it (#171): which queries find it, where it ranks, and
/// the Command Palette entry points that open it.
@MainActor
@Suite("Quick Search commands")
struct QuickSearchCommandTests {
    private let settings = QuickSearchCommand.keybumpsSettings

    @Test("Keybumps Settings is named for the product and shows Command-comma")
    func presentation() throws {
        #expect(settings.title == "Keybumps Settings")
        #expect(settings.kindLabel == "Command")
        #expect(ShortcutKeycapPresentation(shortcut: try #require(settings.shortcut)).keys == ["⌘", ","])
        #expect(settings.rowShortcut(enabledCapabilities: [], visibleTabs: []) == "⌘,")
    }

    @Test(
        "Whole words of its name match by name",
        arguments: [
            "settings", "Settings", "  SETTINGS  ", "SÉTTINGS", "keybumps", "Keybumps Settings",
            "settings keybumps", "keybumps-settings",
        ]
    )
    func nameMatches(query: String) {
        #expect(settings.match(query) == .name)
    }

    /// Since #182, a keyword ranks a command after the apps, like any capability command's keyword.
    /// No stock app is named Preferences on macOS 14.2 and later (System Preferences became System
    /// Settings), so in practice these still list it first.
    @Test("Its keywords, alone or with its name, match by keyword", arguments: ["preferences", "prefs", "Keybumps Prefs"])
    func keywordMatches(query: String) {
        #expect(settings.match(query) == .keyword)
    }

    @Test(
        "Words that start its name or keywords match as a prefix",
        arguments: ["k", "keyb", "sett", "setting", "pref", "preference", "keybumps pref", "KEYBUMPS SETT"]
    )
    func prefixMatches(query: String) {
        #expect(settings.match(query) == .prefix)
    }

    @Test(
        "Other queries don't offer it",
        arguments: ["", "   ", "system", "system settings", "safari", "settingsx", "ettings", "open settings", "keybumps app"]
    )
    func nonMatches(query: String) {
        #expect(settings.match(query) == nil)
    }

    // MARK: Ranking

    private let keybumpsApp = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Keybumps.app"), kind: .application)
    private let systemSettings = QuickSearchResult(
        url: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
        kind: .application
    )
    private let preview = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Preview.app"), kind: .application)
    private let safari = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Safari.app"), kind: .application)
    private let file = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/fixture/settings.txt"), kind: .file)

    @Test("A word of its name puts it first, above apps and files; a keyword lists it after apps")
    func exactQueryRanksFirst() {
        #expect(
            QuickSearchRanking.items(matching: "settings", applications: [systemSettings], files: [file])
                == [.command(settings), .result(systemSettings), .result(file)]
        )
        #expect(
            QuickSearchRanking.items(matching: "prefs", applications: [], files: [file])
                == [.command(settings), .result(file)]
        )
        let preferencesApp = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Preferences Helper.app"), kind: .application)
        #expect(
            QuickSearchRanking.items(matching: "preferences", applications: [preferencesApp], files: [file])
                == [.result(preferencesApp), .command(settings), .result(file)]
        )
    }

    @Test("A partial query lists it after the apps and before files")
    func partialQueryFollowsApps() {
        #expect(
            QuickSearchRanking.items(matching: "sett", applications: [systemSettings], files: [file])
                == [.result(systemSettings), .command(settings), .result(file)]
        )
    }

    @Test("Unrelated queries list only apps and files")
    func unrelatedQueryOmitsIt() {
        #expect(
            QuickSearchRanking.items(matching: "safari", applications: [safari], files: [file])
                == [.result(safari), .result(file)]
        )
    }

    @Test("With the real app ranking, a few letters still find apps first")
    func rankingWithApplications() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-search-command-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let usage = ApplicationUsageStore(storageURL: storageURL)
        let applications = [keybumpsApp, preview, safari, systemSettings]
        func items(_ query: String) -> [QuickSearchItem] {
            QuickSearchRanking.items(
                matching: query,
                applications: QuickSearchRanking.sortedApplications(matching: query, from: applications, usage: usage),
                files: []
            )
        }

        #expect(items("settings") == [.command(settings), .result(systemSettings)])
        #expect(items("keybumps") == [.command(settings), .result(keybumpsApp)], "Opening Keybumps from its own palette only reopens it")
        #expect(items("preferences") == [.command(settings)])
        #expect(items("pre") == [.result(preview), .command(settings)])
        // Capability commands whose names or keywords start with "s" follow too (#182).
        #expect(items("s") == [
            .result(safari), .result(systemSettings), .result(keybumpsApp),
            .command(settings), .command(.capability(.screenshotTools)), .command(.capability(.dictation)),
            .command(.capability(.windowManagement)), .command(.capability(.keyboardShortcutter)),
        ])
    }

    // MARK: Command Palette entry points

    @Test("Command-comma runs it and takes no key the palette already uses")
    func commandKey() {
        #expect(QuickSearchCommand.matchingCommandKey(",") == settings)
        #expect(QuickSearchCommand.matchingCommandKey("1") == nil)
        #expect(QuickSearchCommand.matchingCommandKey(nil) == nil)
        for command in QuickSearchCommand.allCases {
            #expect(CommandPaletteTab.matchingCommandKey(command.commandKey) == nil, "\(command) shares a tab's key")
            // Command-E edits a clipboard image or screenshot.
            #expect(command.commandKey?.lowercased() != "e")
        }
    }

    /// This never shows the palette: even invisible, a shown panel becomes the key window and would
    /// take keyboard focus from whatever the owner is using. The UI tests cover the palette closing
    /// and the real Settings route.
    @Test("Running it from the palette calls the Settings route once")
    func runOpensSettings() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsQuickSearchCommand-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [], missing: nil, root: root)
        let palette = harness.model.commandPalette
        var opened: [SettingsSection?] = []
        palette.openSettings = { opened.append($0) }

        palette.run(.keybumpsSettings)

        #expect(opened == [nil], "Settings opens where it was left")
    }
}
