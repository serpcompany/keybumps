import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The ScreenGrabs tab's rows, which its module supplies (`ScreengrabsPaletteContent`, #494), do
/// what the palette did when it drew them itself. `PaletteCopyPasteKeyTests`, `PaletteFilterTests`,
/// and `CapabilityPaletteContentTests` keep their ScreenGrabs cases from before the move.
@MainActor
@Suite("ScreenGrabs tab rows")
struct ScreengrabsPaletteContentTests {
    // MARK: Rows

    @Test("Lists only screenshots, narrowed by the search and the palette's filter")
    func rows() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First", "Second"])
        fixture.clipboard.ingestForTesting("Made-up copied text")

        #expect(fixture.rowCount() == 2)
        #expect(fixture.rowCount("First") == 1)
        #expect(fixture.rowCount("zzz") == 0)
        fixture.filter = .today
        #expect(fixture.rowCount() == 2)
        fixture.filter = .text
        #expect(fixture.rowCount() == 0)
    }

    @Test("Lists nothing while ScreenGrabs is off")
    func noRowsWhileOff() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First"])
        fixture.preferences.enabledCapabilities.remove(.screenshotTools)
        #expect(fixture.rowCount() == 0)
    }

    @Test("It's a grid, with or without a search")
    func alwaysAGrid() {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        #expect(fixture.content.isGrid(query: ""))
        #expect(fixture.content.isGrid(query: "made-up"))
    }

    @Test("Up and Down move a row of the grid's two columns (#552), Left and Right one screenshot, and each stays put at an edge")
    func gridMoves() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["1", "2", "3", "4", "5"])

        #expect(fixture.move(.down, from: 1) == 3)
        #expect(fixture.move(.down, from: 2) == 4, "Into the shorter last row")
        #expect(fixture.move(.down, from: 3) == nil, "Nothing below in the shorter last row")
        #expect(fixture.move(.up, from: 4) == 2)
        #expect(fixture.move(.up, from: 3) == 1)
        #expect(fixture.move(.up, from: 1) == nil, "The top row: the palette leaves the grid")
        #expect(fixture.move(.right, from: 2) == 3)
        #expect(fixture.move(.right, from: 1) == 2, "From the end of a row to the start of the next")
        #expect(fixture.move(.right, from: 4) == nil)
        #expect(fixture.move(.left, from: 3) == 2)
        #expect(fixture.move(.left, from: 2) == 1, "From the start of a row to the end of the one above")
        #expect(fixture.move(.left, from: 0) == nil)
    }

    // MARK: Keys

    @Test("Return and ⌘C copy, ⌘V pastes, and ⌘Return and ⌘E edit the selected screenshot")
    func keys() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        let ids = try fixture.addScreenshots(["First", "Second"])
        let log = fixture.log
        let content: ScreengrabsPaletteContent = fixture.content

        content.activate(row: 0, query: "", palette: log.actions)
        content.copy(row: 1, query: "", palette: log.actions)
        content.paste(row: 0, query: "", palette: log.actions)
        content.commandActivate(row: 1, query: "", palette: log.actions)
        content.handleCommandKey("e", row: 0, query: "", palette: log.actions)
        #expect(log.calls == [.copy(ids[0]), .copy(ids[1]), .paste(ids[0]), .edit(ids[1]), .edit(ids[0])])
        #expect(content.commandKeys == ["e"])
        #expect(content.pastes(row: 0, query: ""), "⌘V pastes a screenshot")
        #expect(!content.pastes(row: 2, query: ""), "No row, so ⌘V is the search field's")
    }

    @Test("Keys on a row that isn't there do nothing")
    func keysOutOfRange() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First"])
        let log = fixture.log

        fixture.content.activate(row: 1, query: "", palette: log.actions)
        fixture.content.commandActivate(row: 1, query: "", palette: log.actions)
        fixture.content.handleCommandKey("e", row: 1, query: "", palette: log.actions)
        #expect(log.calls.isEmpty)
        #expect(!fixture.content.delete(row: 1, query: ""))
    }

    @Test("A click highlights a screenshot, a double-click copies it, as Return does, and a ⌘-click edits it, once (#552)")
    func click() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        let ids = try fixture.addScreenshots(["First", "Second"])
        let log = fixture.log
        let content: ScreengrabsPaletteContent = fixture.content
        #expect(content.tab.clickAction == .selects)
        #expect(content.commandClicks)

        content.click(.click(), row: 1, query: "", palette: log.actions)
        #expect(log.calls == [.select(1)], "One click only highlights it")
        content.click(.click(count: 2), row: 1, query: "", palette: log.actions)
        content.click(.doubleClick(), row: 1, query: "", palette: log.actions)
        #expect(log.calls == [.select(1), .select(1), .copy(ids[1])], "The double-click copies it")

        content.click(.click(withCommand: true), row: 0, query: "", palette: log.actions)
        content.click(.click(count: 2, withCommand: true), row: 0, query: "", palette: log.actions)
        content.click(.doubleClick(withCommand: true), row: 0, query: "", palette: log.actions)
        #expect(log.calls.suffix(2) == [.select(0), .edit(ids[0])], "A ⌘-click edits, and a ⌘-double-click doesn't copy too")
        #expect(log.calls.count == 5)

        // Choosing it, as Return and ⌘Return do.
        let entry = try #require(fixture.clipboard.entries.first { $0.id == ids[0] })
        ScreengrabsPaletteContent.choose(entry, withCommand: false, palette: log.actions)
        ScreengrabsPaletteContent.choose(entry, withCommand: true, palette: log.actions)
        #expect(log.calls.suffix(2) == [.copy(ids[0]), .edit(ids[0])])
    }

    @Test("Space opens Quick Look (#494), and the footer names Copy ↵, Paste ⌘V, Edit ⌘E, Quick Look, then Delete ⌫ (#552)")
    func spaceAndFooter() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First"])

        let playback = try #require(fixture.content.playback(row: 0, query: ""))
        #expect(playback.title == "Quick Look")
        let footer = fixture.content.footerActions(row: 0, query: "")
        #expect(footer.primary == "Copy")
        #expect(footer.secondary.map(\.description) == ["Paste ⌘V", "Edit ⌘E", "Delete ⌫"])
        let resolved = PaletteFooterActions.resolve(tab: .screenshots, searchItem: nil, content: footer, playback: playback.title)
        #expect(resolved.secondary.map(\.description) == ["Paste ⌘V", "Edit ⌘E", "Quick Look Space", "Delete ⌫"], "Space's before Delete's")
    }

    @Test("Delete removes the screenshot from the tab and its file from ScreenGrabs' history, and leaves the file where macOS saved it (#605)")
    func delete() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First", "Second"])
        let inHistory = try #require(fixture.clipboard.entries.first?.sourceURL)
        let saved = fixture.folder.url.appendingPathComponent("Second.png")

        #expect(fixture.content.delete(row: 0, query: ""))
        #expect(fixture.rowCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: inHistory.path), "moved to the Trash")
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    // MARK: Through the palette

    @Test("⌘E edits the first screenshot before Down goes into the grid, and waits while / lists filters")
    func commandEThroughThePalette() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        let ids = try fixture.addScreenshots(["First", "Second"])
        var edited: [UUID] = []
        fixture.palette.editImage = { edited.append($0.id); return true }
        fixture.palette.selectOnOpening(.screenshots)

        fixture.palette.state.historyQuery = "/"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_E, "e", modifiers: .command)) != nil)
        #expect(edited.isEmpty)
        fixture.palette.state.historyQuery = ""
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_E, "e", modifiers: .command)) == nil)
        #expect(edited == [ids[0]])
    }

    @Test("A click on a tile goes into the grid, as Down does: the footer names its actions, and the arrow keys move on from it; the pointer passing over a tile first changes nothing; a double-click copies it (#552)")
    func clickThroughThePalette() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First", "Second", "Third"])
        let palette = fixture.palette
        var pointer = NSPoint(x: -1000, y: -1000)
        palette.state.mouseLocation = { pointer }
        palette.selectOnOpening(.screenshots)
        #expect(palette.footerActions.secondary.map(\.description) == ["Edit ⌘E"], "Nothing highlighted yet")

        palette.clickContentRow(.click(), row: 1)
        #expect(palette.state.isBrowsingGrid)
        #expect(palette.state.selection == 1)
        #expect(palette.footerActions.primary == "Copy")
        #expect(palette.footerActions.secondary.map(\.description) == ["Paste ⌘V", "Edit ⌘E", "Quick Look Space", "Delete ⌫"])
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.selection == 2)

        // Again, with the pointer passing over the first tile on its way, then a click. The pointer
        // only rings the tile: nothing's highlighted, and the footer still names no tile's actions.
        palette.selectOnOpening(.screenshots)
        pointer = NSPoint(x: 10, y: 20)
        palette.hover(row: 0)
        #expect(!palette.state.isBrowsingGrid)
        #expect(!palette.state.gridEnteredByPointer)
        #expect(palette.footerActions.secondary.map(\.description) == ["Edit ⌘E"])
        palette.clickContentRow(.click(), row: 0)
        #expect(palette.state.isBrowsingGrid)
        #expect(!palette.state.gridEnteredByPointer)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.tab == .screenshots, "Right moves on in the grid")
        #expect(palette.state.selection == 1)

        let before = fixture.pasteboard.changeCount
        palette.clickContentRow(.doubleClick(), row: 1)
        #expect(fixture.pasteboard.changeCount != before, "The double-click copies it")
    }

    @Test("With text in the search field, Left and Right move the caret, and Down still goes into the grid")
    func arrowsWithASearch() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["Made-up 1", "Made-up 2"])
        fixture.palette.selectOnOpening(.screenshots)
        fixture.palette.state.historyQuery = "Made"

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil)
        #expect(fixture.palette.state.tab == .screenshots)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_LeftArrow)) != nil)
        #expect(fixture.palette.state.selection == 0)
    }

    @Test("Down stays put above a shorter last row, and Shift-Down moves a row as Down does")
    func arrowsInTheGrid() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["1", "2", "3", "4", "5"])
        fixture.palette.selectOnOpening(.screenshots)
        let palette = fixture.palette

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        palette.state.selection = 3
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.selection == 3)
        palette.state.selection = 1
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow, modifiers: .shift)) == nil)
        #expect(palette.state.selection == 3)
        #expect(palette.handleKeyDown(Self.key(kVK_UpArrow, modifiers: .shift)) == nil)
        #expect(palette.state.selection == 1)
    }

    @Test("Up and Down always reach the grid, with a modifier too, and one at its edge counts as moving in it; any text in the search field, even spaces, keeps Left and Right")
    func arrowsTheGridOwns() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["1", "2", "3", "4", "5"])
        #expect(fixture.content.gridOwnsUpAndDown)
        let palette = fixture.palette
        var pointer = NSPoint(x: -1000, y: -1000)
        palette.state.mouseLocation = { pointer }
        palette.selectOnOpening(.screenshots)

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow, modifiers: .option)) == nil)
        #expect(palette.state.isBrowsingGrid, "Option-Down goes into the grid")
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow, modifiers: .control)) == nil)
        #expect(palette.state.selection == 2, "Control-Down moves a row")
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow, modifiers: .shift)) != nil)
        #expect(palette.state.selection == 2)

        palette.state.historyQuery = "  "
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil, "Spaces are text, so Right moves the caret")
        #expect(palette.state.tab == .screenshots)
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.isBrowsingGrid)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil)
        #expect(palette.state.selection == 0)

        // A click highlights a screenshot with none below it: Down has nowhere to go and stays put,
        // and Right moves on to the next screenshot. The pointer passing over another first changes
        // nothing (#552); a grid the pointer can go into is `CapabilityPaletteContentTests`'.
        palette.state.historyQuery = ""
        palette.selectOnOpening(.screenshots)
        pointer = NSPoint(x: 10, y: 20)
        palette.hover(row: 1)
        #expect(!palette.state.isBrowsingGrid)
        palette.clickContentRow(.click(), row: 3)
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.selection == 3)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.tab == .screenshots)
        #expect(palette.state.selection == 4)
    }

    @Test("While an input method composes, Up and Down still go into the grid and move a row, and Left and Right stay with the input method")
    func arrowsWhileComposing() async throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["1", "2", "3", "4", "5"])
        let palette = fixture.palette
        let panel = try #require(palette.layOutForTesting(.screenshots))
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(PaletteCopyPasteKeyTests.searchField(in: panel.contentView))
        #expect(panel.makeFirstResponder(field))
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.setMarkedText("きょう", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(palette.state.historyQuery.isEmpty, "The search waits for the input method to commit")

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.isBrowsingGrid, "Down goes into the grid")
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.selection == 2, "Down moves a row")
        #expect(palette.handleKeyDown(Self.key(kVK_UpArrow)) == nil)
        #expect(palette.state.selection == 0)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) != nil, "Right goes to the input method")
        #expect(palette.state.selection == 0)
        editor.unmarkText()
    }

    @Test("Delete on a highlighted screenshot removes it from the tab, leaves the file where macOS saved it, and keeps the highlight on one that's still there")
    func deleteThroughThePalette() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        let ids = try fixture.addScreenshots(["First", "Second"])
        let inHistory = try #require(fixture.clipboard.entries.first { $0.id == ids[1] }?.sourceURL)
        let file = fixture.folder.url.appendingPathComponent("First.png")
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(palette.state.selection == 1)
        #expect(palette.handleKeyDown(Self.key(kVK_Delete, "\u{7f}")) == nil)
        #expect(fixture.clipboard.entries.count == 1)
        #expect(fixture.clipboard.entries.map(\.id) == [ids[0]])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: inHistory.path), "its file in ScreenGrabs' history is moved to the Trash")
        #expect(palette.state.selection == 0)
    }

    static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let isArrow = [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].contains(keyCode)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union(isArrow ? [.function, .numericPad] : []),
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }
}

