import Foundation
import Testing
@testable import Keybumps

/// Navigating by searching (#182): each capability's Quick Search command, the words that find it,
/// where it ranks against real app names, and where it goes while the capability is on or off.
@MainActor
@Suite("Capability commands")
struct CapabilityCommandTests {
    private let clipboard = QuickSearchCommand.capability(.clipboardHistory)
    private let screenshots = QuickSearchCommand.capability(.screenshotTools)
    private let dictation = QuickSearchCommand.capability(.dictation)
    private let windows = QuickSearchCommand.capability(.windowManagement)
    private let coach = QuickSearchCommand.capability(.keyboardShortcutter)
    private let snippets = QuickSearchCommand.capability(.snippets)
    private let timer = QuickSearchCommand.capability(.timer)
    private let allCapabilities = Set(Capability.allCases)

    // MARK: Names

    @Test("Keybumps Settings and Plugins come first, then one command per capability except Quick Search, in registry order")
    func commands() {
        #expect(QuickSearchCommand.allCases == [.keybumpsSettings, .plugins, clipboard, screenshots, dictation, windows, coach, snippets, timer])
    }

    @Test("A capability has a command exactly when its descriptor declares search keywords")
    func commandsComeFromDescriptors() {
        let declared = CapabilityCatalog.descriptors
            .filter { $0.searchKeywords != nil }
            .map { QuickSearchCommand.capability($0.capability) }
        #expect(Array(QuickSearchCommand.allCases.dropFirst(2)) == declared)
        #expect(CapabilityDescriptor.quickSearch.searchKeywords == nil, "Quick Search's tab lists the commands")
    }

