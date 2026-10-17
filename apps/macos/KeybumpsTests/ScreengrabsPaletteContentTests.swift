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

    @Test("Up and Down move a row, Left and Right one screenshot, and each stays put at an edge")
    func gridMoves() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["1", "2", "3", "4", "5"])

        #expect(fixture.move(.down, from: 1) == 4)
        #expect(fixture.move(.down, from: 2) == nil, "Nothing below in the shorter last row")
        #expect(fixture.move(.up, from: 4) == 1)
        #expect(fixture.move(.up, from: 2) == nil, "The top row: the palette leaves the grid")
        #expect(fixture.move(.right, from: 2) == 3)
        #expect(fixture.move(.right, from: 4) == nil)
        #expect(fixture.move(.left, from: 3) == 2)
        #expect(fixture.move(.left, from: 0) == nil)
    }

    // MARK: Keys

    @Test("Return and ⌘C copy, ⌘P pastes, and ⌘Return and ⌘E edit the selected screenshot")
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

    @Test("A click copies, and a ⌘-click edits")
    func click() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        let ids = try fixture.addScreenshots(["First"])
        let entry = try #require(fixture.clipboard.entries.first)
        let log = fixture.log

        ScreengrabsPaletteContent.choose(entry, withCommand: false, palette: log.actions)
        ScreengrabsPaletteContent.choose(entry, withCommand: true, palette: log.actions)
        #expect(log.calls == [.copy(ids[0]), .edit(ids[0])])
    }

    @Test("Space does nothing, and the footer names Copy ↵, Paste ⌘P, and Edit ⌘↵")
    func spaceAndFooter() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First"])

        #expect(fixture.content.playback(row: 0, query: "") == nil)
        let footer = fixture.content.footerActions(row: 0, query: "")
        #expect(footer.primary == "Copy")
        #expect(footer.secondary.map(\.description) == ["Paste ⌘P", "Edit ⌘↵"])
    }

    @Test("Delete removes the screenshot from the tab and leaves its file")
    func delete() throws {
        let fixture = ScreengrabsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshots(["First", "Second"])
        let file = try #require(fixture.clipboard.entries.first?.sourceURL)

        #expect(fixture.content.delete(row: 0, query: ""))
        #expect(fixture.rowCount() == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
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
        palette.state.selection = 2
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.state.selection == 2)
        palette.state.selection = 1
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow, modifiers: .shift)) == nil)
        #expect(palette.state.selection == 4)
        #expect(palette.handleKeyDown(Self.key(kVK_UpArrow, modifiers: .shift)) == nil)
        #expect(palette.state.selection == 1)
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
        case copy(UUID), paste(UUID), edit(UUID)
    }

    private(set) var calls: [Call] = []

    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: {},
            selectRow: { _ in },
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
