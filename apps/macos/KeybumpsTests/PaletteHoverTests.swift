import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// Moving the pointer over a Command Palette row highlights it, as in Raycast (#347), but rows that
/// scroll or appear under a still pointer don't take the highlight from the keyboard.
@MainActor
@Suite("Command Palette: hover highlights a row")
struct PaletteHoverTests {
    static func key(_ keyCode: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    @Test("A hover counts only once the pointer has moved since the highlight last moved")
    func pointerMustMove() {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        for index in 1...10 { fixture.clipboard.ingestForTesting("made-up text \(index)") }
        fixture.palette.selectOnOpening(.clipboard)
        let state = fixture.palette.state

        fixture.palette.hover(row: 2)
        #expect(state.selection == 0, "The palette opened under a still pointer")

        fixture.pointer = NSPoint(x: 10, y: 20)
        fixture.palette.hover(row: 2)
        #expect(state.selection == 2)
        #expect(state.selectionFollowsPointer, "So the list doesn't scroll to it")

        _ = fixture.palette.handleKeyDown(Self.key(kVK_DownArrow))
        #expect(state.selection == 3)
        #expect(!state.selectionFollowsPointer)
        fixture.palette.hover(row: 5)
        #expect(state.selection == 3, "Rows scrolling under a still pointer leave the keyboard's highlight")

        fixture.pointer = NSPoint(x: 10, y: 60)
        fixture.palette.hover(row: 5)
        #expect(state.selection == 5)
    }

    @Test("Typing or a new tab moves the highlight without the pointer, so it has to move again")
    func keyboardChangesNeedAMove() {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        for index in 1...10 { fixture.clipboard.ingestForTesting("made-up text \(index)") }
        fixture.palette.selectOnOpening(.clipboard)
        fixture.pointer = NSPoint(x: 10, y: 20)
        fixture.palette.hover(row: 4)
        #expect(fixture.palette.state.selection == 4)

        fixture.palette.selectOnOpening(.dictation)
        fixture.palette.selectOnOpening(.clipboard)
        fixture.palette.hover(row: 6)
        #expect(fixture.palette.state.selection == 0, "The new tab's rows appeared under a still pointer")

        // Clipboard only filters as you type, so its selection stays put; any key still re-arms.
        fixture.pointer = NSPoint(x: 10, y: 90)
        let typed = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: UInt16(kVK_ANSI_M)
        )!
        #expect(fixture.palette.handleKeyDown(typed) != nil, "The letter goes to the search field")
        fixture.palette.state.historyQuery = "m"
        #expect(fixture.palette.state.selection == 0)
        fixture.palette.hover(row: 3)
        #expect(fixture.palette.state.selection == 0, "Rows that typing brought under a still pointer")

        // A click moves the highlight without the pointer flag, and re-arms too.
        fixture.pointer = NSPoint(x: 10, y: 120)
        fixture.palette.state.selection = 2
        fixture.palette.hover(row: 5)
        #expect(fixture.palette.state.selection == 2)
    }

    @Test("A row that appears under a pointer resting since it last moved doesn't take the highlight")
    func restingPointer() {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        for index in 1...10 { fixture.clipboard.ingestForTesting("made-up text \(index)") }
        fixture.palette.selectOnOpening(.clipboard)
        let state = fixture.palette.state

        // The pointer moves onto empty space under the rows, and rests there.
        fixture.pointer = NSPoint(x: 10, y: 400)
        state.notePointer()
        fixture.clock += 2
        fixture.palette.hover(row: 6)
        #expect(state.selection == 0, "A late row under a resting pointer")

        fixture.pointer = NSPoint(x: 10, y: 402)
        fixture.palette.hover(row: 6)
        #expect(state.selection == 6, "Moving again counts at once")
    }

    @Test("Deleting a recording asks first, from the Delete key too, so a hover can't retarget it unseen")
    func dictationDeleteAsks() throws {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        let audio = fixture.folder.url.appendingPathComponent("made-up.wav")
        try Data(count: 64).write(to: audio)
        let entry = try fixture.dictationHistory.record("made-up words", language: "en-US", duration: 1, audioSourceURL: audio)
        fixture.palette.selectOnOpening(.dictation)
        let delete = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: UInt16(kVK_Delete)
        )!

        #expect(fixture.palette.handleKeyDown(delete) == nil)
        #expect(fixture.palette.state.dictationPendingDeletion?.id == entry.id)
        #expect(fixture.dictationHistory.entries.count == 1, "Nothing is deleted until the alert's Delete")
        #expect(fixture.palette.handleKeyDown(delete) != nil, "While the alert shows, it has the keys")

        fixture.pointer = NSPoint(x: 10, y: 20)
        fixture.palette.hover(row: 0)
        #expect(!fixture.palette.state.selectionFollowsPointer, "The pointer behind the alert changes nothing")

        fixture.palette.deleteDictation(entry)
        #expect(fixture.dictationHistory.entries.isEmpty, "The alert's Delete deletes")
        #expect(fixture.palette.state.selection == 0)
    }

    @Test("Arrowing past the visible rows scrolls the real Clipboard list to the highlight (#352)")
    func clipboardScrollsToTheHighlight() throws {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        for index in 1...40 { fixture.clipboard.ingestForTesting("made-up text \(index)") }
        fixture.palette.show(.clipboard)
        defer { fixture.palette.dismiss() }
        let panel = try #require(NSApp.windows.first { $0.identifier?.rawValue == "commandPalette" })
        let content = try #require(panel.contentView)
        let list = try #require(Self.waitFor { Self.scrollViews(in: content).first { $0.documentView is NSTableView } })
        #expect(list.contentView.bounds.minY <= 0)

        for _ in 0..<30 { _ = fixture.palette.handleKeyDown(Self.key(kVK_DownArrow)) }

        #expect(fixture.palette.state.selection == 30)
        #expect(Self.waitFor { list.contentView.bounds.minY > 300 ? true : nil } == true, "The list scrolled down to row 30")
    }

    private static func waitFor<T>(_ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = value() { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    @Test("A row that's no longer in the list can't take the highlight")
    func staleRowIsIgnored() {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        for index in 1...3 { fixture.clipboard.ingestForTesting("made-up text \(index)") }
        fixture.palette.selectOnOpening(.clipboard)
        fixture.pointer = NSPoint(x: 10, y: 20)

        fixture.palette.hover(row: 3)
        #expect(fixture.palette.state.selection == 0)
        fixture.palette.hover(row: 2)
        #expect(fixture.palette.state.selection == 2)
    }


}

/// A palette over temporary folders and a named pasteboard, with a pointer the test moves.
@MainActor
private final class HoverFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsHover-\(UUID().uuidString)"))
    let clipboard: ClipboardHistoryService
    let dictationHistory: DictationHistoryService
    let palette: CommandPaletteController
    var pointer = NSPoint(x: -1000, y: -1000)
    var clock: TimeInterval = 100

    init() {
        let root = folder.url
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US", history: dictationHistory, paster: InertTextPaster(), allowsSystemAccess: false
            ),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: HoverNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
        // Weak: a shown palette's window outlives the fixture.
        palette.state.mouseLocation = { [weak self] in self?.pointer ?? .zero }
        palette.state.now = { [weak self] in self?.clock ?? 0 }
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

private final class HoverNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