    @Test("Each command carries its capability's name, not its tab label, and the Command kind")
    func names() {
        #expect(QuickSearchCommand.allCases.map(\.title) == [
            "Keybumps Settings", "Plugins", "Clipboard History", "Screenshot Tools", "Dictation", "Window Manager", "Shortcut Coach",
            "Snippets", "Timer",
        ])
        #expect(QuickSearchCommand.allCases.allSatisfy { $0.kindLabel == "Command" })
        #expect(QuickSearchCommand.allCases.map(\.id) == [
            "keybumpsSettings", "plugins", "clipboardHistory", "screenshotTools", "dictation", "windowManagement", "keyboardShortcutter",
            "snippets", "timer",
        ])
    }

    @Test("Capability commands have no Command-key of their own; their tabs keep Command-number")
    func noCommandKeys() {
        for command in QuickSearchCommand.allCases where command != .keybumpsSettings {
            #expect(command.commandKey == nil)
            #expect(command.shortcut == nil)
        }
        for key in ["1", "2", "3", "4", "5", "e"] {
            #expect(QuickSearchCommand.matchingCommandKey(key) == nil, "⌘\(key)")
        }
    }

    // MARK: Matching

    @Test(
        "Whole words of its name match by name",
        arguments: [
            ("clipboard", QuickSearchCommand.capability(.clipboardHistory)),
            ("Clipboard History", .capability(.clipboardHistory)),
            ("history", .capability(.clipboardHistory)),
            ("screenshot", .capability(.screenshotTools)),
            ("screenshot tools", .capability(.screenshotTools)),
            ("DICTATION", .capability(.dictation)),
            ("window manager", .capability(.windowManagement)),
            ("window", .capability(.windowManagement)),
            ("shortcut coach", .capability(.keyboardShortcutter)),
            ("shortcut", .capability(.keyboardShortcutter)),
        ]
    )
    func nameMatches(query: String, command: QuickSearchCommand) {
        #expect(command.match(query) == .name)
    }

    @Test(
        "Its tab's name and what people call it match by keyword",
        arguments: [
            ("copy", QuickSearchCommand.capability(.clipboardHistory)),
            ("paste", .capability(.clipboardHistory)),
            ("screenshots", .capability(.screenshotTools)),
            ("screen", .capability(.screenshotTools)),
            ("capture", .capability(.screenshotTools)),
            ("dictate", .capability(.dictation)),
            ("voice", .capability(.dictation)),
            ("transcribe", .capability(.dictation)),
            ("recordings", .capability(.dictation)),
            ("history", .capability(.dictation)),
            ("dictation history", .capability(.dictation)),
            ("windows", .capability(.windowManagement)),
            ("snap", .capability(.windowManagement)),
            ("hotkeys", .capability(.keyboardShortcutter)),
            ("shortcuts", .capability(.keyboardShortcutter)),
            ("keyboard", .capability(.keyboardShortcutter)),
            ("history", .capability(.keyboardShortcutter)),
        ]
    )
    func keywordMatches(query: String, command: QuickSearchCommand) {
        #expect(command.match(query) == .keyword)
    }

    @Test(
        "A few letters match as a prefix",
        arguments: [
            ("clip", QuickSearchCommand.capability(.clipboardHistory)),
            ("dict", .capability(.dictation)),
            ("transcr", .capability(.dictation)),
            ("scr", .capability(.screenshotTools)),
            ("win", .capability(.windowManagement)),
            ("hot", .capability(.keyboardShortcutter)),
        ]
    )
    func prefixMatches(query: String, command: QuickSearchCommand) {
        #expect(command.match(query) == .prefix)
    }

    @Test("Queries that name something else find no capability command", arguments: ["safari", "settings", "prefs", "keybumps", "quick search", "dictionary"])
    func nonMatches(query: String) {
        for command in QuickSearchCommand.allCases where command != .keybumpsSettings {
            #expect(command.match(query) == nil, "\(command.id) for \(query)")
        }
    }

    // MARK: Ranking

    private let file = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/fixture/notes.txt"), kind: .file)

    /// Stock macOS apps, plus common third-party ones, whose names share a word with a command.
    private let shortcutsApp = app("/System/Applications/Shortcuts.app")
    private let screenshotApp = app("/System/Applications/Utilities/Screenshot.app")
    private let screenSharing = app("/System/Applications/Utilities/Screen Sharing.app")
    private let imageCapture = app("/System/Applications/Image Capture.app")
    private let voiceMemos = app("/System/Applications/VoiceMemos.app")
    private let voiceOverUtility = app("/System/Applications/Utilities/VoiceOver Utility.app")
    private let keyboardMaestro = app("/Applications/Keyboard Maestro.app")
    private let pasteApp = app("/Applications/Paste.app")
    private let windowsApp = app("/Applications/Windows App.app")
    private let dictionaryApp = app("/System/Applications/Dictionary.app")
    private let systemSettings = app("/System/Applications/System Settings.app")

    /// Quick Search's rows for a query over those apps, with the real app ranking and no files.
    /// Without `usage` there is no history.
    private func rows(_ query: String, usage: ApplicationUsageStore? = nil) -> [QuickSearchItem] {
        let usage = usage ?? Self.usageStore()
        let applications = [
            shortcutsApp, screenshotApp, screenSharing, imageCapture, voiceMemos, voiceOverUtility,
            keyboardMaestro, pasteApp, windowsApp, dictionaryApp, systemSettings,
        ]
        return QuickSearchRanking.items(
            matching: query,
            applications: QuickSearchRanking.sortedApplications(matching: query, from: applications, usage: usage),
            files: [],
            usage: usage
        )
    }

    /// Learned usage in a temporary file (written only once something is recorded; remove it with
    /// `defer`). Every use is at the same moment, so the recency bonus never varies.
    private static func usageStore(at url: URL = temporaryUsageURL()) -> ApplicationUsageStore {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return ApplicationUsageStore(storageURL: url, now: { now })
    }

    nonisolated private static func temporaryUsageURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("capability-command-usage-\(UUID().uuidString).json")
    }

    @Test(
        "A keyword never hides an app of that name: the app stays first and the command follows the apps",
        arguments: [
            ("shortcuts", QuickSearchCommand.capability(.keyboardShortcutter)),
            ("screen", .capability(.screenshotTools)),
            ("capture", .capability(.screenshotTools)),
            ("voice", .capability(.dictation)),
            ("keyboard", .capability(.keyboardShortcutter)),
            ("paste", .capability(.clipboardHistory)),
            ("windows", .capability(.windowManagement)),
        ]
    )
    func keywordFollowsApps(query: String, command: QuickSearchCommand) throws {
        let rows = rows(query)
        let commandIndex = try #require(rows.firstIndex(of: .command(command)), "\(command.id) is still listed")
        let appIndices = rows.indices.filter { rows[$0].result?.kind == .application }
        #expect(!appIndices.isEmpty, "\(query) names a real app")
        #expect(appIndices.allSatisfy { $0 < commandIndex }, "Return on \(query) opens the app")
    }

    @Test("The apps named by a keyword query come first in their own order")
    func keywordQueriesKeepAppsFirst() {
        #expect(rows("shortcuts") == [.result(shortcutsApp), .command(coach)])
        #expect(rows("capture") == [.result(imageCapture), .command(screenshots)])
        #expect(rows("keyboard") == [.result(keyboardMaestro), .command(coach)])
        #expect(rows("paste") == [.result(pasteApp), .command(clipboard)])
        #expect(rows("windows") == [.result(windowsApp), .command(windows)])
        #expect(rows("voice").last == .command(dictation))
        #expect(rows("voice").dropLast().allSatisfy { $0.result != nil })
    }

    @Test(
        "A query of its name puts the command first, above apps",
        arguments: [
            ("dictation", QuickSearchCommand.capability(.dictation)),
            ("clipboard", .capability(.clipboardHistory)),
            ("window manager", .capability(.windowManagement)),
            ("shortcut coach", .capability(.keyboardShortcutter)),
            ("screenshot tools", .capability(.screenshotTools)),
            ("settings", .keybumpsSettings),
        ]
    )
    func nameQueryRanksFirst(query: String, command: QuickSearchCommand) {
        #expect(rows(query).first == .command(command))
    }

    @Test("With no history, a name word shared with an app lists the command first: screenshot, shortcut")
    func nameWordSharedWithAnApp() {
        #expect(rows("screenshot") == [.command(screenshots), .result(screenshotApp)])
        #expect(rows("shortcut") == [.command(coach), .result(shortcutsApp)])
    }

    // MARK: Learned usage (owner decision on #186: history decides)

    @Test("Screenshot.app picked once rises above Screenshot Tools; the command picked more rises back")
    func historyDecidesScreenshot() {
        let url = Self.temporaryUsageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = Self.usageStore(at: url)

        usage.record(screenshotApp)
        #expect(rows("screenshot", usage: usage) == [.result(screenshotApp), .command(screenshots)])
        usage.record(screenshots)
        #expect(rows("screenshot", usage: usage) == [.command(screenshots), .result(screenshotApp)], "Picked as often: the name match wins")
        usage.record(screenshotApp)
        #expect(rows("screenshot", usage: usage).first == .result(screenshotApp))
        usage.record(screenshots)
        usage.record(screenshots)
        #expect(rows("screenshot", usage: usage) == [.command(screenshots), .result(screenshotApp)])
    }

    @Test("Shortcuts.app, a prefix of \"shortcut\", needs three picks to pass Shortcut Coach's name")
    func historyDecidesShortcut() {
        let url = Self.temporaryUsageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = Self.usageStore(at: url)

        usage.record(shortcutsApp)
        usage.record(shortcutsApp)
        #expect(rows("shortcut", usage: usage).first == .command(coach))
        usage.record(shortcutsApp)
        #expect(rows("shortcut", usage: usage) == [.result(shortcutsApp), .command(coach)])
        usage.record(coach)
        #expect(rows("shortcut", usage: usage) == [.command(coach), .result(shortcutsApp)])
    }

    /// Consistent with app learning, where an often-opened app with a weaker match passes an unused
    /// app with the exact name: a keyword command picked often enough passes the app it names.
    @Test("A keyword command rises above an app with that exact name only after six picks")
    func historyLiftsKeywordCommandsLikeApps() {
        let url = Self.temporaryUsageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = Self.usageStore(at: url)

        for _ in 1...5 { usage.record(coach) }
        #expect(rows("shortcuts", usage: usage) == [.result(shortcutsApp), .command(coach)])
        usage.record(coach)
        #expect(rows("shortcuts", usage: usage) == [.command(coach), .result(shortcutsApp)])
        #expect(rows("hotkeys", usage: usage) == [.command(coach)])
    }

    /// Usage is per item, so picks from any query (even "dictation", where it's first anyway) lift a
    /// command for every keyword and every prefix of one. An app whose name only starts with the
    /// query scores 6,000, so three picks within a day pass it (900 or 800 + 3 × 1,500 + 1,000);
    /// with older picks it takes four.
    @Test("Three recent picks lift a keyword or prefix command above apps whose names only start with the query")
    func historyLiftsKeywordAndPrefixCommandsPastPrefixApps() {
        let url = Self.temporaryUsageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = Self.usageStore(at: url)

        usage.record(dictation)
        usage.record(dictation)
        #expect(rows("voice", usage: usage) == [.result(voiceMemos), .result(voiceOverUtility), .command(dictation)])
        #expect(rows("vo", usage: usage) == [.result(voiceMemos), .result(voiceOverUtility), .command(dictation)])
        usage.record(dictation)
        #expect(rows("voice", usage: usage) == [.command(dictation), .result(voiceMemos), .result(voiceOverUtility)], "Keyword")
        #expect(rows("vo", usage: usage) == [.command(dictation), .result(voiceMemos), .result(voiceOverUtility)], "Prefix of a keyword")
    }

    @Test("History is kept per item, not per query, as for apps")
    func historyIsPerItem() {
        let url = Self.temporaryUsageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = Self.usageStore(at: url)

        usage.record(screenshotApp)
        #expect(rows("screenshot", usage: usage).first == .result(screenshotApp))
        #expect(rows("screen", usage: usage).first == .result(screenshotApp), "Learned from any query, it lifts the app everywhere")
        #expect(usage.record(for: screenshots) == nil)
        #expect(usage.record(for: screenshotApp.url)?.launchCount == 1)
    }

    @Test("A keyword with no app of that name still lists the command first, before files")
    func keywordWithoutAnApp() {
        #expect(
            QuickSearchRanking.items(matching: "dictate", applications: [], files: [file])
                == [.command(dictation), .result(file)]
        )
        #expect(rows("hotkeys") == [.command(coach)])
    }

    @Test("A partial word lists the command after the apps and before files")
    func partialQueryFollowsApps() {
        #expect(
            QuickSearchRanking.items(matching: "dict", applications: [dictionaryApp], files: [file])
                == [.result(dictionaryApp), .command(dictation), .result(file)]
        )
    }

    @Test("\"settings\" still puts Keybumps Settings first, and no capability command")
    func settingsStaysFirst() {
        #expect(rows("settings") == [.command(.keybumpsSettings), .result(systemSettings)])
    }

    @Test("A name match comes before keyword matches, which keep registry order")
    func ties() {
        #expect(
            QuickSearchRanking.items(matching: "history", applications: [], files: [file])
                == [.command(clipboard), .command(dictation), .command(coach), .result(file)]
        )
        let historyApp = app("/Applications/History Book.app")
        #expect(
            QuickSearchRanking.items(matching: "history", applications: [historyApp], files: [])
                == [.command(clipboard), .result(historyApp), .command(dictation), .command(coach)]
        )
    }

    // MARK: Destinations

    @Test("While on, a command shows its capability's tab; Window Manager, which has none, opens its Settings page")
    func destinationsWhileOn() {
        #expect(clipboard.destination(enabledCapabilities: allCapabilities) == .paletteTab(.clipboard))
        #expect(screenshots.destination(enabledCapabilities: allCapabilities) == .paletteTab(.screenshots))
        #expect(dictation.destination(enabledCapabilities: allCapabilities) == .paletteTab(.dictation))
        #expect(coach.destination(enabledCapabilities: allCapabilities) == .paletteTab(.keyboardShortcutter))
        #expect(windows.destination(enabledCapabilities: allCapabilities) == .settings(.windows))
        #expect(QuickSearchCommand.keybumpsSettings.destination(enabledCapabilities: allCapabilities) == .settings(nil))
    }

    @Test("While off, a command opens its capability's Settings page, where it can be turned on")
    func destinationsWhileOff() {
        for command in QuickSearchCommand.allCases {
            guard case .capability(let capability) = command else { continue }
            let off = allCapabilities.subtracting([capability])
            #expect(command.destination(enabledCapabilities: off) == .settings(capability.descriptor.settingsPage?.section))
            #expect(command.isTurnedOff(enabledCapabilities: off))
            #expect(!command.isTurnedOff(enabledCapabilities: allCapabilities))
        }
        #expect(!QuickSearchCommand.keybumpsSettings.isTurnedOff(enabledCapabilities: []))
    }

    /// By design, listing never looks at which capabilities are on: `QuickSearchModel` has no
    /// preferences, and the palette shows its items unfiltered, so a turned-off capability's command
    /// is always listed. Only its row and Return change, computed from the enabled set where the
    /// row is built (`turnedOffRows`).
    @Test("Every command is listed for its name through the real model; listing ignores on and off by design")
    func listedForItsName() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityCommandListing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        for command in QuickSearchCommand.allCases {
            search.query = command.title
            #expect(search.items == [.command(command)], "\(command.id)")
        }
    }

    /// What `SearchResultsView` computes for each command row from the palette's enabled set.
    @Test("A row says Turned off, shows no keycaps, and opens Settings exactly while its capability is off")
    func turnedOffRows() {
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: true, selected: .search)
        let states = [allCapabilities, []] + Capability.allCases.map { allCapabilities.subtracting([$0]) }
        for enabled in states {
            for command in QuickSearchCommand.allCases {
                guard case .capability(let capability) = command else { continue }
                let isOn = enabled.contains(capability)
                let tab = isOn ? capability.descriptor.paletteTab?.tab : nil
                let state = "\(command.id) with \(enabled.map(\.rawValue).sorted())"
                #expect(command.isTurnedOff(enabledCapabilities: enabled) == !isOn, "\(state)")
                #expect(
                    command.destination(enabledCapabilities: enabled)
                        == (tab.map { .paletteTab($0) } ?? .settings(capability.descriptor.settingsPage?.section)),
                    "\(state)"
                )
                #expect(command.rowShortcut(enabledCapabilities: enabled, visibleTabs: tabs) == tab?.shortcutLabel, "\(state)")
            }
        }
    }

    @Test("Rows show the tab's Command-number only when Return goes to a tab in the tab bar")
    func rowShortcuts() {
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search)
        let tabsWithHotkeys = CommandPaletteTab.visibleTabs(showsHotkeys: true, selected: .search)
        #expect(clipboard.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘2")
        #expect(screenshots.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘3")
        #expect(dictation.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘4")
        #expect(snippets.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘5")
        #expect(timer.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘6")
        #expect(coach.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == nil, "The Hotkeys tab is hidden, so ⌘7 does nothing")
        #expect(coach.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabsWithHotkeys) == "⌘7")
        #expect(windows.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == nil)
        #expect(dictation.rowShortcut(enabledCapabilities: [], visibleTabs: tabs) == nil, "Off, it opens Settings instead")
    }

    @Test("Tooltips and VoiceOver hints say where Return goes")
    func hints() {
        #expect(QuickSearchCommand.Destination.paletteTab(.clipboard).hint == "Shows the Clipboard tab")
        #expect(QuickSearchCommand.Destination.paletteTab(.keyboardShortcutter).hint == "Shows the Hotkeys tab")
        #expect(QuickSearchCommand.Destination.settings(.windows).hint == "Opens Window Manager in Settings")
        #expect(QuickSearchCommand.Destination.settings(nil).hint == "Opens Settings")
    }

    // MARK: Running from the palette

    /// Like `QuickSearchCommandTests.runOpensSettings`, this never shows the palette.
    @Test("Running a command shows the tab in place, or closes the palette for the Settings page")
    func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityCommand-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.clipboardHistory, .windowManagement], missing: nil, root: root)
        let palette = harness.model.commandPalette
        var opened: [SettingsSection?] = []
        palette.openSettings = { opened.append($0) }

        palette.run(clipboard)
        #expect(palette.selectedTab == .clipboard)
        #expect(opened.isEmpty)

        palette.run(dictation)
        #expect(opened == [.dictation], "Dictation is off")
        palette.run(windows)
        #expect(opened == [.dictation, .windows])
        #expect(palette.selectedTab == .clipboard)
    }

    /// The harness's own palette, with the Quick Search model the test hands it.
    @Test("Picking any command from the results, on or off, learns its own usage but adds no Recent Item")
    func commandsStayOutOfRecentItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityCommandRecents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let recentItems = search.recentItems
        let usage = search.applicationUsage
        let usageURL = root.appendingPathComponent("application-usage.json")
        let harness = WiringHarness(enabled: allCapabilities, missing: nil, root: root, quickSearch: search)
        let model = harness.model
        let palette = model.commandPalette
        palette.openSettings = { _ in }
        palette.openURL = { _ in true }

        for enabled in [allCapabilities, []] {
            model.preferences.enabledCapabilities = enabled
            for command in QuickSearchCommand.allCases {
                search.query = command.title
                #expect(search.items.first == .command(command))
                palette.choose(command)
            }
        }
        #expect(recentItems.items.isEmpty)
        for command in QuickSearchCommand.allCases {
            #expect(usage.record(for: command)?.launchCount == 2, "\(command.id)")
            #expect(ApplicationUsageStore(storageURL: usageURL).record(for: command)?.launchCount == 2, "Kept locally")
        }
        #expect(usage.record(for: dictionaryApp.url) == nil, "No app usage was learned")

        // The footer's Settings button and Command-comma run Keybumps Settings without teaching the ranking.
        palette.run(.keybumpsSettings)
        #expect(usage.record(for: .keybumpsSettings)?.launchCount == 2)

        // The same stores do record an opened app, so the checks above can fail.
        search.recordOpenResult(dictionaryApp, succeeded: true)
        #expect(recentItems.items.map(\.result) == [dictionaryApp])
        #expect(usage.record(for: dictionaryApp.url)?.launchCount == 1)
    }

    @Test("Quick Search ranks with what the palette learns: picking a command lifts it back above the app")
    func paletteLearnsFromPicks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityCommandLearning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let search = QuickSearchModel.forTests(in: root, applications: [screenshotApp], now: { now })
        let harness = WiringHarness(enabled: allCapabilities, missing: nil, root: root, quickSearch: search)
        let palette = harness.model.commandPalette
        palette.openSettings = { _ in }
        func firstRow() -> QuickSearchItem? {
            search.query = "screenshot"
            return search.items.first
        }

        #expect(firstRow() == .command(screenshots))
        search.recordOpenResult(screenshotApp, succeeded: true)
        #expect(firstRow() == .result(screenshotApp))
        palette.choose(screenshots)
        #expect(firstRow() == .command(screenshots))
        #expect(search.recentItems.items.map(\.result) == [screenshotApp], "Only the app became a Recent Item")
    }

    // MARK: Settings route

    @Test("A requested Settings page is handed over once, and only a page request notifies an open window")
    func requestedSettingsPage() {
        var opens = 0
        let router = MainWindowRouter(activate: {}, openWithoutWindow: { _ in })
        router.configure { opens += 1 }
        let notifications = NotificationCount()
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsSectionRequested,
            object: router,
            queue: nil
        ) { _ in notifications.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(router.open(.windows))
        #expect(opens == 1)
        #expect(notifications.value == 1)
        #expect(router.consumeRequestedSection() == .windows)
        #expect(router.consumeRequestedSection() == nil)

        router.open(.dictation)
        router.open(nil)
        #expect(opens == 3)
        #expect(notifications.value == 2)
        #expect(router.consumeRequestedSection() == nil, "Opening Settings plainly drops an unshown request")
    }
}

private func app(_ path: String) -> QuickSearchResult {
    QuickSearchResult(url: URL(fileURLWithPath: path), kind: .application)
}

/// Counts notifications delivered synchronously on the posting thread.
private final class NotificationCount: @unchecked Sendable {
    var value = 0
}
