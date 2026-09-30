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

    /// Since #182, with no history a keyword ranks a command after the apps, like any capability
    /// command's keyword. No stock app is named Preferences on macOS 14.2 and later (System
    /// Preferences became System Settings), so in practice these still list it first.
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
            .command(.capability(.snippets)),
        ])
    }

    /// #179 listed Keybumps Settings above System Settings for "settings" whatever the history. Since
    /// #186 the owner's rule applies: what the user picks more ranks first, as among apps.
    @Test("Learned usage decides between Keybumps Settings and System Settings for \"settings\"")
    func historyDecidesSettings() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-search-command-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let usage = ApplicationUsageStore(storageURL: storageURL, now: { now })
        func items() -> [QuickSearchItem] {
            QuickSearchRanking.items(
                matching: "settings",
                applications: QuickSearchRanking.sortedApplications(matching: "settings", from: [systemSettings], usage: usage),
                files: [file],
                usage: usage
            )
        }

        #expect(items() == [.command(settings), .result(systemSettings), .result(file)], "No history: as in #179")
        // System Settings only starts a word with "settings", so it needs four picks to pass the name match.
        for _ in 1...3 { usage.record(systemSettings) }
        #expect(items().first == .command(settings))
        usage.record(systemSettings)
        #expect(items() == [.result(systemSettings), .command(settings), .result(file)])
        usage.record(settings)
        #expect(items() == [.command(settings), .result(systemSettings), .result(file)])
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

    // MARK: Keybumps's own app (owner QA of 4015.182.3)

    @Test("A copy of Keybumps stands in for Keybumps Settings: this app, or any build found by its bundle identifier")
    func keybumpsAppStandsInForSettings() {
        let running = URL(fileURLWithPath: "/tmp/fixture/Build/Products/Debug/Keybumps.app")
        let identifiers = [
            "/Applications/Keybumps.app": "com.serp.keybumps",
            "/Applications/Keybumps Debug.app": "com.serp.keybumps.debug",
            "/Applications/KeybumpsTests.app": "com.serp.keybumps.tests",
            "/Applications/Utilities/Keybumps.app": "com.example.keybumps",
            "/Applications/Safari.app": "com.apple.Safari",
        ]
        func standIn(_ path: String, kind: QuickSearchResult.Kind = .application) -> QuickSearchCommand? {
            QuickSearchCommand.standIn(
                for: QuickSearchResult(url: URL(fileURLWithPath: path), kind: kind),
                runningAppURL: running,
                bundleIdentifier: { identifiers[$0.path] }
            )
        }

        #expect(standIn(running.path) == settings, "This app, whatever its identifier")
        #expect(standIn("/Applications/Keybumps.app") == settings, "The installed release or QA copy")
        #expect(standIn("/Applications/Keybumps Debug.app") == settings, "A Debug build")
        #expect(standIn("/Applications/KeybumpsTests.app") == nil)
        #expect(standIn("/Applications/Utilities/Keybumps.app") == nil, "The name isn't read; another app named Keybumps opens normally")
        #expect(standIn("/Applications/Safari.app") == nil)
        #expect(standIn("/Applications/Unreadable.app") == nil, "No bundle identifier")
        #expect(standIn("/Applications/Keybumps.app", kind: .folder) == nil, "Only apps")
        // The unit-test host is Keybumps itself.
        #expect(QuickSearchCommand.standIn(for: QuickSearchResult(url: Bundle.main.bundleURL, kind: .application)) == settings)
        // The real reader on the test host, a Debug build, as if it were another copy: pins the Debug
        // identifier in `keybumpsBundleIdentifiers` to the one `project.yml` gives the build.
        #expect(Bundle.main.bundleIdentifier.map(QuickSearchCommand.keybumpsBundleIdentifiers.contains) == true)
        #expect(QuickSearchCommand.standIn(
            for: QuickSearchResult(url: Bundle.main.bundleURL, kind: .application),
            runningAppURL: URL(fileURLWithPath: "/tmp/fixture/Other/Keybumps.app")
        ) == settings)
    }

    /// Before, the palette asked macOS to open Keybumps's own bundle. macOS reopened the running app,
    /// the reopen showed Quick Search again (as a Dock click does), and Settings opened under it.
    @Test("Opening Keybumps from Quick Search runs Keybumps Settings: Settings once, no open, no Recent Item")
    func openingKeybumpsRunsSettings() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsOwnApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, quickSearch: search)
        let palette = harness.model.commandPalette
        var opened: [SettingsSection?] = []
        palette.openSettings = { opened.append($0) }
        var openedURLs: [URL] = []
        palette.openURL = { openedURLs.append($0); return true }
        let keybumps = QuickSearchResult(url: Bundle.main.bundleURL, kind: .application)

        palette.open(keybumps)

        #expect(opened == [nil], "Settings opens once, where it was left")
        #expect(openedURLs.isEmpty, "macOS is never asked to open Keybumps, which would reopen it")
        #expect(search.recentItems.items.isEmpty, "Keybumps never becomes a Recent Item")
        #expect(search.applicationUsage.record(for: settings)?.launchCount == 1, "Learned as Keybumps Settings")
        #expect(search.applicationUsage.record(for: keybumps.url) == nil)

        // Any other app still opens through the workspace and becomes a Recent Item.
        palette.open(preview)
        #expect(openedURLs == [preview.url])
        #expect(search.recentItems.items.map(\.result) == [preview])
        #expect(opened == [nil])
    }

    /// Owner decision on #186: Keybumps Settings covers Keybumps, so its app row is never listed.
    @Test("Quick Search never lists Keybumps itself as an app, even with old learned usage")
    func keybumpsIsNeverAnAppResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsHiddenApp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = QuickSearchResult(url: Bundle.main.bundleURL, kind: .application)
        let copy = try Self.makeApp(named: "Keybumps Copy", identifier: "com.serp.keybumps", in: root)
        let other = try Self.makeApp(named: "Keybumps Companion", identifier: "com.example.companion", in: root)
        let search = QuickSearchModel.forTests(in: root, applications: [running, copy, other, preview])
        // An installed copy opened before this change has learned usage; it must not bring the row back.
        for _ in 1...5 { search.applicationUsage.record(copy) }

        search.query = "keybumps"
        #expect(search.items == [.command(settings), .result(other)], "Keybumps Settings, and only apps that aren't Keybumps")
        search.query = running.name
        #expect(!search.results.contains(running))
        search.query = "preview"
        #expect(search.results == [preview])
    }

    @Test("Recent Items never show Keybumps itself, even an entry saved before it was hidden")
    func recentItemsHideKeybumps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsHiddenRecent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let running = QuickSearchResult(url: Bundle.main.bundleURL, kind: .application)
        let copy = try Self.makeApp(named: "Keybumps Copy", identifier: "com.serp.keybumps.debug", in: root)
        let search = QuickSearchModel.forTests(in: root)

        search.recentItems.record(running)
        search.recentItems.record(preview)
        search.recentItems.record(copy)

        #expect(search.recentItems.items.count == 3, "Older entries stay stored")
        #expect(search.displayedRecentItems.map(\.result) == [preview])
        // As in the UI test, entries saved earlier are hidden once loaded from disk.
        let reloaded = QuickSearchModel.forTests(in: root)
        #expect(reloaded.recentItems.items.count == 3)
        #expect(reloaded.displayedRecentItems.map(\.result) == [preview])
    }

    /// A minimal app bundle in a temporary folder: enough for `Bundle(url:)` to read its identifier.
    private static func makeApp(named name: String, identifier: String, in root: URL) throws -> QuickSearchResult {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return QuickSearchResult(url: app, kind: .application)
    }
}
