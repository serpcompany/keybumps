import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

// Keyword auto-expansion: typing a snippet's keyword in another app replaces it with the snippet.
// Every snippet here is made up. Keys come from a fake monitor, the replacement goes to a recording
// fake, and the clipboard is a named pasteboard each test releases, so no test listens to the
// keyboard, posts a key, or touches the owner's clipboard or Keychain.

// MARK: - What a key press means

@Suite("Keyword expansion: reading key presses")
struct TypedKeyTests {
    @Test("Typed characters, Delete, and everything else that ends what was being typed")
    func translation() {
        func key(_ code: Int, _ characters: String, _ flags: CGEventFlags = [], synthetic: Bool = false) -> TypedKey {
            TypedKey(keyCode: code, characters: characters, flags: flags, isSynthetic: synthetic)
        }
        #expect(key(kVK_ANSI_S, "s") == .characters("s"))
        #expect(key(kVK_ANSI_S, "S", .maskShift) == .characters("S"))
        #expect(key(kVK_ANSI_E, "é", .maskAlternate) == .characters("é"), "Option types characters")
        #expect(key(kVK_Space, " ") == .characters(" "))
        #expect(key(kVK_Delete, "\u{7f}") == .deleteBackward)
        #expect(key(kVK_Delete, "\u{7f}", .maskShift) == .deleteBackward)
        #expect(key(kVK_Delete, "\u{7f}", .maskAlternate) == .reset, "⌥⌫ deletes a word, not one character")

        #expect(key(kVK_ANSI_S, "s", .maskCommand) == .reset, "A shortcut")
        #expect(key(kVK_ANSI_S, "\u{13}", .maskControl) == .reset)
        #expect(key(kVK_Return, "\r") == .reset)
        #expect(key(kVK_Tab, "\t") == .reset)
        #expect(key(kVK_Escape, "\u{1b}") == .reset)
        #expect(key(kVK_LeftArrow, "\u{F702}", .maskSecondaryFn) == .reset)
        #expect(key(kVK_ForwardDelete, "\u{F728}") == .reset)
        #expect(key(kVK_ANSI_E, "", .maskAlternate) == .reset, "A dead key types nothing yet")
        #expect(key(kVK_ANSI_V, "v", .maskCommand, synthetic: true) == .reset, "Keybumps' own keys")
        #expect(key(kVK_Delete, "\u{7f}", synthetic: true) == .reset)
    }

    @Test("A key event's code, characters, flags, and Keybumps' marker are read as the tap sees them")
    func readsEvents() throws {
        let typed = try keyDown(kVK_ANSI_S)
        typed.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array("s".utf16))
        #expect(KeyTypingMonitor.typedKey(from: typed) == .characters("s"))

        typed.flags = .maskCommand
        #expect(KeyTypingMonitor.typedKey(from: typed) == .reset)

        let own = try keyDown(kVK_ANSI_S)
        own.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array("s".utf16))
        own.setIntegerValueField(.eventSourceUserData, value: SystemTextPaster.syntheticEventMarker)
        #expect(KeyTypingMonitor.typedKey(from: own) == .reset)
    }

    /// A key-down event that can't pick up modifier keys someone is physically holding while the
    /// tests run (#295): an event from no source takes on the live modifiers, such as ⌥ held for
    /// Dictation's ⌥Space, and then reads as a shortcut.
    private func keyDown(_ code: Int) throws -> CGEvent {
        let event = try #require(CGEvent(
            keyboardEventSource: CGEventSource(stateID: .privateState),
            virtualKey: CGKeyCode(code),
            keyDown: true
        ))
        event.flags = []
        return event
    }

    @Test("A key that reaches Keybumps late is never expanded, since more typing may have landed first")
    func lateKeys() throws {
        #expect(!KeyTypingMonitor.isLate(eventUptime: 10.0, now: 10.05))
        #expect(KeyTypingMonitor.isLate(eventUptime: 10.0, now: 10.2))
        #expect(!KeyTypingMonitor.isLate(eventUptime: 0, now: 10.2), "A key posted with no timestamp counts as on time")

        // A real event's timestamp is read on the same clock as system uptime.
        let event = try keyDown(kVK_ANSI_S)
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let read = try #require(KeyTypingMonitor.uptime(of: event))
        #expect(abs(read - ProcessInfo.processInfo.systemUptime) < 0.05)
        event.timestamp = 0
        #expect(KeyTypingMonitor.uptime(of: event) == nil)
    }

    @Test("A key or click after the keyword's last key, by more than 10 ms, counts as newer input")
    func newerInput() {
        // The keyword's last key went down at 100.000; now is 100.200.
        #expect(!KeyTypingMonitor.happenedSince(lastKeyUptime: 100.0, now: 100.2, secondsSinceInput: [0.2, 5, 5]), "That key itself")
        #expect(KeyTypingMonitor.happenedSince(lastKeyUptime: 100.0, now: 100.2, secondsSinceInput: [0.05, 5, 5]), "A newer key")
        #expect(KeyTypingMonitor.happenedSince(lastKeyUptime: 100.0, now: 100.2, secondsSinceInput: [0.2, 0.05, 5]), "A click")
        #expect(!KeyTypingMonitor.happenedSince(lastKeyUptime: 100.0, now: 100.2, secondsSinceInput: [0.195, 5, 5]), "Within 10 ms")
    }
}

