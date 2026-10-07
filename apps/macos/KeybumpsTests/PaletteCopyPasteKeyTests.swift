import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// ⌘C copies and ⌘P pastes the highlighted row, and Space plays and pauses audio (#370), in the tabs
/// the palette draws itself: Clipboard, Screenshots, Dictation, and Quick Search's emoji rows. The
/// Snippets, Emoji, and Translate tabs have theirs in their own suites; `CapabilityPaletteContentTests`
/// covers how the keys reach a module tab's rows.
@MainActor
@Suite("Command Palette: ⌘C, ⌘P, and Space on a highlighted row")
struct PaletteCopyPasteKeyTests {
    static func key(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    static let commandC = key(kVK_ANSI_C, "c", modifiers: .command)
    static let commandP = key(kVK_ANSI_P, "p", modifiers: .command)
    static let returnKey = key(kVK_Return, "\r")
    static let commandReturn = key(kVK_Return, "\r", modifiers: .command)
    static let space = key(kVK_Space, " ")
    static let downKey = key(kVK_DownArrow, "", modifiers: [.function, .numericPad])

    /// The palette's search field, as `CommandPaletteController` finds it to focus it.
    static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    /// The view behind SwiftUI's selectable text (`.textSelection(.enabled)`), such as a transcript:
    /// one that takes the keys, can select all, and reports its selection to accessibility. On
    /// macOS 27 it's an `AppKitTextInteractionView`, not an NSTextView. The search field is skipped.
    static func selectableText(in view: NSView?) -> NSView? {
        guard let view, !(view is NSTextField) else { return nil }
        if view.acceptsFirstResponder, view.responds(to: #selector(NSResponder.selectAll(_:))),
           view.accessibilitySelectedText() != nil {
            return view
        }
        return view.subviews.lazy.compactMap { selectableText(in: $0) }.first
    }

    // MARK: Clipboard

    @Test("Clipboard: ⌘C copies the highlighted item as Return does; ⌘P puts it on the clipboard, pastes it, and leaves it there")
    func clipboardCopiesAndPastes() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        fixture.copy("made-up first")
        fixture.copy("made-up second")
        fixture.palette.state.select(.clipboard)
        fixture.palette.state.selection = 1

        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up first")
        #expect(fixture.notices.shown == [.init(message: "Copied to Clipboard", isWarning: false)])

        fixture.palette.state.select(.clipboard)
        fixture.palette.state.selection = 1
        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up first", "On the clipboard before ⌘V")
        try await fixture.waitUntil { fixture.paster.clipboardPastes == 1 }
        #expect(fixture.paster.pasted.isEmpty, "⌘V for the item itself, never a text rewrite")
        #expect(fixture.palette.clipboardRestorer.pendingRestore == nil, "Nothing is put back: the item stays")
        #expect(fixture.pasteboard.string(forType: .string) == "made-up first")
        #expect(fixture.notices.shown.count == 1, "A paste shows no notice")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.map(\.text) == ["made-up second", "made-up first"], "No new item")

        // ⌘Return copies, as Return does; it doesn't paste.
        fixture.palette.state.select(.clipboard)
        #expect(fixture.palette.handleKeyDown(Self.commandReturn) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up second")
        #expect(fixture.paster.clipboardPastes == 1)
    }

    @Test("Clipboard: without Accessibility, ⌘P leaves the item copied, says why, and offers setup for Clipboard History; a failed paste still leaves it copied")
    func clipboardPasteThatCantPaste() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        fixture.copy("made-up item")
        var offered: [Capability] = []
        fixture.palette.offerPasteSetup = { offered.append($0) }

        fixture.palette.canPaste = { false }
        fixture.palette.state.select(.clipboard)
        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up item")
        #expect(fixture.notices.shown == [.init(message: "Copied · Paste needs Accessibility", isWarning: true)])
        #expect(offered == [.clipboardHistory])
        #expect(fixture.paster.clipboardPastes == 0)

        fixture.palette.canPaste = { true }
        fixture.paster.fails = true
        fixture.palette.state.select(.clipboard)
        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        try await fixture.waitUntil { fixture.notices.shown.count == 2 }
        #expect(fixture.notices.shown.last == .init(message: "Copied · Couldn’t paste", isWarning: true))
        #expect(fixture.pasteboard.string(forType: .string) == "made-up item")
    }

    @Test("⌘C and ⌘P do nothing while `/`'s list of filters shows, or in an empty tab")
    func noHighlightedRow() {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        fixture.palette.state.select(.clipboard)
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)

