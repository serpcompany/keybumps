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
        #expect(fixture.replacer.replaced == [.init(count: 5, text: "made-up shipping text", concealed: false)])
        #expect(fixture.store.snippet(withID: fixture.plain.id)?.lastUsedAt != nil)
        try await fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "made-up earlier copy" }
        #expect(fixture.restores == 1, "Putting the clipboard back is kept out of Clipboard History")
    }

    @Test("A sensitive snippet expands with its Keychain text, marked concealed")
    func sensitive() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.type(";key")
        #expect(fixture.replacer.replaced == [.init(count: 4, text: "made-up-secret", concealed: true)])
    }

    @Test("Nothing expands in Keybumps' own windows or while macOS hides typing (secure input)")
    func exclusions() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.keybumpsIsFrontmost = true
        fixture.type(";ship")
        fixture.keybumpsIsFrontmost = false
        fixture.secureInput = true
        fixture.type(";ship")
        #expect(fixture.replacer.replaced.isEmpty)
    }

    @Test("Switching apps or clicking clears what was typed")
    func reset() throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.type(";sh")
        fixture.controller.handle(.reset)
        fixture.type("ip")
        #expect(fixture.replacer.replaced.isEmpty)
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

    @Test("If the keyword can't be replaced, nothing is recorded and the clipboard is left alone")
    func failure() async throws {
        let fixture = try ExpansionFixture()
        defer { fixture.tearDown() }
        fixture.replacer.fails = true
        fixture.type(";ship")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.store.snippet(withID: fixture.plain.id)?.lastUsedAt == nil)
        #expect(fixture.restores == 0)
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
        fixture.type(";sh")
        fixture.controller.update(listening: false)
        #expect(!fixture.monitor.isRunning)
        fixture.controller.update(listening: true)
        fixture.type("ip")
        #expect(fixture.replacer.replaced.isEmpty, "Stopping forgets what was typed")
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

    @Test("Replacing deletes the keyword first, then pastes")
    func replaceOrder() throws {
        var steps: [String] = []
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsExpansionOrder-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let paster = SystemTextPaster(
            pasteboard: { pasteboard },
            postCommandV: { steps.append("⌘V") },
            postBackspaces: { steps.append("delete \($0)") }
        )
        try paster.replaceTyped(4, with: "made-up text", concealed: false)
        #expect(steps == ["delete 4", "⌘V"])
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
    let replacer: RecordingReplacer
    let controller: KeywordExpansionController
    let plain: Snippet
    var keybumpsIsFrontmost = false
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
            notices: SilentNotices()
        )
        controller.restoreDelay = restoreDelay
        controller.keybumpsIsFrontmost = { [unowned self] in keybumpsIsFrontmost }
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

private final class FakeTypingMonitor: KeyTypingMonitoring {
    var onKey: ((TypedKey) -> Void)?
    private(set) var isRunning = false
    func start() -> Bool { isRunning = true; return true }
    func stop() { isRunning = false }
}

/// Records each replacement and writes its text to the pasteboard, as the real paste step would.
@MainActor
private final class RecordingReplacer: TextPasting {
    struct Replacement: Equatable {
        let count: Int
        let text: String
        let concealed: Bool
    }

    private let pasteboard: NSPasteboard
    private(set) var replaced: [Replacement] = []
    var fails = false

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func paste(_ text: String, concealed: Bool) throws {
        throw TextPasteError.unavailable
    }

    func replaceTyped(_ count: Int, with text: String, concealed: Bool) throws {
        if fails { throw TextPasteError.accessibilityRequired }
        pasteboard.writeText(text, concealed: concealed)
        replaced.append(Replacement(count: count, text: text, concealed: concealed))
    }
}

private final class SilentNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
