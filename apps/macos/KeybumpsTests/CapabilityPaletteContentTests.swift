import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// A capability module can supply its own palette tab's rows (`CapabilityPaletteContent`), so the
/// palette needs no case for the tab. These tests drive the palette's keys against fake rows.
@MainActor
@Suite("Capability modules: palette tab rows")
struct CapabilityPaletteContentTests {
    static func key(_ keyCode: Int, _ characters: String = "", command: Bool = false) -> NSEvent {
        key(keyCode, characters, modifiers: command ? [.command] : [])
    }

    /// Arrow keys carry the function and numeric-pad flags, as real ones do.
    static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let isArrow = [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].contains(keyCode)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: isArrow ? modifiers.union([.function, .numericPad]) : modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    static let returnKey = key(kVK_Return, "\r")
    static let commandReturn = key(kVK_Return, "\r", command: true)
    static let deleteKey = key(kVK_Delete, "\u{7f}")
    static let downKey = key(kVK_DownArrow)
    static let upKey = key(kVK_UpArrow)

    @Test("Showing a module tab tells its rows, and the arrow keys move through them")
    func showAndMove() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }

        fixture.palette.selectOnOpening(.keyboardShortcutter)
        #expect(fixture.content.shows == 1)
        #expect(fixture.palette.state.selection == 0)

        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.selection == 2)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.selection == 0, "Wraps to the first row")
        #expect(fixture.palette.handleKeyDown(Self.upKey) == nil)
        #expect(fixture.palette.state.selection == 2, "Wraps to the last row")
    }

    @Test("Return and ⌘Return go to the module tab's rows")
    func returnGoesToTheContent() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        fixture.palette.state.selection = 1
        fixture.palette.state.historyQuery = "5m"
        fixture.palette.state.selection = 1

        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandReturn) == nil)
        #expect(fixture.content.activations == [
            .init(row: 1, query: "5m", withCommand: false),
            .init(row: 1, query: "5m", withCommand: true)
        ])
    }

    @Test("Down goes into a grid, which then gets all four arrow keys; a list's, or a grid's once you type, leave Left and Right to the search field")
    func gridGetsArrowKeys() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        fixture.palette.state.historyQuery = "made-up"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil, "A list leaves Right to the caret")
        fixture.palette.state.historyQuery = ""

        fixture.content.isGrid = true
        fixture.content.rows = 6
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.state.selection == 0, "Down goes into the grid at its first item")
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.selection == 4, "Down moves a row of 3")
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.selection == 4, "Down at the last row stays put")
        #expect(fixture.content.moves == [.right, .down, .down])

        // With Command (or Shift, Option, Control), arrows stay with the search field.
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow, command: true)) != nil)
        // A selection left past the end comes back to the first item.
        fixture.palette.state.selection = 99
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.selection == 0)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .keyboardShortcutter, "Inside the grid, Left at the first item stays put")

        // Typing turns the grid into a list: Right goes back to the search field's caret.
        fixture.palette.state.historyQuery = "made-up"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil)
    }

    @Test("With the search field empty, Left and Right switch to the tab beside this one, stopping at the ends")
    func arrowsSwitchTabs() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.search)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .search, "Left at the first tab stays put")
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.tab == .clipboard)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .search)

        // With Shift, Option, Command, or Control, or text to edit, they stay with the search field.
        for modifier: NSEvent.ModifierFlags in [.shift, .option, .command, .control] {
            #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow, modifiers: modifier)) != nil)
        }
        fixture.search.query = "made-up"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil)
        #expect(fixture.palette.state.tab == .search)
    }

    @Test("Until Down goes into a grid, Left and Right switch tabs and Delete removes nothing; Up from the top row comes back out")
    func gridTabLevel() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.content.isGrid = true
        fixture.content.rows = 6
        fixture.palette.tabContents[.clipboard] = fixture.content
        fixture.palette.selectOnOpening(.clipboard)

        #expect(!fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.handleKeyDown(Self.deleteKey) != nil, "Nothing is highlighted to delete")
        #expect(fixture.content.deletions.isEmpty)
        #expect(fixture.palette.handleKeyDown(Self.upKey) == nil)
        #expect(fixture.palette.state.tab == .clipboard)

        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.upKey) == nil)
        #expect(!fixture.palette.state.isBrowsingGrid, "Up from the top row leaves the grid")
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.tab == .screenshots)

        // Typing leaves the grid too.
        fixture.palette.selectOnOpening(.clipboard)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        fixture.palette.state.historyQuery = "x"
        #expect(!fixture.palette.state.isBrowsingGrid)

        // An empty grid has nothing to go into.
        fixture.content.rows = 0
        fixture.palette.selectOnOpening(.clipboard)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(!fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .search)
    }

    @Test("Screenshots: Left and Right switch tabs until Down goes into the grid, then move between screenshots")
    func screenshotsGridNeedsDown() throws {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        for name in ["First.png", "Second.png"] {
            let url = fixture.folder.url.appendingPathComponent(name)
            try ModuleTabFixture.png(seed: name).write(to: url)
            #expect(fixture.clipboard.ingestImageFile(at: url))
        }
        fixture.palette.selectOnOpening(.screenshots)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.tab == .dictation, "Right from the tab goes on to the next one")
        fixture.palette.selectOnOpening(.screenshots)
        #expect(fixture.palette.handleKeyDown(Self.deleteKey) != nil, "Nothing is highlighted to delete")
        #expect(fixture.clipboard.entries.count == 2)

        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.tab == .screenshots, "Inside the grid, Right at the last screenshot stays put")
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.upKey) == nil)
        #expect(!fixture.palette.state.isBrowsingGrid, "Up from the top row leaves the grid")
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .clipboard)
    }

    @Test("An empty Screenshots grid passes Left and Right on to the tabs beside it")
    func emptyScreenshotsSwitchesTabs() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.screenshots)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(fixture.palette.state.tab == .dictation)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .screenshots)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) == nil)
        #expect(fixture.palette.state.tab == .clipboard)
    }

    @Test("A tab's rows can copy through the palette, kept out of Clipboard History")
    func rowsCopyThroughThePalette() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.content.copiesOnActivate = "made-up text"
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
    }

    @Test("Delete goes to the rows, and the selection stays on a row that still exists")
    func deleteGoesToTheContent() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        fixture.palette.state.selection = 2

        #expect(fixture.palette.handleKeyDown(Self.deleteKey) == nil)
        #expect(fixture.content.deletions == [2])
        #expect(fixture.palette.state.selection == 1)

        fixture.content.refusesDelete = true
        #expect(fixture.palette.handleKeyDown(Self.deleteKey) != nil, "Rows that remove nothing pass Delete on")
    }

    @Test("While the search field has text, Delete edits it unless Command is held")
    func deleteWhileTyping() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        fixture.palette.state.historyQuery = "tea"

        #expect(fixture.palette.handleKeyDown(Self.deleteKey) != nil)
        #expect(fixture.content.deletions.isEmpty)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Delete, "\u{7f}", command: true)) == nil)
        #expect(fixture.content.deletions == [0])
    }

    @Test("A tab's rows can clear the search field")
    func clearQuery() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        fixture.palette.state.historyQuery = "tea 5m"
        fixture.content.clearsQueryOnActivate = true

        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.palette.state.historyQuery.isEmpty)
    }

    @Test("Typing goes back to the first row only for rows that ask")
    func typingResetsSelectionWhenAsked() {
        let resetting = ModuleTabFixture(resetsSelectionWhileTyping: true)
        defer { resetting.tearDown() }
        resetting.palette.selectOnOpening(.keyboardShortcutter)
        resetting.palette.state.selection = 2
        resetting.palette.state.historyQuery = "t"
        #expect(resetting.palette.state.selection == 0)

        let filtering = ModuleTabFixture(resetsSelectionWhileTyping: false)
        defer { filtering.tearDown() }
        filtering.palette.selectOnOpening(.keyboardShortcutter)
        filtering.palette.state.selection = 2
        filtering.palette.state.historyQuery = "t"
        #expect(filtering.palette.state.selection == 2)
    }

    @Test("The footer names a module tab's actions, else Quick Search's row's, else the tab's own")
    func footerActions() {
        let content = PaletteFooterActions(primary: "Pause", secondary: nil)
        #expect(PaletteFooterActions.resolve(tab: .keyboardShortcutter, searchItem: nil, content: content) == content)
        #expect(
            PaletteFooterActions.resolve(tab: .snippets, searchItem: nil, content: nil)
                == PaletteFooterActions(primary: "Copy", secondary: "Paste")
        )
        #expect(PaletteFooterActions(tab: .keyboardShortcutter) == PaletteFooterActions(primary: nil, secondary: nil))
    }

    @Test("The Hotkeys rows are Shortcut Coach's history, filtered, and none while it's off")
    func hotkeysRows() throws {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let inbox = InboxStore(persistence: MemoryCoachingPersistence())
        try inbox.append(CoachingEvent(applicationName: "Finder", actionTitle: "Open New Window", shortcut: "⌘N"))
        try inbox.append(CoachingEvent(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T"))
        let content = KeyboardShortcutterPaletteContent(inbox: inbox, preferences: preferences)

        preferences.setCapability(.keyboardShortcutter, enabled: true)
        #expect(content.rowCount(query: "") == 2)
        #expect(content.rowCount(query: "safari") == 1)
        #expect(content.delete(row: 0, query: "") == false, "The history is read-only")
        #expect(inbox.events.count == 2)

        preferences.setCapability(.keyboardShortcutter, enabled: false)
        #expect(content.rowCount(query: "") == 0)
    }

    // MARK: ⇧1–9 quick select (#182)

    static func shiftNumber(_ number: Int, extra: NSEvent.ModifierFlags = []) -> NSEvent {
        let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let symbols = Array("!@#$%^&*(")
        return key(keyCodes[number - 1], String(symbols[number - 1]), modifiers: NSEvent.ModifierFlags.shift.union(extra))
    }

    @Test("⇧N highlights the Nth row on screen and does what Return does, instead of typing a symbol")
    func shiftNumberActivatesTheRow() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)

        #expect(fixture.palette.handleKeyDown(Self.shiftNumber(2)) == nil, "⇧2 doesn't type @")
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.content.activations == [.init(row: 1, query: "", withCommand: false)])

        #expect(fixture.palette.handleKeyDown(Self.shiftNumber(9)) == nil)
        #expect(fixture.content.activations.count == 1, "There's no ninth row")
        #expect(fixture.palette.handleKeyDown(Self.shiftNumber(1, extra: .command)) != nil, "⇧⌘1 isn't quick select")
    }

    @Test("Numbers follow the rows on screen: after scrolling, ⇧1 is the top one showing")
    func shiftNumberFollowsTheRowsOnScreen() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.content.rows = 30
        fixture.palette.selectOnOpening(.keyboardShortcutter)
        let quickSelect = fixture.palette.state.quickSelect
        let views = (0..<30).map { _ in UUID() }
        quickSelect.setViewport(CGRect(x: 0, y: 0, width: 800, height: 1000), of: UUID())
        func onScreen(_ slot: Int) -> CGRect { CGRect(x: 0, y: CGFloat(slot) * 40, width: 800, height: 40) }
        for row in 12...20 { quickSelect.report(views[row], row: row, frame: onScreen(row - 12)) }

        _ = fixture.palette.handleKeyDown(Self.shiftNumber(1))
        #expect(fixture.content.activations.last?.row == 12)
        _ = fixture.palette.handleKeyDown(Self.shiftNumber(9))
        #expect(fixture.content.activations.last?.row == 20)

        // Scrolled to the end, with only four rows showing.
        for row in 12...20 { quickSelect.report(views[row], row: row, frame: nil) }
        for row in 26...29 { quickSelect.report(views[row], row: row, frame: onScreen(row - 26)) }
        _ = fixture.palette.handleKeyDown(Self.shiftNumber(5))
        #expect(fixture.content.activations.last?.row == 20, "⇧5 picks nothing when only four rows show")
        _ = fixture.palette.handleKeyDown(Self.shiftNumber(4))
        #expect(fixture.content.activations.last?.row == 29)
    }

    @Test("A grid with tiles too small to number, such as Emoji's, takes ⇧-numbers without acting")
    func shiftNumberSkipsTheEmojiGrid() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.content.isGrid = true
        fixture.palette.selectOnOpening(.keyboardShortcutter)

        #expect(fixture.palette.handleKeyDown(Self.shiftNumber(1)) == nil)
        #expect(fixture.content.activations.isEmpty)

        fixture.palette.state.historyQuery = "smile"
        _ = fixture.palette.handleKeyDown(Self.shiftNumber(1))
        #expect(fixture.content.activations == [.init(row: 0, query: "smile", withCommand: false)], "Search results are a list")
    }

    @Test("Caps Lock doesn't stop the palette's Command keys")
    func capsLockKeepsCommandKeys() {
        let fixture = ModuleTabFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.keyboardShortcutter)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_2, "2", modifiers: [.command, .capsLock])) == nil)
        #expect(fixture.palette.state.tab == .clipboard)
        #expect(fixture.palette.handleKeyDown(Self.shiftNumber(1, extra: .capsLock)) == nil, "Nor ⇧-numbers")
    }
}

