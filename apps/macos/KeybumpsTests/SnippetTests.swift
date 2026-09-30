import AppKit
import Foundation
import Security
import Testing
@testable import Keybumps

// Every snippet here is made up. Files go to temporary folders, sensitive text to an in-memory
// secret store, and copies to a named pasteboard that each test releases, so no test touches the
// owner's Application Support folder, Keychain, or clipboard.

// MARK: - Model and storage

@MainActor
@Suite("Snippets: model and storage")
struct SnippetStorageTests {
    @Test("Snippets round-trip through snippets.json, a JSON array only the user can read")
    func roundTrip() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let first = try store.add(SnippetDraft(name: "Made-up greeting", keyword: " ;hi ", text: "Hello from nowhere"))
        let second = try store.add(SnippetDraft(name: "Made-up sign-off", text: "Line one\nLine two"))

        let reloaded = folder.makeStore()
        #expect(reloaded.snippets == [first, second])
        #expect(reloaded.snippets.first?.keyword == ";hi", "Keywords are saved trimmed")
        #expect(reloaded.snippets.last?.keyword == nil)

        let data = try Data(contentsOf: folder.storageURL)
        #expect(try JSONSerialization.jsonObject(with: data) is [[String: Any]])
        #expect(try folder.permissions(of: folder.storageURL) == 0o600)
        #expect(folder.leftoverTemporaryFiles().isEmpty)
    }

    @Test("A file saved with looser permissions is replaced by one only the user can read")
    func tightensPermissions() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try Data("[]".utf8).write(to: folder.storageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.storageURL.path)

        let store = folder.makeStore()
        try store.add(SnippetDraft(name: "Made-up", text: "text"))
        #expect(try folder.permissions(of: folder.storageURL) == 0o600)
    }

    @Test("Older entries without the newer fields still load")
    func decodesMinimalEntries() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let id = UUID()
        try Data(#"[{"id":"\#(id.uuidString)","name":"Made-up","text":"made-up text"}]"#.utf8).write(to: folder.storageURL)

        let snippet = try #require(folder.makeStore().snippets.first)
        #expect(snippet.id == id)
        #expect(snippet.text == "made-up text")
        #expect(snippet.keyword == nil)
        #expect(!snippet.isSensitive)
        #expect(snippet.lastUsedAt == nil)
        #expect(snippet.updatedAt == snippet.createdAt)
    }

    @Test("An unreadable file is kept as a copy instead of being overwritten")
    func unreadableFileIsSetAside() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: folder.storageURL)

        let store = folder.makeStore()
        #expect(store.snippets.isEmpty)
        let copyName = try #require(store.unreadableCopyName)
        #expect(copyName.hasPrefix("snippets.unreadable-"))
        let copyURL = folder.url.appendingPathComponent(copyName)
        #expect(try Data(contentsOf: copyURL) == garbage)
        #expect(try folder.permissions(of: copyURL) == 0o600)

        try store.add(SnippetDraft(name: "Made-up", text: "text"))
        #expect(try Data(contentsOf: copyURL) == garbage, "Saving never touches the kept copy")
    }

    @Test("One unreadable entry is skipped, and the file is kept as a copy before the next save")
    func unreadableEntryIsSkipped() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let good = UUID()
        let json = #"[{"id":"\#(good.uuidString)","name":"Made-up","text":"kept"},{"id":"not-a-uuid"}]"#
        try Data(json.utf8).write(to: folder.storageURL)

        let store = folder.makeStore()
        #expect(store.snippets.map(\.id) == [good])
        #expect(store.unreadableCopyName != nil)
    }

    @Test("The editor's problems: a name, a keyword without spaces that no other snippet uses, and text")
    func validation() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let existing = try store.add(SnippetDraft(name: "Made-up", keyword: ";Ship", text: "text"))

        #expect(store.problem(with: SnippetDraft(name: "  ", text: "text")) == .missingName)
        #expect(store.problem(with: SnippetDraft(name: "A", keyword: "two words", text: "text")) == .keywordHasSpaces)
        #expect(store.problem(with: SnippetDraft(name: "A", keyword: ";ship", text: "text")) == .keywordInUse)
        #expect(store.problem(with: SnippetDraft(name: "A", keyword: ";ship", text: "text"), editing: existing.id) == nil)
        #expect(store.problem(with: SnippetDraft(name: "A", text: " \n\t")) == .missingText)
        #expect(store.problem(with: SnippetDraft(name: "A", keyword: "   ", text: "text")) == nil, "A blank keyword is none")
        #expect(throws: SnippetStoreError.invalid(.keywordInUse)) {
            try store.add(SnippetDraft(name: "A", keyword: ";SHIP", text: "text"))
        }
        #expect(store.snippets.count == 1)
    }

    @Test("Editing keeps the ID and creation date; deleting removes it from the file")
    func updateAndDelete() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = folder.makeStore(now: { clock })
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: "before"))

        clock = Date(timeIntervalSinceReferenceDate: 2_000)
        try store.update(snippet.id, with: SnippetDraft(name: "Renamed", keyword: ";new", text: "after"))
        let updated = try #require(folder.makeStore().snippet(withID: snippet.id))
        #expect(updated.name == "Renamed")
        #expect(updated.keyword == ";new")
        #expect(updated.text == "after")
        #expect(updated.createdAt == snippet.createdAt)
        #expect(updated.updatedAt == clock)

        try store.delete(snippet.id)
        #expect(folder.makeStore().snippets.isEmpty)
        #expect(throws: SnippetStoreError.notFound) { try store.delete(snippet.id) }
    }

    @Test("Copying or pasting records when it was used, and the order survives a relaunch")
    func markUsedPersists() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let used = Date(timeIntervalSinceReferenceDate: 5_000)
        let store = folder.makeStore(now: { used })
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: "text"))
        store.markUsed(snippet.id)
        #expect(folder.makeStore().snippet(withID: snippet.id)?.lastUsedAt == used)
    }
}