        fixture.copy("made-up item")
        fixture.pasteboard.clearContents()
        fixture.palette.state.select(.clipboard)
        fixture.palette.state.historyQuery = "/"
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == nil)
        #expect(fixture.notices.shown.isEmpty)
        #expect(fixture.paster.clipboardPastes == 0)
    }

    // MARK: Screenshots

    @Test("Screenshots: once a screenshot is highlighted, ⌘C copies it and ⌘P pastes it; ⌘Return still opens the editor")
    func screenshotsCopyPasteAndEdit() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.screenshot("Made-up.png")
        var edited: [UUID] = []
        fixture.palette.editImage = { edited.append($0.id); return true }
        fixture.palette.state.select(.screenshots)

        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.types?.isEmpty != false, "Nothing is highlighted until Down goes into the grid")

        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.pasteboard.data(forType: .png) != nil)
        #expect(fixture.notices.shown.map(\.message) == ["Copied to Clipboard"])

        fixture.palette.state.select(.screenshots)
        fixture.palette.state.isBrowsingGrid = true
        fixture.pasteboard.clearContents()
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.data(forType: .png) != nil)
        try await fixture.waitUntil { fixture.paster.clipboardPastes == 1 }
        #expect(fixture.pasteboard.data(forType: .png) != nil, "It stays on the clipboard")

        fixture.palette.state.select(.screenshots)
        #expect(fixture.palette.handleKeyDown(Self.commandReturn) == nil)
        #expect(edited == [entry.id], "⌘Return opens the Screenshot Editor, as before")
        #expect(fixture.paster.clipboardPastes == 1)
    }

    @Test("Screenshots: without Accessibility, ⌘P offers setup for Screenshot Tools")
    func screenshotsPasteSetup() throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        _ = try fixture.screenshot("Made-up.png")
        var offered: [Capability] = []
        fixture.palette.offerPasteSetup = { offered.append($0) }
        fixture.palette.canPaste = { false }
        fixture.palette.state.select(.screenshots)
        fixture.palette.state.isBrowsingGrid = true

        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(offered == [.screenshotTools])
        #expect(fixture.pasteboard.data(forType: .png) != nil)
    }

    // MARK: Dictation

    @Test("Dictation: ⌘C copies the transcript, kept out of Clipboard History; ⌘P pastes it and leaves it on the clipboard")
    func dictationCopiesAndPastes() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        try fixture.recording("made-up transcript")
        fixture.palette.state.select(.dictation)

        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up transcript")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "Kept out of Clipboard History")

        fixture.palette.state.select(.dictation)
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        try await fixture.waitUntil { !fixture.paster.pasted.isEmpty }
        #expect(fixture.paster.pasted.map(\.text) == ["made-up transcript"])
        #expect(fixture.palette.clipboardRestorer.pendingRestore == nil, "The transcript stays on the clipboard")
    }

    @Test("Dictation: Space plays and pauses the highlighted recording only while the search field is empty")
    func dictationSpace() throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.recording("made-up transcript")
        var toggled: [String] = []
        fixture.palette.toggleDictationPlayback = { toggled.append($0.id) }
        fixture.palette.state.select(.dictation)

        #expect(fixture.palette.handleKeyDown(Self.space) == nil)
        #expect(fixture.palette.handleKeyDown(Self.space) == nil)
        #expect(toggled == [entry.id, entry.id])
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Space, " ", modifiers: .shift)) != nil)

        fixture.palette.state.historyQuery = "made-up"
        #expect(fixture.palette.handleKeyDown(Self.space) != nil, "With text in the field, Space types")
        #expect(toggled.count == 2)
        #expect(fixture.pasteboard.string(forType: .string) == nil, "Space never copies")
    }

    @Test("Space types while an input method is composing, and ⌘C with text selected in the search field is the field's")
    func searchFieldKeepsItsKeys() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.recording("made-up transcript")
        var toggled: [String] = []
        fixture.palette.toggleDictationPlayback = { toggled.append($0.id) }
        let panel = try #require(fixture.palette.layOutForTesting(.dictation))
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(Self.searchField(in: panel.contentView))
        #expect(panel.makeFirstResponder(field))
        let editor = try #require(panel.firstResponder as? NSTextView)

        editor.setMarkedText("きょう", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.palette.handleKeyDown(Self.space) != nil, "Space goes to the input method")
        #expect(fixture.palette.handleKeyDown(Self.commandC) != nil)
        #expect(fixture.palette.handleKeyDown(Self.commandP) != nil, "⌘P too")
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.paster.pasted.isEmpty, "Nothing was pasted")
        #expect(fixture.pasteboard.string(forType: .string) == nil)
        editor.unmarkText()
        editor.string = ""
        fixture.palette.state.historyQuery = ""
        #expect(toggled.isEmpty)

        // Selected text in the field: ⌘C is the field's, as in any text field, and the row isn't copied.
        editor.string = "made-up"
        editor.selectAll(nil)
        #expect(fixture.palette.handleKeyDown(Self.commandC) != nil)
        #expect(fixture.pasteboard.string(forType: .string) == nil)

        // With nothing selected, ⌘C copies the highlighted recording.
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up transcript")
        #expect(fixture.palette.handleKeyDown(Self.space) == nil)
        #expect(toggled == [entry.id])
    }

    @Test("Part of a transcript selected with the pointer: ⌘C is Edit › Copy's, not the recording's")
    func pointerSelectionInTheTranscript() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        try fixture.recording("made-up transcript")
        let panel = try #require(fixture.palette.layOutForTesting(.dictation))
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()

        // SwiftUI's selectable text, as a click on the transcript leaves it: taking the keys.
        let transcript = try #require(Self.selectableText(in: panel.contentView))
        #expect(panel.makeFirstResponder(transcript))
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil, "Nothing selected: ⌘C copies the recording")
        #expect(fixture.pasteboard.string(forType: .string) == "made-up transcript")

        fixture.pasteboard.clearContents()
        transcript.perform(#selector(NSResponder.selectAll(_:)), with: nil)
        #expect(fixture.palette.handleKeyDown(Self.commandC) != nil)
        #expect(fixture.pasteboard.string(forType: .string) == nil, "The recording wasn't copied")
        #expect(fixture.notices.shown.count == 1)
    }

    // MARK: Quick Search

    @Test("Quick Search: ⌘C copies an emoji, ⌘P pastes it and puts the clipboard back; on an app or command they do nothing")
    func quickSearchEmoji() async throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        let emoji = QuickSearchEmoji(glyph: "🎉", baseGlyph: "🎉", name: "made-up party")
        var used: [String] = []
        fixture.palette.setQuickSearchEmoji(matches: { $0 == "zzqq" ? [emoji] : [] }, use: { used.append($0.glyph) })
        fixture.palette.clipboardRestorer.delay = .zero
        fixture.paster.pasteboard = fixture.pasteboard

        fixture.palette.state.select(.search)
        fixture.search.query = "zzqq"
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "🎉")
        #expect(used == ["🎉"])

        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.palette.state.select(.search)
        fixture.search.query = "zzqq"
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        try await fixture.waitUntil { !fixture.paster.pasted.isEmpty }
        await fixture.palette.clipboardRestorer.pendingRestore?.value
        #expect(fixture.paster.pasted.map(\.text) == ["🎉"])
        #expect(fixture.pasteboard.string(forType: .string) == "made-up earlier copy", "The clipboard is put back, as the Emoji tab does")
        #expect(used == ["🎉", "🎉"])

        // Keybumps Settings, a command: neither copies nor pastes.
        fixture.pasteboard.clearContents()
        fixture.palette.state.select(.search)
        fixture.search.query = "keybumps settings"
        #expect(fixture.palette.handleKeyDown(Self.commandC) == nil)
        #expect(fixture.palette.handleKeyDown(Self.commandP) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == nil)
        #expect(fixture.paster.pasted.count == 1)
    }

    // MARK: Footer and paste step

    @Test("The footer names each tab's keys: Copy ↵ and Paste ⌘P, Edit ⌘↵ in Screenshots, and Space for audio")
    func footerKeys() throws {
        func footer(_ tab: CommandPaletteTab, playback: String? = nil, isRowHighlighted: Bool = true) -> [String] {
            let actions = PaletteFooterActions.resolve(
                tab: tab, searchItem: nil, content: nil, playback: playback, isRowHighlighted: isRowHighlighted
            )
            return (actions.primary.map { ["\($0) ↵"] } ?? []) + actions.secondary.map(\.description)
        }
        #expect(footer(.search) == ["Open ↵"])
        #expect(footer(.clipboard) == ["Copy ↵", "Paste ⌘P"])
        #expect(footer(.screenshots) == ["Copy ↵", "Paste ⌘P", "Edit ⌘↵"])
        // Before Down goes into the grid, Return and ⌘Return act on the first screenshot; ⌘P does nothing.
        #expect(footer(.screenshots, isRowHighlighted: false) == ["Copy ↵", "Edit ⌘↵"])
        #expect(footer(.emoji, isRowHighlighted: false) == ["Copy ↵"])
        #expect(footer(.dictation, playback: "Play") == ["Copy ↵", "Paste ⌘P", "Play Space"])
        #expect(footer(.snippets) == ["Copy ↵", "Paste ⌘P"])
        #expect(footer(.timers) == ["Start ↵"])
        #expect(footer(.emoji) == ["Copy ↵", "Paste ⌘P"])
        #expect(footer(.keyboardShortcutter).isEmpty)

        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.recording("made-up transcript")
        #expect(DictationPaletteResults.playbackTitle(of: entry, player: fixture.palette.dictationPlayer) == "Play")
        let silent = DictationHistoryEntry(metadata: entry.metadata, directoryURL: entry.directoryURL, audioURL: nil)
        #expect(DictationPaletteResults.playbackTitle(of: silent, player: fixture.palette.dictationPlayer) == nil, "No audio, no Space")
    }

    @Test("VoiceOver reads each footer hint as words: \"Paste, Command P\"")
    func footerHintsSpoken() {
        #expect(PaletteKeyAction.accessibilityLabel(title: "Paste", keys: PaletteKeyAction.paste().keys) == "Paste, Command P")
        #expect(PaletteKeyAction.accessibilityLabel(title: "Edit", keys: PaletteKeyAction.edit.keys) == "Edit, Command Return")
        #expect(PaletteKeyAction.accessibilityLabel(title: "Copy", keys: ["↵"]) == "Copy, Return")
        #expect(PaletteKeyAction.accessibilityLabel(title: "Play", keys: ["Space"]) == "Play, Space")
        #expect(PaletteKeyAction.accessibilityLabel(title: "Select", keys: ["↑", "↓"]) == "Select, Up Arrow or Down Arrow")
    }

    @Test("The shared paste step presses ⌘V for what's on the clipboard without writing it; the inert one refuses")
    func pasteClipboardStep() throws {
        let fixture = CopyPasteFixture()
        defer { fixture.tearDown() }
        var steps: [String] = []
        var paster = SystemTextPaster()
        paster.pasteboard = { fixture.pasteboard }
        paster.didWritePasteboard = { steps.append("write") }
        paster.postCommandV = { steps.append("⌘V") }
        fixture.pasteboard.writeText("made-up item")

        try paster.pasteClipboard()
        #expect(steps == ["⌘V"])
        #expect(fixture.pasteboard.string(forType: .string) == "made-up item")
        #expect(throws: TextPasteError.unavailable) { try InertTextPaster().pasteClipboard() }
    }
}