/// A palette over temporary folders and a named pasteboard, with fake rows on the Hotkeys tab.
@MainActor
private final class ModuleTabFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsModuleTab-\(UUID().uuidString)"))
    let content: RecordingPaletteContent
    let search: QuickSearchModel
    let clipboard: ClipboardHistoryService
    let palette: CommandPaletteController

    init(resetsSelectionWhileTyping: Bool = false) {
        let root = folder.url
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        let dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
        search = QuickSearchModel.forTests(in: root)
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US",
                history: dictationHistory,
                paster: InertTextPaster(),
                allowsSystemAccess: false
            ),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: SilentNotices(),
            search: search
        )
        content = RecordingPaletteContent(resetsSelectionWhileTyping: resetsSelectionWhileTyping)
        palette.tabContents = [.keyboardShortcutter: content]
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }

    /// A 1×1 PNG with `seed` appended, so each file is a different image.
    static func png(seed: String) -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!
            + Data(seed.utf8)
    }
}

/// Three fake rows that record what the palette asks of them.
@MainActor
private final class RecordingPaletteContent: CapabilityPaletteContent {
    struct Activation: Equatable {
        let row: Int
        let query: String
        let withCommand: Bool
    }

    let tab = CommandPaletteTab.keyboardShortcutter
    let resetsSelectionWhileTyping: Bool
    var rows = 3
    var refusesDelete = false
    var clearsQueryOnActivate = false
    var isGrid = false
    var copiesOnActivate: String?
    private(set) var moves: [PaletteMove] = []
    private(set) var shows = 0
    private(set) var activations: [Activation] = []
    private(set) var deletions: [Int] = []

    init(resetsSelectionWhileTyping: Bool) {
        self.resetsSelectionWhileTyping = resetsSelectionWhileTyping
    }

    func rowCount(query: String) -> Int { rows }

    /// A grid only while the search is empty, as emoji to browse.
    func isGrid(query: String) -> Bool { isGrid && query.isEmpty }

    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? {
        moves.append(move)
        return PaletteGrid.selection(after: move, from: row, sectionCounts: [rows], columns: 3)
    }

    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {
        activations.append(Activation(row: row, query: query, withCommand: withCommand))
        if clearsQueryOnActivate { palette.clearQuery() }
        if let copiesOnActivate { palette.copy(copiesOnActivate) }
    }

    func delete(row: Int, query: String) -> Bool {
        guard !refusesDelete else { return false }
        deletions.append(row)
        rows -= 1
        return true
    }

    func didShow(palette: PaletteContentActions) { shows += 1 }

    func makeView(_ context: PaletteContentContext) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
private final class SilentNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}

private final class MemoryCoachingPersistence: EventPersistence {
    private var events: [CoachingEvent] = []
    func load() throws -> [CoachingEvent] { events }
    func save(_ events: [CoachingEvent]) throws { self.events = events }
}