// MARK: - Sensitive snippets

@MainActor
@Suite("Snippets: sensitive text in the Keychain")
struct SensitiveSnippetTests {
    static let secret = "made-up-secret-7f3a"

    @Test("A sensitive snippet's text goes to the secret store, never into snippets.json or memory")
    func sensitiveTextStaysOutOfTheFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up key", keyword: ";key", text: Self.secret, isSensitive: true))

        #expect(snippet.text.isEmpty)
        #expect(secrets.texts[snippet.id] == Self.secret)
        #expect(store.text(for: snippet) == Self.secret)
        #expect(store.draft(for: snippet.id)?.text == Self.secret, "The editor shows it")

        let file = try String(contentsOf: folder.storageURL, encoding: .utf8)
        #expect(!file.contains(Self.secret))
        let entry = try #require((try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [[String: Any]])?.first)
        #expect(entry["text"] == nil)
        #expect(entry["isSensitive"] as? Bool == true)
        #expect(folder.makeStore(secrets: secrets).snippets.first?.text.isEmpty == true)
    }

    @Test("Turning Sensitive off moves the text into the file; turning it on moves it back")
    func togglingSensitive() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))

        try store.update(snippet.id, with: SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: false))
        #expect(secrets.texts.isEmpty)
        #expect(store.snippet(withID: snippet.id)?.text == Self.secret)
        #expect(try String(contentsOf: folder.storageURL, encoding: .utf8).contains(Self.secret))

        try store.update(snippet.id, with: SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        #expect(secrets.texts[snippet.id] == Self.secret)
        #expect(store.snippet(withID: snippet.id)?.text.isEmpty == true)
        #expect(!(try String(contentsOf: folder.storageURL, encoding: .utf8).contains(Self.secret)))
    }

    @Test("Deleting a sensitive snippet removes its Keychain item")
    func deletingRemovesTheSecret() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        try store.delete(snippet.id)
        #expect(secrets.texts.isEmpty)
    }

    @Test("When the Keychain refuses the text, nothing is saved")
    func keychainFailureSavesNothing() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        secrets.failsNextWrite = true
        #expect(throws: SnippetStoreError.keychain) {
            try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        }
        #expect(store.snippets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.storageURL.path))
    }

    @Test("Text written into the file for a sensitive snippet is ignored")
    func ignoresSensitiveTextInTheFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Made-up","text":"\#(Self.secret)","isSensitive":true}]"#
        try Data(json.utf8).write(to: folder.storageURL)
        #expect(folder.makeStore().snippets.first?.text.isEmpty == true)
    }

    @Test("Keychain items are this app's, per snippet, readable only while unlocked, and never synced")
    func keychainItemAttributes() {
        let store = KeychainSnippetSecretStore(bundleIdentifier: "com.example.made-up")
        let id = UUID()
        let query = store.query(for: id)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.example.made-up.snippets")
        #expect(query[kSecAttrAccount as String] as? String == id.uuidString)

        let attributes = store.newItemAttributes(for: id, data: Data("made-up".utf8))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrLabel as String] as? String == "Keybumps snippet", "No name or keyword in the Keychain")
        #expect(attributes[kSecValueData as String] as? Data == Data("made-up".utf8))
    }
}