/// The tab's rows over a temporary folder and a named pasteboard, never the real ones, in a palette
/// that shows them, with the palette's filter set by the test.
@MainActor
private final class ScreengrabsTabFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreengrabsTab-\(UUID().uuidString)"))
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let log = ContentActionLog()
    let clipboard: ClipboardHistoryService
    let palette: CommandPaletteController
    private(set) var content: ScreengrabsPaletteContent!
    var filter: PaletteFilter?

    init() {
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
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US",
                history: dictationHistory,
                paster: InertTextPaster(),
                allowsSystemAccess: false
            ),
            preferences: preferences,
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: SilentScreengrabsNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
        content = ScreengrabsPaletteContent(clipboard: clipboard, preferences: preferences) { [weak self] in self?.filter }
        palette.tabContents = [.screenshots: content]
    }

    func rowCount(_ query: String = "") -> Int {
        content.rowCount(query: query)
    }

    func move(_ move: PaletteMove, from row: Int) -> Int? {
        content.selection(after: move, from: row, query: "")
    }

    /// Adds made-up screenshots, as the screenshot folder's watcher does, oldest first. Returns their
    /// IDs as the tab lists them, newest first.
    @discardableResult
    func addScreenshots(_ names: [String]) throws -> [UUID] {
        for name in names {
            let url = folder.url.appendingPathComponent("\(name).png")
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!
            try (png + Data(name.utf8)).write(to: url)
            #expect(clipboard.ingestImageFile(at: url))
        }
        return clipboard.entries.filter(\.isScreenshot).map(\.id)
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// Records what the rows ask of the palette.
@MainActor
private final class ContentActionLog {
    enum Call: Equatable {
        case select(Int), copy(UUID), paste(UUID), edit(UUID)
    }

    private(set) var calls: [Call] = []

    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: {},
            selectRow: { [weak self] row in self?.calls.append(.select(row)) },
            clearQuery: {},
            copyClipboardEntry: { [weak self] entry in self?.calls.append(.copy(entry.id)) },
            pasteClipboardEntry: { [weak self] entry in self?.calls.append(.paste(entry.id)) },
            editClipboardImage: { [weak self] entry in self?.calls.append(.edit(entry.id)) }
        )
    }
}

private final class SilentScreengrabsNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