/// A palette over a temporary folder and a named pasteboard, with another app in front to paste
/// into, Accessibility granted, and a paste step that records instead of pressing ⌘V.
@MainActor
private final class CopyPasteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsCopyPaste-\(UUID().uuidString)"))
    let paster = RecordingClipboardPaster()
    let notices = CopyPasteNotices()
    let clipboard: ClipboardHistoryService
    let dictationHistory: DictationHistoryService
    let search: QuickSearchModel
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        dictationHistory = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
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
            paster: paster,
            pasteboard: pasteboard,
            notices: notices,
            search: search
        )
        palette.canPaste = { true }
        palette.pasteDelay = .zero
        palette.frontmostApp = { PasteTarget(processIdentifier: 4242, isKeybumps: false) }
        palette.rememberPasteTarget()
    }

    /// Copies text in "another app", as Clipboard History sees it.
    func copy(_ text: String) {
        pasteboard.writeText(text)
        clipboard.pollForTesting()
    }

    /// Adds a screenshot to Clipboard History, as the screenshot folder's watcher does.
    @discardableResult
    func screenshot(_ name: String) throws -> ClipboardEntry {
        let url = folder.url.appendingPathComponent(name)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!
        try (png + Data(name.utf8)).write(to: url)
        #expect(clipboard.ingestImageFile(at: url))
        return try #require(clipboard.entries.first)
    }

    /// A finished recording with its (made-up) audio file.
    @discardableResult
    func recording(_ transcript: String) throws -> DictationHistoryEntry {
        let audio = folder.url.appendingPathComponent("made-up-\(UUID().uuidString).wav")
        try Data("made-up audio".utf8).write(to: audio)
        return try dictationHistory.record(transcript, language: "en-US", duration: 1, audioSourceURL: audio)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    func tearDown() {
        palette.dictationPlayer.stop()
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// Records each paste instead of pressing ⌘V: a text paste, which writes the text first as the real
/// step does when `pasteboard` is set, or a paste of what's on the clipboard already.
@MainActor
private final class RecordingClipboardPaster: TextPasting {
    private(set) var pasted: [(text: String, concealed: Bool)] = []
    private(set) var clipboardPastes = 0
    var fails = false
    var pasteboard: NSPasteboard?

    func paste(_ text: String, concealed: Bool) throws {
        if fails { throw TextPasteError.keystrokeUnavailable }
        _ = pasteboard?.writeText(text, concealed: concealed)
        pasted.append((text, concealed))
    }

    func pasteClipboard() throws {
        if fails { throw TextPasteError.keystrokeUnavailable }
        clipboardPastes += 1
    }
}

@MainActor
private final class CopyPasteNotices: PaletteNoticePresenting {
    struct Notice: Equatable {
        let message: String
        let isWarning: Bool
    }

    private(set) var shown: [Notice] = []

    func showNotice(_ message: String, isWarning: Bool) {
        shown.append(Notice(message: message, isWarning: isWarning))
    }
}