// MARK: - Search

@MainActor
@Suite("Snippets: search and masking")
struct SnippetSearchTests {
    static func snippet(
        _ name: String,
        keyword: String? = nil,
        text: String = "made-up text",
        sensitive: Bool = false,
        usedAt: TimeInterval? = nil
    ) -> Snippet {
        Snippet(
            name: name, text: text, keyword: keyword, isSensitive: sensitive,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            lastUsedAt: usedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test("With no search, recently used snippets come first, then the rest by name")
    func emptySearchOrder() {
        let snippets = [
            Self.snippet("Item 10"), Self.snippet("Older", usedAt: 10), Self.snippet("Item 2"),
            Self.snippet("Newest", usedAt: 20), Self.snippet("alpha")
        ]
        #expect(SnippetSearch.results(snippets, query: "  ").map(\.name) == ["Newest", "Older", "alpha", "Item 2", "Item 10"])
        #expect(SnippetSearch.settingsResults(snippets, query: "").map(\.name) == ["alpha", "Item 2", "Item 10", "Newest", "Older"])
    }

    @Test("Keyword matches first, then name words, then names, then text")
    func matchOrder() {
        let snippets = [
            Self.snippet("Mentions it", text: "we ship on Mondays"),
            Self.snippet("Relationship notes"),
            Self.snippet("Shipping delay"),
            Self.snippet("Made-up reply", keyword: ";ship"),
            Self.snippet("Unrelated")
        ]
        #expect(SnippetSearch.results(snippets, query: "ship").map(\.name) == [
            "Made-up reply", "Shipping delay", "Relationship notes", "Mentions it"
        ])
    }

    @Test("A keyword matches with or without its leading punctuation; an exact one comes first")
    func keywordMatching() {
        let exact = Self.snippet("B", keyword: ";sh")
        let prefix = Self.snippet("A", keyword: ";ship")
        #expect(SnippetSearch.match(prefix, query: ";ship") == .keyword)
        #expect(SnippetSearch.match(prefix, query: "ship") == .keyword)
        #expect(SnippetSearch.match(prefix, query: "sh") == .keywordPrefix)
        #expect(SnippetSearch.match(prefix, query: ";s") == .keywordPrefix)
        #expect(SnippetSearch.results([prefix, exact], query: "sh").map(\.name) == ["B", "A"])
    }

    @Test("Case and accents are ignored, and every word of a query can start a word of the name")
    func foldingAndWords() {
        let snippet = Self.snippet("Café reply – refund")
        #expect(SnippetSearch.match(snippet, query: "CAFE") == .nameWords)
        #expect(SnippetSearch.match(snippet, query: "reply ref") == .nameWords)
        #expect(SnippetSearch.match(snippet, query: "ply – ref") == .name)
        #expect(SnippetSearch.match(snippet, query: "zzz") == nil)
    }