// MARK: - Matching what was typed

@Suite("Keyword expansion: matching keywords")
struct KeywordBufferTests {
    static let ship = UUID()
    static let shipBare = UUID()
    static let entries = KeywordExpansion.entries(for: [
        Snippet(id: ship, name: "Made-up", text: "made-up text", keyword: ";ship", createdAt: .distantPast),
        Snippet(id: shipBare, name: "Made-up bare", text: "made-up text", keyword: "ship", createdAt: .distantPast),
        Snippet(name: "No keyword", text: "made-up text", createdAt: .distantPast),
    ])

    static func type(_ text: String, into buffer: inout KeywordBuffer) -> KeywordBuffer.Match? {
        var match: KeywordBuffer.Match?
        for character in text {
            if let found = buffer.handle(.characters(String(character)), keywords: entries) { match = found }
        }
        return match
    }

    @Test("A keyword expands the moment it's complete, even in the middle of a word")
    func completes() {
        var buffer = KeywordBuffer()
        #expect(Self.type(";shi", into: &buffer) == nil)
        #expect(buffer.handle(.characters("p"), keywords: Self.entries) == .init(snippetID: Self.ship, length: 5))
        #expect(buffer.typed.isEmpty, "A match starts over")
        #expect(Self.type("abc;ship", into: &buffer)?.snippetID == Self.ship)
    }

    @Test("The longest keyword that was typed wins, and case must match")
    func longestAndCase() {
        var buffer = KeywordBuffer()
        #expect(Self.type(";ship", into: &buffer) == .init(snippetID: Self.ship, length: 5), "Not the shorter `ship`")
        #expect(Self.type("xship", into: &buffer) == .init(snippetID: Self.shipBare, length: 4))
        #expect(Self.type(";SHIP", into: &buffer) == nil)
    }

    @Test("A reset in the middle of a keyword stops it; Delete takes back one character")
    func resetAndDelete() {
        var buffer = KeywordBuffer()
        _ = Self.type(";sh", into: &buffer)
        _ = buffer.handle(.reset, keywords: Self.entries)
        #expect(Self.type("ip", into: &buffer) == nil)

        _ = Self.type(";shx", into: &buffer)
        _ = buffer.handle(.deleteBackward, keywords: Self.entries)
        #expect(Self.type("ip", into: &buffer)?.snippetID == Self.ship)
    }

    @Test("An empty or spaced keyword, possible only in a hand-edited file, is never listened for")
    func emptyKeywords() {
        let entries = KeywordExpansion.entries(for: [
            Snippet(name: "Empty", text: "made-up text", keyword: "", createdAt: .distantPast),
            Snippet(name: "Spaces", text: "made-up text", keyword: "  ", createdAt: .distantPast),
            Snippet(name: "Spaced", text: "made-up text", keyword: "a b", createdAt: .distantPast),
        ])
        #expect(entries.isEmpty)
    }

    @Test("It never keeps more characters than the longest keyword, and none without keywords")
    func bounded() {
        var buffer = KeywordBuffer()
        _ = Self.type("a long sentence that is never a keyword", into: &buffer)
        #expect(buffer.typed.count <= 5)
        var empty = KeywordBuffer()
        _ = empty.handle(.characters("abc"), keywords: [])
        #expect(empty.typed.isEmpty)
    }
}

