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
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
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
}

/// A palette over temporary folders and a named pasteboard, with fake rows on the Hotkeys tab.
@MainActor
private final class ModuleTabFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsModuleTab-\(UUID().uuidString)"))
    let content: RecordingPaletteContent
    let palette: CommandPaletteController

    init(resetsSelectionWhileTyping: Bool = false) {
        let root = folder.url
        let clipboard = ClipboardHistoryService(
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
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: SilentNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
        content = RecordingPaletteContent(resetsSelectionWhileTyping: resetsSelectionWhileTyping)
        palette.tabContents = [.keyboardShortcutter: content]
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
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
    private(set) var shows = 0
    private(set) var activations: [Activation] = []
    private(set) var deletions: [Int] = []

    init(resetsSelectionWhileTyping: Bool) {
        self.resetsSelectionWhileTyping = resetsSelectionWhileTyping
    }

    func rowCount(query: String) -> Int { rows }

    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {
        activations.append(Activation(row: row, query: query, withCommand: withCommand))
        if clearsQueryOnActivate { palette.clearQuery() }
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
