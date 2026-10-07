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
        quickSelect.setViewport(CGRect(x: 0, y: 100, width: 800, height: 600))
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