// MARK: - Expanding

@MainActor
@Suite("Keyword expansion: replacing the keyword")
struct KeywordExpansionControllerTests {
    @Test("Typing a keyword replaces it with the snippet's text, records the use, and puts the clipboard back")
    func expands() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")

        fixture.type(";ship")
        #expect(fixture.replacer.steps == ["delete 5", "paste made-up shipping text"], "The keyword goes first, then the paste")
        #expect(fixture.monitor.newerKeyChecks == 1, "It checks for newer typing right before deleting")
        #expect(fixture.store.snippet(withID: fixture.plain.id)?.lastUsedAt != nil)
        try await fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "made-up earlier copy" }
        #expect(fixture.restores == 1, "Putting the clipboard back is kept out of Clipboard History")
    }

    @Test("A sensitive snippet expands with its Keychain text, marked concealed")
    func sensitive() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.type(";key")
        #expect(fixture.replacer.steps == ["delete 4", "paste made-up-secret (concealed)"])
    }

    @Test("Nothing expands in Keybumps' own windows or while macOS hides typing (secure input)")
    func exclusions() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.typingIsInKeybumps = true
        fixture.type(";ship")
        fixture.typingIsInKeybumps = false
        fixture.secureInput = true
        fixture.type(";ship")
        #expect(fixture.replacer.steps.isEmpty)
    }

    @Test("Keybumps' own windows include the Command Palette, which never takes the app focus")
    func keybumpsWindows() {
        #expect(KeywordExpansionController.isTypingInKeybumps(isActive: false, hasKeyWindow: true, frontmostIsKeybumps: false),
                "The palette is a key window while another app stays in front")
        #expect(KeywordExpansionController.isTypingInKeybumps(isActive: true, hasKeyWindow: false, frontmostIsKeybumps: false))
        #expect(KeywordExpansionController.isTypingInKeybumps(isActive: false, hasKeyWindow: false, frontmostIsKeybumps: true))
        #expect(!KeywordExpansionController.isTypingInKeybumps(isActive: false, hasKeyWindow: false, frontmostIsKeybumps: false))
    }

    @Test("Switching apps or clicking clears what was typed")
    func reset() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.type(";sh")
        fixture.controller.handle(.reset)
        fixture.type("ip")
        #expect(fixture.replacer.steps.isEmpty)
    }

    @Test("A copy made before the clipboard is put back is kept")
    func newCopyWins() async throws {
        let fixture = try ExpansionFixture(restoreDelay: .milliseconds(50))
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.type(";ship")
        fixture.pasteboard.writeText("made-up new copy")
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.pasteboard.string(forType: .string) == "made-up new copy")
        #expect(fixture.restores == 0)
    }

    @Test("Two quick expansions put back the clipboard from before the first")
    func twoInARow() async throws {
        let fixture = try ExpansionFixture(restoreDelay: .milliseconds(50))
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.type(";ship")
        fixture.type(";ship")
        try await fixture.waitUntil { fixture.restores == 1 }
        #expect(fixture.pasteboard.string(forType: .string) == "made-up earlier copy")
    }

    @Test("A copy made between two quick expansions is the one put back")
    func copyBetweenExpansions() async throws {
        let fixture = try ExpansionFixture(restoreDelay: .milliseconds(50))
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.type(";ship")
        fixture.pasteboard.writeText("made-up copy in between")
        fixture.type(";ship")
        try await fixture.waitUntil { fixture.restores == 1 }
        #expect(fixture.pasteboard.string(forType: .string) == "made-up copy in between")
    }

    @Test("The clipboard is read after the keyword is deleted, never before")
    func snapshotAfterDelete() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        // Stands in for anything that changes the clipboard while the Deletes go out.
        fixture.replacer.copiesWhileDeleting = "made-up copy during the deletes"
        fixture.type(";ship")
        try await fixture.waitUntil { fixture.restores == 1 }
        #expect(fixture.pasteboard.string(forType: .string) == "made-up copy during the deletes")
    }

    @Test("A key typed after the keyword stops the expansion before anything is deleted")
    func newerTyping() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.monitor.newerKeyWentDown = true
        fixture.type(";ship")
        #expect(fixture.replacer.steps.isEmpty)
    }

    @Test("If the paste fails after the Deletes, a notice says so and the clipboard is still put back")
    func pasteFails() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.replacer.pasteFails = true
        fixture.type(";ship")
        #expect(fixture.notices.shown == ["Couldn’t paste the snippet"])
        try await fixture.waitUntil { fixture.restores == 1 }
        #expect(fixture.pasteboard.string(forType: .string) == "made-up earlier copy")
        #expect(fixture.store.snippet(withID: fixture.plain.id)?.lastUsedAt == nil)
    }

    @Test("If the paste fails before writing the clipboard, nothing needs putting back")
    func pasteFailsBeforeWriting() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.replacer.pasteFailsBeforeWriting = true
        fixture.type(";ship")
        #expect(fixture.notices.shown == ["Couldn’t paste the snippet"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.restores == 0)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up earlier copy")
    }

    @Test("If the keyword can't be replaced, nothing is recorded and the clipboard is left alone")
    func failure() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.replacer.fails = true
        fixture.pasteboard.writeText("made-up earlier copy")
        fixture.type(";ship")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.store.snippet(withID: fixture.plain.id)?.lastUsedAt == nil)
        #expect(fixture.restores == 0)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up earlier copy")
    }

    @Test("It listens only while Snippets and the switch are on and both permissions are granted")
    func whenItListens() throws {
        #expect(KeywordExpansionController.shouldListen(snippetsOn: true, switchOn: true, inputMonitoring: true, accessibility: true))
        #expect(!KeywordExpansionController.shouldListen(snippetsOn: false, switchOn: true, inputMonitoring: true, accessibility: true))
        #expect(!KeywordExpansionController.shouldListen(snippetsOn: true, switchOn: false, inputMonitoring: true, accessibility: true))
        #expect(!KeywordExpansionController.shouldListen(snippetsOn: true, switchOn: true, inputMonitoring: false, accessibility: true))
        #expect(!KeywordExpansionController.shouldListen(snippetsOn: true, switchOn: true, inputMonitoring: true, accessibility: false))

        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.controller.update(listening: true)
        #expect(fixture.monitor.isRunning)
        #expect(fixture.controller.isListening)
        fixture.type(";sh")
        fixture.controller.update(listening: false)
        #expect(!fixture.monitor.isRunning)
        fixture.controller.update(listening: true)
        fixture.type("ip")
        #expect(fixture.replacer.steps.isEmpty, "Stopping forgets what was typed")

        // macOS refusing the tap (for example before a relaunch) leaves it off, and it tries again.
        fixture.controller.update(listening: false)
        fixture.monitor.refuses = true
        fixture.controller.update(listening: true)
        #expect(!fixture.controller.isListening)
        fixture.monitor.refuses = false
        fixture.controller.update(listening: true)
        #expect(fixture.controller.isListening)
    }

    @Test("The switch is off by default and is remembered")
    func preference() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.expandsSnippetKeywords)
        preferences.expandsSnippetKeywords = true
        #expect(AppPreferences(defaults: defaults).expandsSnippetKeywords)
    }
}

