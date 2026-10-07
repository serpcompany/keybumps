import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// ⇧1–9 quick select in the Command Palette (#182): which keys it takes, which rows get numbers,
/// and what it does in the tabs the palette draws itself.
@MainActor
@Suite("Command Palette: ⇧1–9 quick select")
struct PaletteQuickSelectTests {
    static func key(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    @Test("⇧ and a top-row number key, by position, whatever the layout types or Caps Lock")
    func keys() {
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_1, "!", .shift)) == 1)
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_9, "(", .shift)) == 9)
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_5, "%", [.shift, .capsLock])) == 5)
        // On AZERTY the key left of 2 types 1 with Shift; quick select takes it anyway.
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_1, "1", .shift)) == 1)
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_1, "1", [])) == nil, "A plain digit types")
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_0, ")", .shift)) == nil)
        #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_Keypad1, "1", [.shift, .numericPad])) == nil)
        for other: NSEvent.ModifierFlags in [.command, .option, .control] {
            #expect(PaletteQuickSelect.number(for: Self.key(kVK_ANSI_1, "!", [.shift, other])) == nil)
        }
    }

    @Test("Rows on screen are numbered from the top one, up to nine")
    func numbering() {
        let quickSelect = PaletteQuickSelect()
        #expect(quickSelect.row(for: 3) == 2, "With no rows drawn, ⇧3 is the third row")
        #expect(quickSelect.number(forRow: 0) == nil, "A row not on screen has no number")

        // 40pt rows under a 600pt viewport, scrolled so row 3 is at the top.
        let list = UUID()
        quickSelect.setViewport(CGRect(x: 0, y: 100, width: 800, height: 600), of: list)
        func frame(_ row: Int) -> CGRect { CGRect(x: 0, y: 100 + CGFloat(row - 3) * 40, width: 800, height: 40) }
        let views = (0..<20).map { _ in UUID() }
        for row in 2..<20 { quickSelect.report(views[row], row: row, frame: frame(row)) }
        #expect(quickSelect.visibleRows == Set(3...16), "Row 2 is above the top; the footer covers row 17 and later")
        #expect(quickSelect.number(forRow: 3) == 1)
        #expect(quickSelect.number(forRow: 11) == 9)
        #expect(quickSelect.number(forRow: 12) == nil, "Only nine")
        #expect(quickSelect.row(for: 1) == 3)

        // The old tab's row 3 going away doesn't drop the new tab's row 3.
        quickSelect.report(UUID(), row: 3, frame: frame(3))
        quickSelect.report(views[3], row: 3, frame: nil)
        #expect(quickSelect.number(forRow: 3) == 1)

        // A view that now shows another row keeps its place on screen.
        quickSelect.move(views[4], to: 40)
        #expect(quickSelect.visibleRows.contains(40))

        // A new list reports before the old one goes away; only the list that reported last counts.
        let newList = UUID()
        quickSelect.setViewport(CGRect(x: 0, y: 140, width: 800, height: 600), of: newList)
        quickSelect.setViewport(nil, of: list)
        #expect(!quickSelect.visibleRows.contains(3), "Row 3 is above the new list's top")
        #expect(quickSelect.visibleRows.contains(5))
        quickSelect.setViewport(nil, of: newList)
        #expect(quickSelect.visibleRows.isEmpty, "With no list, no row is on screen")
    }

    @Test("In Timers, a ⇧ key that types a digit types it, for durations on French-style layouts")
    func timersTypeDigits() {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        let azertyFive = Self.key(kVK_ANSI_5, "5", .shift)
        let usFive = Self.key(kVK_ANSI_5, "%", .shift)
        #expect(PaletteQuickSelect.typesDigit(azertyFive))
        #expect(!PaletteQuickSelect.typesDigit(usFive))

        fixture.palette.selectOnOpening(.timers)
        #expect(fixture.palette.handleKeyDown(azertyFive) != nil, "5 goes to the search field")
        #expect(fixture.palette.handleKeyDown(usFive) == nil, "On a US layout ⇧5 is still quick select")

        fixture.palette.selectOnOpening(.clipboard)
        #expect(fixture.palette.handleKeyDown(azertyFive) == nil, "Elsewhere it's quick select, as decided")
    }

    @Test("Scrolling the real Clipboard list numbers from the first row wholly inside it, not one behind the header")
    func scrolledListNumbersFromItsTopRow() throws {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        for index in 1...30 { fixture.clipboard.ingestForTesting("made-up clipboard text \(index)") }
        fixture.palette.show(.clipboard)
        defer { fixture.palette.dismiss() }
        let quickSelect = fixture.palette.state.quickSelect
        try #require(Self.waitUntil { quickSelect.visibleRows.contains(0) })
        let panel = try #require(NSApp.windows.first { $0.identifier?.rawValue == "commandPalette" })
        let content = try #require(panel.contentView)
        let list = try #require(Self.scrollViews(in: content).first { $0.documentView is NSTableView })

        // Part of the top row scrolls up under the header.
        list.contentView.scroll(to: NSPoint(x: 0, y: 30))
        list.reflectScrolledClipView(list.contentView)

        #expect(Self.waitUntil { quickSelect.firstRow == 1 }, "⇧1 is the first row wholly showing, not the cut-off one")
        #expect(quickSelect.number(forRow: 0) == nil)
    }

    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    @Test("Clipboard: ⇧2 copies the second entry")
    func clipboard() {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        for text in ["made-up first", "made-up second", "made-up third"] { fixture.clipboard.ingestForTesting(text) }
        fixture.palette.selectOnOpening(.clipboard)
        let second = fixture.clipboard.entries[1].text

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_2, "@", .shift)) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == second)
    }

    @Test("Snippets: ⇧2 copies the second snippet listed")
    func snippets() throws {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        for name in ["Made-up alpha", "Made-up beta", "Made-up gamma"] {
            try fixture.snippets.add(SnippetDraft(name: name, keyword: ";\(name.split(separator: " ")[1])", text: "\(name) text"))
        }
        fixture.preferences.setCapability(.snippets, enabled: true)
        fixture.palette.selectOnOpening(.snippets)
        let listed = SnippetPaletteContent.resolve(
            snippets: fixture.snippets.snippets, query: "", isEnabled: true, libraryState: fixture.snippets.libraryState
        ).entries
        try #require(listed.count == 3)

        _ = fixture.palette.handleKeyDown(Self.key(kVK_ANSI_2, "@", .shift))
        #expect(fixture.pasteboard.string(forType: .string) == listed[1].text)
    }

    @Test("Holding ⇧N acts once, not again on whatever row is Nth by then")
    func heldKeyActsOnce() {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        for text in ["made-up first", "made-up second"] { fixture.clipboard.ingestForTesting(text) }
        fixture.palette.selectOnOpening(.clipboard)
        let repeated = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
            characters: "!", charactersIgnoringModifiers: "!", isARepeat: true, keyCode: UInt16(kVK_ANSI_1)
        )!

        _ = fixture.palette.handleKeyDown(Self.key(kVK_ANSI_1, "!", .shift))
        #expect(fixture.pasteboard.string(forType: .string) == fixture.clipboard.entries[0].text, "The press acts")
        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(repeated) == nil, "A held key still doesn't type !")
        #expect(fixture.pasteboard.string(forType: .string) == nil, "Its repeats don't act again")
    }

    @Test("Command keys are Command alone; Caps Lock, Fn and the keypad flag don't matter")
    func commandKeys() {
        for flags: NSEvent.ModifierFlags in [.command, [.command, .capsLock], [.command, .function], [.command, .numericPad]] {
            #expect(CommandPaletteController.isCommandKey(Self.key(kVK_ANSI_E, "e", flags)))
        }
        for flags: NSEvent.ModifierFlags in [[], .capsLock, [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(!CommandPaletteController.isCommandKey(Self.key(kVK_ANSI_E, "e", flags)))
        }
    }

    @Test("/'s filters are numbered too: ⇧2 chooses the second")
    func filters() {
        let fixture = QuickSelectFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.clipboard)
        fixture.palette.state.historyQuery = "/"

        _ = fixture.palette.handleKeyDown(Self.key(kVK_ANSI_2, "@", .shift))
        #expect(fixture.palette.state.filter == .images)
    }
}

/// A palette over temporary folders and a named pasteboard, never the real ones.
@MainActor
private final class QuickSelectFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsQuickSelect-\(UUID().uuidString)"))
    let clipboard: ClipboardHistoryService
    let snippets: SnippetStore
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let palette: CommandPaletteController

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
        snippets = folder.makeStore()
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
            snippets: snippets,
            pasteboard: pasteboard,
            notices: QuietNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

private final class QuietNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
