import Foundation
import Testing
@testable import Keybumps

/// Navigating by searching (#182): each capability's Quick Search command, the words that find it,
/// where it ranks, and where it goes while the capability is on or off.
@MainActor
@Suite("Capability commands")
struct CapabilityCommandTests {
    private let clipboard = QuickSearchCommand.capability(.clipboardHistory)
    private let screenshots = QuickSearchCommand.capability(.screenshotTools)
    private let dictation = QuickSearchCommand.capability(.dictation)
    private let windows = QuickSearchCommand.capability(.windowManagement)
    private let coach = QuickSearchCommand.capability(.keyboardShortcutter)
    private let allCapabilities = Set(Capability.allCases)

    // MARK: Names

    @Test("Keybumps Settings comes first, then one command per capability except Quick Search, in registry order")
    func commands() {
        #expect(QuickSearchCommand.allCases == [.keybumpsSettings, clipboard, screenshots, dictation, windows, coach])
    }

    @Test("Each command carries its capability's name, not its tab label, and the Command kind")
    func names() {
        #expect(QuickSearchCommand.allCases.map(\.title) == [
            "Keybumps Settings", "Clipboard History", "Screenshot Tools", "Dictation", "Window Manager", "Shortcut Coach",
        ])
        #expect(QuickSearchCommand.allCases.allSatisfy { $0.kindLabel == "Command" })
        #expect(QuickSearchCommand.allCases.map(\.id) == [
            "keybumpsSettings", "clipboardHistory", "screenshotTools", "dictation", "windowManagement", "keyboardShortcutter",
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
        "Its name, its tab's name, and what people call it match exactly",
        arguments: [
            ("clipboard", QuickSearchCommand.capability(.clipboardHistory)),
            ("Clipboard History", .capability(.clipboardHistory)),
            ("copy", .capability(.clipboardHistory)),
            ("paste", .capability(.clipboardHistory)),
            ("screenshots", .capability(.screenshotTools)),
            ("screenshot", .capability(.screenshotTools)),
            ("capture", .capability(.screenshotTools)),
            ("screenshot tools", .capability(.screenshotTools)),
            ("dictate", .capability(.dictation)),
            ("DICTATION", .capability(.dictation)),
            ("voice", .capability(.dictation)),
            ("transcribe", .capability(.dictation)),
            ("recordings", .capability(.dictation)),
            ("dictation history", .capability(.dictation)),
            ("window manager", .capability(.windowManagement)),
            ("windows", .capability(.windowManagement)),
            ("snap", .capability(.windowManagement)),
            ("hotkeys", .capability(.keyboardShortcutter)),
            ("shortcut coach", .capability(.keyboardShortcutter)),
            ("shortcuts", .capability(.keyboardShortcutter)),
        ]
    )
    func exactMatches(query: String, command: QuickSearchCommand) {
        #expect(command.match(query) == .exact)
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

    private let dictionaryApp = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Dictionary.app"), kind: .application)
    private let systemSettings = QuickSearchResult(
        url: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
        kind: .application
    )
    private let file = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/fixture/notes.txt"), kind: .file)

    @Test("A whole word puts the command first, above apps and files")
    func exactQueryRanksFirst() {
        #expect(
            QuickSearchRanking.items(matching: "dictate", applications: [], files: [file])
                == [.command(dictation), .result(file)]
        )
        #expect(
            QuickSearchRanking.items(matching: "clipboard", applications: [], files: [file])
                == [.command(clipboard), .result(file)]
        )
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
        #expect(
            QuickSearchRanking.items(matching: "settings", applications: [systemSettings], files: [])
                == [.command(.keybumpsSettings), .result(systemSettings)]
        )
    }

    @Test("Equally good matches keep registry order")
    func ties() {
        #expect(
            QuickSearchRanking.items(matching: "history", applications: [], files: [])
                == [.command(clipboard), .command(dictation), .command(coach)]
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

    @Test("While off, a command still appears and opens its capability's Settings page, where it can be turned on")
    func destinationsWhileOff() {
        for command in QuickSearchCommand.allCases {
            guard case .capability(let capability) = command else { continue }
            let off = allCapabilities.subtracting([capability])
            #expect(command.destination(enabledCapabilities: off) == .settings(capability.descriptor.settingsPage?.section))
            #expect(command.isTurnedOff(enabledCapabilities: off))
            #expect(!command.isTurnedOff(enabledCapabilities: allCapabilities))
        }
        #expect(!QuickSearchCommand.keybumpsSettings.isTurnedOff(enabledCapabilities: []))
        // Every capability command appears whether or not its capability is on.
        #expect(QuickSearchRanking.items(matching: "dictate", applications: [], files: []) == [.command(dictation)])
    }

    @Test("Rows show the tab's Command-number only when Return goes to a tab in the tab bar")
    func rowShortcuts() {
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search)
        let tabsWithHotkeys = CommandPaletteTab.visibleTabs(showsHotkeys: true, selected: .search)
        #expect(clipboard.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘2")
        #expect(screenshots.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘3")
        #expect(dictation.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == "⌘4")
        #expect(coach.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabs) == nil, "The Hotkeys tab is hidden, so ⌘5 does nothing")
        #expect(coach.rowShortcut(enabledCapabilities: allCapabilities, visibleTabs: tabsWithHotkeys) == "⌘5")
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

/// Counts notifications delivered synchronously on the posting thread.
private final class NotificationCount: @unchecked Sendable {
    var value = 0
}