// MARK: - Posting the replacement

@MainActor
@Suite("Keyword expansion: the keys Keybumps posts")
struct KeywordReplacementKeyTests {
    @Test("One Delete per keyword character, marked as Keybumps' own, and only with Accessibility")
    func backspaces() throws {
        var sent: [CGEvent] = []
        try SystemTextPaster.postSystemBackspaces(count: 3, accessibilityTrusted: { true }, send: { sent.append($0) })
        #expect(sent.count == 6)
        #expect(sent.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Delete) })
        #expect(sent.map { $0.type } == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        #expect(sent.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SystemTextPaster.syntheticEventMarker })

        sent = []
        #expect(throws: TextPasteError.accessibilityRequired) {
            try SystemTextPaster.postSystemBackspaces(count: 3, accessibilityTrusted: { false }, send: { sent.append($0) })
        }
        #expect(sent.isEmpty)
    }

    @Test("⌘V is marked as Keybumps' own too, so the typing monitor ignores it")
    func commandVMarked() throws {
        var sent: [CGEvent] = []
        try SystemTextPaster.postSystemCommandV(accessibilityTrusted: { true }, send: { sent.append($0) })
        #expect(sent.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == SystemTextPaster.syntheticEventMarker })
    }

    @Test("The paste step deletes typed characters with its own Delete poster")
    func deleteTyped() throws {
        var deleted: [Int] = []
        let paster = SystemTextPaster(postCommandV: {}, postBackspaces: { deleted.append($0) })
        try paster.deleteTyped(4)
        #expect(deleted == [4])
        #expect(throws: TextPasteError.unavailable) { try InertTextPaster().deleteTyped(4) }
    }

    @Test("A clipboard snapshot puts back every item and type, concealed ones included")
    func snapshot() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsSnapshot-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeText("made-up secret", concealed: true)
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.writeText("made-up other")
        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "made-up secret")
        #expect(pasteboard.types?.contains(.concealed) == true)

        pasteboard.clearContents()
        let empty = PasteboardSnapshot(pasteboard)
        pasteboard.writeText("made-up other")
        empty.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

