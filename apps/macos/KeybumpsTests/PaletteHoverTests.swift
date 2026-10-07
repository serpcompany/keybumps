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

        // Clipboard only filters as you type, so its selection stays put; typing still re-arms.
        fixture.pointer = NSPoint(x: 10, y: 90)
        fixture.palette.state.historyQuery = "made-up"
        #expect(fixture.palette.state.selection == 0)
        fixture.palette.hover(row: 3)
        #expect(fixture.palette.state.selection == 0, "Rows that typing brought under a still pointer")
    }

    @Test("Hovering a screenshot tile brings the arrow keys into the grid")
    func gridTile() {
        let fixture = HoverFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.screenshots)
        #expect(!fixture.palette.state.isBrowsingGrid)

        fixture.pointer = NSPoint(x: 10, y: 20)
        fixture.palette.hover(row: 0)
        #expect(fixture.palette.state.isBrowsingGrid)
    }
}

/// A palette over temporary folders and a named pasteboard, with a pointer the test moves.
@MainActor
private final class HoverFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsHover-\(UUID().uuidString)"))
    let clipboard: ClipboardHistoryService
    let palette: CommandPaletteController
    var pointer = NSPoint(x: -1000, y: -1000)

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
                language: "en-US", history: dictationHistory, paster: InertTextPaster(), allowsSystemAccess: false
            ),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: HoverNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
        palette.state.mouseLocation = { [unowned self] in pointer }
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

private final class HoverNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