    @Test("A sensitive snippet's text is never searched or shown, but its name and keyword are")
    func sensitiveMasking() {
        let sensitive = Self.snippet("Staging key", keyword: ";stg", text: "made-up-token", sensitive: true)
        #expect(sensitive.text.isEmpty, "A sensitive snippet never holds its text")
        // Even one that somehow held its text is never searched or shown by it.
        var leaked = Self.snippet("Staging key", keyword: ";stg", text: "made-up-token")
        leaked.isSensitive = true
        #expect(SnippetSearch.match(leaked, query: "token") == nil)
        #expect(SnippetSearch.match(leaked, query: "staging") == .nameWords)
        #expect(SnippetSearch.match(leaked, query: "stg") == .keyword)

        #expect(SnippetPresentation.preview(of: leaked) == "••••••")
        #expect(!SnippetPresentation.accessibilityLabel(for: leaked).contains("token"))
        #expect(SnippetPresentation.accessibilityLabel(for: leaked) == "Staging key, keyword ;stg, sensitive, text hidden")
    }

    @Test("Rows show the text on one line")
    func previewIsOneLine() {
        let snippet = Self.snippet("Made-up", text: "Hi there,\n\n  Thanks\tfor writing.\n")
        #expect(SnippetPresentation.preview(of: snippet) == "Hi there, Thanks for writing.")
        #expect(SnippetPresentation.count(1) == "1 snippet")
        #expect(SnippetPresentation.count(8) == "8 snippets")
    }

    @Test("The tab says when Snippets is off, when there are none, and when nothing matches")
    func paletteContent() {
        let snippets = [Self.snippet("Made-up")]
        #expect(SnippetPaletteContent.resolve(snippets: snippets, query: "", isEnabled: false) == .disabled)
        #expect(SnippetPaletteContent.resolve(snippets: [], query: "", isEnabled: true) == .empty)
        #expect(SnippetPaletteContent.resolve(snippets: snippets, query: "zzz", isEnabled: true) == .noMatches)
        #expect(SnippetPaletteContent.resolve(snippets: snippets, query: "made", isEnabled: true).entries == snippets)
    }
}

// MARK: - Palette actions

@MainActor
@Suite("Snippets: copying and pasting from the palette")
struct SnippetPaletteTests {
    @Test("Return copies the text, keeps it out of Clipboard History, and records the use")
    func copyKeepsItOutOfHistory() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.copySnippet(snippet)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.pasteboard.data(forType: .concealed) == nil)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty)
        #expect(fixture.snippets.snippet(withID: snippet.id)?.lastUsedAt != nil)
        #expect(fixture.paster.pasted.isEmpty)
        #expect(fixture.notices.shown == [.init(message: "Copied to Clipboard", isWarning: false)])
    }

    @Test("A sensitive snippet's copy comes from the Keychain and is marked concealed")
    func sensitiveCopyIsConcealed() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up key", text: "made-up-token", isSensitive: true))

        fixture.palette.copySnippet(snippet)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up-token")
        #expect(fixture.pasteboard.data(forType: .concealed) != nil)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty)
    }

    @Test("Without Accessibility, ⌘Return copies instead of pasting")
    func pasteWithoutAccessibilityCopies() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { false }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.paster.pasted.isEmpty)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty)
        #expect(fixture.snippets.snippet(withID: snippet.id)?.lastUsedAt != nil)
        #expect(fixture.notices.shown == [.init(message: "Copied · Paste needs Accessibility", isWarning: true)])
    }

    @Test("With Accessibility, ⌘Return hands the text to the shared paste step")
    func pasteUsesTheSharedPasteStep() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up key", text: "made-up-token", isSensitive: true))

        fixture.palette.pasteSnippet(snippet)
        try await fixture.waitUntil { !fixture.paster.pasted.isEmpty }
        #expect(fixture.paster.pasted.map(\.text) == ["made-up-token"])
        #expect(fixture.paster.pasted.map(\.concealed) == [true])
        #expect(fixture.snippets.snippet(withID: snippet.id)?.lastUsedAt != nil)
        #expect(fixture.notices.shown.isEmpty, "A paste shows no notice")
    }

    @Test("If the paste step fails, the text is still copied")
    func failedPasteStillCopies() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        fixture.paster.fails = true
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        try await fixture.waitUntil { !fixture.notices.shown.isEmpty }
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.notices.shown == [.init(message: "Copied · Couldn’t paste", isWarning: true)])
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty)
    }

    @Test("New Snippet and Edit open the editor in Settings; Delete asks first")
    func editorAndDeletionRequests() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        var settingsOpened = 0
        fixture.palette.openSettings = { settingsOpened += 1 }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "text"))

        fixture.palette.openSnippetEditor(.new)
        #expect(fixture.snippets.editorRequest == .new)
        fixture.palette.openSnippetEditor(.edit(snippet.id))
        #expect(fixture.snippets.editorRequest == .edit(snippet.id))
        #expect(settingsOpened == 2)

        fixture.palette.requestSnippetDeletion(snippet)
        #expect(fixture.palette.state.snippetPendingDeletion == snippet)
        #expect(fixture.snippets.snippets.count == 1, "Nothing is deleted until it's confirmed")
    }

    @Test("A text write can carry nspasteboard.org's concealed marker")
    func writeTextMarksConcealed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsSnippetWrite-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeText("made-up", concealed: true))
        #expect(pasteboard.string(forType: .string) == "made-up")
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        #expect(pasteboard.writeText("plain"))
        #expect(pasteboard.data(forType: .concealed) == nil)
    }

    @Test("Snippets takes ⌘5 and the hidden-by-default Hotkeys tab moves to ⌘6")
    func tabOrdering() {
        #expect(CommandPaletteTab.allCases.suffix(2) == [.snippets, .keyboardShortcutter])
        #expect(CommandPaletteTab.snippets.shortcutLabel == "⌘5")
        #expect(CommandPaletteTab.keyboardShortcutter.shortcutLabel == "⌘6")
        let visible = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search)
        #expect(visible.map(\.shortcutLabel) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"], "No gap in the visible tabs")
        #expect(CommandPaletteTab.matchingCommandKey("5", in: visible) == .snippets)
        #expect(CommandPaletteTab.matchingCommandKey("6", in: visible) == nil)
        #expect(CommandPaletteTab.visibleTabs(showsHotkeys: true, selected: .search).last == .keyboardShortcutter)
    }
}