// MARK: - Fixture

/// A controller over an in-memory library with one plain and one sensitive snippet, a fake
/// monitor and replacer, and a named pasteboard.
@MainActor
private final class ExpansionFixture {
    let store = SnippetStore(storageURL: nil, secrets: InMemorySnippetSecretStore())
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsExpansion-\(UUID().uuidString)"))
    let monitor = FakeTypingMonitor()
    let notices = RecordingExpansionNotices()
    let replacer: RecordingReplacer
    let controller: KeywordExpansionController
    let plain: Snippet
    var typingIsInKeybumps = false
    var secureInput = false
    private(set) var restores = 0

    init(restoreDelay: Duration = .zero) throws {
        plain = try store.add(SnippetDraft(name: "Made-up shipping", keyword: ";ship", text: "made-up shipping text"))
        try store.add(SnippetDraft(name: "Made-up key", keyword: ";key", text: "made-up-secret", isSensitive: true))
        replacer = RecordingReplacer(pasteboard: pasteboard)
        controller = KeywordExpansionController(
            snippets: store,
            monitor: monitor,
            replacer: replacer,
            pasteboard: pasteboard,
            notices: notices
        )
        controller.restoreDelay = restoreDelay
        controller.typingIsInKeybumps = { [unowned self] in typingIsInKeybumps }
        controller.secureInputEnabled = { [unowned self] in secureInput }
        controller.didRestorePasteboard = { [unowned self] in restores += 1 }
    }

    func type(_ text: String) {
        for character in text { controller.handle(.characters(String(character))) }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    func tearDown() {
        controller.update(listening: false)
        pasteboard.releaseGlobally()
    }
}

final class FakeTypingMonitor: KeyTypingMonitoring {
    var onKey: ((TypedKey) -> Void)?
    private(set) var isRunning = false
    /// Refuses to start, as macOS does without Input Monitoring.
    var refuses = false
    /// Whether another key went down after the one that completed the keyword.
    var newerKeyWentDown = false
    private(set) var newerKeyChecks = 0
    func start() -> Bool {
        isRunning = !refuses
        return isRunning
    }
    func stop() { isRunning = false }
    func keyWentDownSinceLastKey() -> Bool {
        newerKeyChecks += 1
        return newerKeyWentDown
    }
}

/// Records each step and writes pasted text to the pasteboard, as the real paste step would.
@MainActor
private final class RecordingReplacer: TextPasting {
    private let pasteboard: NSPasteboard
    private(set) var steps: [String] = []
    /// Refuses to delete, as without Accessibility.
    var fails = false
    /// Writes the pasteboard, then fails to press ⌘V.
    var pasteFails = false
    /// Fails before writing the pasteboard.
    var pasteFailsBeforeWriting = false
    var copiesWhileDeleting: String?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func deleteTyped(_ count: Int) throws {
        if fails { throw TextPasteError.accessibilityRequired }
        if let copiesWhileDeleting { pasteboard.writeText(copiesWhileDeleting) }
        steps.append("delete \(count)")
    }

    func paste(_ text: String, concealed: Bool) throws {
        if pasteFailsBeforeWriting { throw TextPasteError.pasteboardWriteFailed }
        pasteboard.writeText(text, concealed: concealed)
        if pasteFails { throw TextPasteError.keystrokeUnavailable }
        steps.append("paste \(text)" + (concealed ? " (concealed)" : ""))
    }
}

private final class RecordingExpansionNotices: PaletteNoticePresenting {
    private(set) var shown: [String] = []
    func showNotice(_ message: String, isWarning: Bool) { shown.append(message) }
}