// MARK: - Helpers

/// A temporary folder holding one `snippets.json`.
@MainActor
private struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsSnippets-\(UUID().uuidString)", isDirectory: true)

    var storageURL: URL { url.appendingPathComponent(SnippetStore.fileName) }

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeStore(
        secrets: any SnippetSecretStoring = InMemorySnippetSecretStore(),
        now: @escaping () -> Date = Date.init
    ) -> SnippetStore {
        SnippetStore(storageURL: storageURL, secrets: secrets, now: now)
    }

    func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func leftoverTemporaryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A Command Palette over a named pasteboard, temporary folders, and a recording paste step.
@MainActor
private final class PaletteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsSnippetPalette-\(UUID().uuidString)"))
    let paster = RecordingPaster()
    let notices = RecordingNotices()
    let clipboard: ClipboardHistoryService
    let snippets: SnippetStore
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        snippets = folder.makeStore()
        let dictationHistory = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US",
                fileManager: FolderFileManager(root: root),
                history: dictationHistory,
                paster: InertTextPaster(),
                allowsSystemAccess: false
            ),
            inbox: InboxStore(persistence: NoEventPersistence()),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: snippets,
            paster: paster,
            pasteboard: pasteboard,
            notices: notices
        )
        palette.pasteDelay = .zero
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

@MainActor
private final class RecordingPaster: TextPasting {
    private(set) var pasted: [(text: String, concealed: Bool)] = []
    var fails = false

    func paste(_ text: String, concealed: Bool) throws {
        if fails { throw TextPasteError.keystrokeUnavailable }
        pasted.append((text, concealed))
    }
}

/// Records notch notices instead of drawing them.
@MainActor
private final class RecordingNotices: PaletteNoticePresenting {
    struct Notice: Equatable {
        let message: String
        let isWarning: Bool
    }

    private(set) var shown: [Notice] = []

    func showNotice(_ message: String, isWarning: Bool) {
        shown.append(Notice(message: message, isWarning: isWarning))
    }
}

/// Keeps Dictation's recovery file in the test's folder instead of Application Support.
private final class FolderFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

private struct NoEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}
