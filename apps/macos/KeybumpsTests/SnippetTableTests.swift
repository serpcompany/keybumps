import Foundation
import Security
import Testing
@testable import Keybumps

// Settings › Snippets › All Snippets: sorting by column, selecting several snippets, and the bulk
// Delete and Mark as Sensitive / Not Sensitive behind them. Every snippet here is made up. Files go
// to temporary folders and sensitive text to an in-memory secret store, so no test touches the
// owner's Application Support folder or Keychain.

// MARK: - Sorting

@MainActor
@Suite("Snippets table: sorting by column")
struct SnippetTableSortTests {
    static func snippet(
        _ name: String,
        keyword: String? = nil,
        text: String = "made-up text",
        sensitive: Bool = false,
        createdAt: TimeInterval = 0
    ) -> Snippet {
        Snippet(
            name: name, text: text, keyword: keyword, isSensitive: sensitive,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }

    static func sorted(_ snippets: [Snippet], by column: SnippetTableSort.Column, _ order: SortOrder = .forward) -> [String] {
        SnippetTableSort.sorted(snippets, by: [SnippetTableSort(column: column, order: order)]).map(\.name)
    }

    @Test("Name sorts as Finder does, ignoring case and accents, and the second click reverses it")
    func sortsByName() {
        let snippets = [
            Self.snippet("banana"), Self.snippet("Item 10"), Self.snippet("apple"), Self.snippet("Item 2"),
        ]
        #expect(Self.sorted(snippets, by: .name) == ["apple", "banana", "Item 2", "Item 10"])
        #expect(Self.sorted(snippets, by: .name, .reverse) == ["Item 10", "Item 2", "banana", "apple"])

        // Names that differ only by case or accents are the same name, so the older one comes first.
        let older = Self.snippet("Résumé", createdAt: 0)
        let newer = Self.snippet("resume", createdAt: 1)
        #expect(Self.sorted([newer, older], by: .name) == ["Résumé", "resume"])
        #expect(Self.sorted([older, newer], by: .name, .reverse) == ["resume", "Résumé"])
    }

    @Test("Keyword ignores case and accents, and snippets without one stay last, by name, both ways")
    func sortsByKeyword() {
        let snippets = [
            Self.snippet("No keyword B"), Self.snippet("Second", keyword: ";b"), Self.snippet("No keyword A"),
            Self.snippet("First", keyword: ";A"), Self.snippet("Third", keyword: ";ç"),
        ]
        #expect(Self.sorted(snippets, by: .keyword) == ["First", "Second", "Third", "No keyword A", "No keyword B"])
        #expect(Self.sorted(snippets, by: .keyword, .reverse) == ["Third", "Second", "First", "No keyword A", "No keyword B"])
    }

    @Test("Snippet sorts by what the column shows: sensitive rows by their mask, together, by name")
    func sortsByShownText() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        try store.add(SnippetDraft(name: "Zeta", text: "zebra crossing"))
        try store.add(SnippetDraft(name: "Hidden B", text: "made-up-secret-b", isSensitive: true))
        try store.add(SnippetDraft(name: "Alpha", text: "Apple\n  pie"))
        try store.add(SnippetDraft(name: "Hidden A", text: "made-up-secret-a", isSensitive: true))
        try store.add(SnippetDraft(name: "Middle", text: "Éclair"))
        let readsBefore = secrets.reads

        for order in [SortOrder.forward, .reverse] {
            let names = Self.sorted(store.snippets, by: .snippet, order)
            let plain = names.filter { !$0.hasPrefix("Hidden") }
            #expect(plain == (order == .forward ? ["Alpha", "Middle", "Zeta"] : ["Zeta", "Middle", "Alpha"]))
            let hidden = try #require(names.firstIndex(of: "Hidden A"))
            let other = try #require(names.firstIndex(of: "Hidden B"))
            #expect(abs(hidden - other) == 1, "Sensitive rows stay together")
            #expect((hidden < other) == (order == .forward), "…and sort by name among themselves")
        }
        #expect(secrets.reads == readsBefore, "No sensitive text was read to sort")
    }

    @Test("With no column chosen, the table keeps its own order")
    func noColumnKeepsTheOrder() {
        let snippets = [Self.snippet("b"), Self.snippet("c"), Self.snippet("a")]
        #expect(SnippetTableSort.sorted(snippets, by: []).map(\.name) == ["b", "c", "a"])
    }
}

// MARK: - Selection

@MainActor
@Suite("Snippets table: selecting several snippets")
struct SnippetTableSelectionTests {
    let plain = SnippetTableSortTests.snippet("Plain")
    let other = SnippetTableSortTests.snippet("Other plain")
    let hidden = SnippetTableSortTests.snippet("Hidden", sensitive: true)

    @Test("Edit… is offered for exactly one snippet, and the count says how many are selected")
    func editAndCount() {
        let rows = [plain, other, hidden]
        #expect(SnippetTableSelection([], in: rows).editableID == nil)
        #expect(SnippetTableSelection([plain.id], in: rows).editableID == plain.id)
        #expect(SnippetTableSelection([plain.id, other.id], in: rows).editableID == nil)

        #expect(SnippetTableSelection.countText(total: 66, selected: 0) == "66 snippets")
        #expect(SnippetTableSelection.countText(total: 66, selected: 1) == "66 snippets")
        #expect(SnippetTableSelection.countText(total: 66, selected: 5) == "5 selected")
        #expect(SnippetTableSelection.countText(total: 1, selected: 0) == "1 snippet")
    }

    @Test("Only selected rows the search shows are acted on, in the table's order")
    func onlyShownRowsCount() {
        let selection = SnippetTableSelection([hidden.id, plain.id, other.id], in: [other, plain])
        #expect(selection.snippets.map(\.id) == [other.id, plain.id])
        #expect(selection.ids == [other.id, plain.id])
        #expect(SnippetTableSelection([hidden.id], in: [plain]).isEmpty)
    }

    @Test("The Delete confirmation names one snippet, or counts several")
    func deletionText() {
        let one = SnippetTableSelection([plain.id], in: [plain, other])
        #expect(one.deletionTitle == "Delete this snippet?")
        #expect(one.deletionMessage == "“Plain” will be removed from this Mac.")
        let two = SnippetTableSelection([plain.id, other.id], in: [plain, other])
        #expect(two.deletionTitle == "Delete 2 snippets?")
        #expect(two.deletionMessage == "They’ll be removed from this Mac.")
    }

    @Test("Mark as Sensitive and Mark as Not Sensitive are offered for whichever applies")
    func markActions() {
        let rows = [plain, other, hidden]
        let allPlain = SnippetTableSelection([plain.id, other.id], in: rows)
        #expect(allPlain.canMarkSensitive && !allPlain.canMarkNotSensitive)
        let mixed = SnippetTableSelection([plain.id, hidden.id], in: rows)
        #expect(mixed.canMarkSensitive && mixed.canMarkNotSensitive)
        let allHidden = SnippetTableSelection([hidden.id], in: rows)
        #expect(!allHidden.canMarkSensitive && allHidden.canMarkNotSensitive)
    }
}

// MARK: - Bulk changes

@MainActor
@Suite("Snippets table: deleting and marking several at once")
struct SnippetBulkChangeTests {
    static let secretA = "made-up-secret-a"
    static let secretB = "made-up-secret-b"

    /// A library of two sensitive and two plain snippets, with every save counted.
    @MainActor
    struct Library {
        let folder = TemporaryFolder()
        let secrets = InMemorySnippetSecretStore()
        let files = SaveCountingFileManager()
        let store: SnippetStore
        let hiddenA: Snippet
        let hiddenB: Snippet
        let plainA: Snippet
        let plainB: Snippet

        init() throws {
            store = folder.makeStore(secrets: secrets, fileManager: files)
            hiddenA = try store.add(SnippetDraft(name: "Hidden A", text: SnippetBulkChangeTests.secretA, isSensitive: true))
            plainA = try store.add(SnippetDraft(name: "Plain A", text: "made-up plain a"))
            hiddenB = try store.add(SnippetDraft(name: "Hidden B", text: SnippetBulkChangeTests.secretB, isSensitive: true))
            plainB = try store.add(SnippetDraft(name: "Plain B", text: "made-up plain b"))
        }

        var fileText: String {
            (try? String(contentsOf: folder.storageURL, encoding: .utf8)) ?? ""
        }

        func reloaded() -> SnippetStore {
            folder.makeStore(secrets: secrets)
        }
    }

    @Test("Deleting several saves once and removes the Keychain items of only those snippets")
    func bulkDelete() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let savesBefore = library.files.saves

        try library.store.delete([library.hiddenA.id, library.plainA.id])

        #expect(library.files.saves == savesBefore + 1, "One save")
        #expect(library.store.snippets.map(\.id) == [library.hiddenB.id, library.plainB.id])
        #expect(library.reloaded().snippets.map(\.id) == [library.hiddenB.id, library.plainB.id])
        #expect(library.secrets.texts == [library.hiddenB.id: Self.secretB])
        #expect(library.secrets.removals == 1)
    }

    @Test("If the Keychain won't remove one of them, none is deleted and every item is put back")
    func bulkDeleteKeychainFailure() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let fileBefore = library.fileText
        // The library's order is Hidden A, Plain A, Hidden B: Hidden A's item goes first, then Hidden B's fails.
        library.secrets.refusedIDs = [library.hiddenB.id]

        #expect(throws: SnippetStoreError.keychain) {
            try library.store.delete([library.hiddenA.id, library.plainA.id, library.hiddenB.id])
        }
        #expect(library.store.snippets.count == 4)
        #expect(library.fileText == fileBefore)
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
    }

    @Test("If the file can't be written, nothing is deleted and every Keychain item is put back")
    func bulkDeleteFileFailure() throws {
        let library = try Library()
        defer { library.folder.remove() }
        try library.folder.setPermissions(0o500, of: library.folder.url)
        defer { try? library.folder.setPermissions(0o700, of: library.folder.url) }

        #expect(throws: SnippetStoreError.storage) {
            try library.store.delete([library.hiddenA.id, library.hiddenB.id, library.plainB.id])
        }
        #expect(library.store.snippets.count == 4)
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
    }

    @Test("Marking several as Sensitive saves once and moves only their text into the Keychain")
    func bulkMarkSensitive() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let savesBefore = library.files.saves

        try library.store.setSensitive(true, for: [library.plainA.id, library.plainB.id, library.hiddenA.id])

        #expect(library.files.saves == savesBefore + 1, "One save")
        let reloaded = library.reloaded()
        for store in [library.store, reloaded] {
            #expect(store.snippets.allSatisfy { $0.isSensitive })
            #expect(store.snippet(withID: library.plainA.id)?.updatedAt != library.plainA.updatedAt)
            #expect(store.snippet(withID: library.hiddenA.id)?.updatedAt == library.hiddenA.updatedAt, "Already sensitive: unchanged")
        }
        #expect(library.secrets.texts[library.plainA.id] == "made-up plain a")
        #expect(library.secrets.texts[library.plainB.id] == "made-up plain b")
        #expect(library.secrets.texts[library.hiddenA.id] == Self.secretA)
        #expect(!library.fileText.contains("made-up plain"), "Their text left the file")
    }

    @Test("Marking several as Not Sensitive saves once, moves their text into the file, and removes their items")
    func bulkMarkNotSensitive() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let savesBefore = library.files.saves

        try library.store.setSensitive(false, for: [library.hiddenA.id, library.hiddenB.id, library.plainA.id])

        #expect(library.files.saves == savesBefore + 1, "One save")
        let reloaded = library.reloaded()
        for store in [library.store, reloaded] {
            #expect(!store.snippets.contains { $0.isSensitive })
            #expect(store.snippet(withID: library.hiddenA.id)?.text == Self.secretA)
            #expect(store.snippet(withID: library.hiddenB.id)?.text == Self.secretB)
            #expect(store.snippet(withID: library.plainA.id)?.updatedAt == library.plainA.updatedAt, "Already plain: unchanged")
        }
        #expect(library.secrets.texts.isEmpty)
        #expect(library.secrets.removals == 2)
    }

    @Test("If the Keychain refuses one partway, nothing changes and every item is put back as it was")
    func bulkMarkKeychainFailure() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let fileBefore = library.fileText

        // Plain A's text goes into the Keychain first, then Plain B's is refused.
        library.secrets.refusedIDs = [library.plainB.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(true, for: [library.plainA.id, library.plainB.id])
        }
        // Hidden A's item goes first, then Hidden B's removal is refused.
        library.secrets.refusedIDs = [library.hiddenB.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(false, for: [library.hiddenA.id, library.hiddenB.id])
        }

        #expect(library.fileText == fileBefore)
        #expect(library.store.snippets == library.reloaded().snippets)
        #expect(library.store.snippets.filter(\.isSensitive).map(\.id) == [library.hiddenA.id, library.hiddenB.id])
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
    }

    @Test("Marking Not Sensitive needs every text first: one the Keychain can't give back changes nothing")
    func bulkMarkNotSensitiveNeedsEveryText() throws {
        let library = try Library()
        defer { library.folder.remove() }
        library.secrets.removeTextForTesting(library.hiddenB.id)

        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(false, for: [library.hiddenA.id, library.hiddenB.id])
        }
        #expect(library.secrets.removals == 0)
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA])
        #expect(library.store.snippets.filter(\.isSensitive).count == 2)
    }

    @Test("If the file can't be written, every Keychain item is put back as it was")
    func bulkMarkFileFailure() throws {
        let library = try Library()
        defer { library.folder.remove() }
        try library.folder.setPermissions(0o500, of: library.folder.url)
        defer { try? library.folder.setPermissions(0o700, of: library.folder.url) }

        #expect(throws: SnippetStoreError.storage) {
            try library.store.setSensitive(true, for: [library.plainA.id, library.plainB.id])
        }
        #expect(throws: SnippetStoreError.storage) {
            try library.store.setSensitive(false, for: [library.hiddenA.id, library.hiddenB.id])
        }
        #expect(library.store.snippets.filter(\.isSensitive).map(\.id) == [library.hiddenA.id, library.hiddenB.id])
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
    }

    @Test("A plain snippet's leftover Keychain item is put back as it was when a change fails")
    func leftoverItemIsPutBack() throws {
        let library = try Library()
        defer { library.folder.remove() }
        // An item a plain snippet still has, for example from a library restored from an older file.
        let leftover = "made-up-leftover"
        try library.secrets.setText(leftover, for: library.plainA.id)

        library.secrets.refusedIDs = [library.hiddenB.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.delete([library.plainA.id, library.hiddenB.id])
        }
        #expect(library.secrets.texts[library.plainA.id] == leftover, "Delete's rollback")

        library.secrets.refusedIDs = [library.plainB.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(true, for: [library.plainA.id, library.plainB.id])
        }
        #expect(library.secrets.texts[library.plainA.id] == leftover, "Mark as Sensitive's rollback")

        library.secrets.refusedIDs = []
        try library.folder.setPermissions(0o500, of: library.folder.url)
        defer { try? library.folder.setPermissions(0o700, of: library.folder.url) }
        #expect(throws: SnippetStoreError.storage) { try library.store.delete([library.plainA.id]) }
        #expect(library.secrets.texts[library.plainA.id] == leftover, "A failed save's rollback")
        #expect(library.store.snippets.count == 4)
    }

    @Test("Two entries with the same ID (only a hand-edited file has them) are left alone")
    func duplicateIDs() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let id = UUID()
        try Data(#"[{"id":"\#(id.uuidString)","name":"First","text":"made-up one"},{"id":"\#(id.uuidString)","name":"Second","text":"made-up two"}]"#.utf8)
            .write(to: folder.storageURL)
        let fileBefore = try Data(contentsOf: folder.storageURL)
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        #expect(store.snippets.count == 2)

        #expect(throws: SnippetStoreError.sharedID) { try store.setSensitive(true, for: [id]) }
        #expect(throws: SnippetStoreError.sharedID) { try store.setSensitive(false, for: [id]) }
        #expect(store.snippets.map(\.text) == ["made-up one", "made-up two"], "No text is lost")
        #expect(try Data(contentsOf: folder.storageURL) == fileBefore)
        #expect(secrets.texts.isEmpty)

        // Deleting is well defined: both entries go, as before, and their one item is read once.
        let readsBefore = secrets.reads
        try store.delete(id)
        #expect(store.snippets.isEmpty)
        #expect(secrets.reads == readsBefore + 1)
    }

    @Test("An item the Keychain won't read stops Mark as Sensitive or Not Sensitive before anything changes")
    func unreadableItemStopsMarking() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let fileBefore = library.fileText
        // As a locked Keychain, or a denied access prompt, would refuse to read it.
        library.secrets.unreadableIDs = [library.hiddenA.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(false, for: [library.hiddenA.id, library.hiddenB.id])
        }
        library.secrets.unreadableIDs = [library.plainA.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.setSensitive(true, for: [library.plainA.id])
        }

        #expect(library.secrets.removals == 0)
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
        #expect(library.fileText == fileBefore)
    }

    @Test("Delete still deletes a snippet whose item can't be read, removing that item last")
    func unreadableItemIsDeletedLast() throws {
        let library = try Library()
        defer { library.folder.remove() }
        library.secrets.unreadableIDs = [library.hiddenA.id]

        // Hidden B's removal is refused before Hidden A's item, which couldn't be put back, is touched.
        library.secrets.refusedIDs = [library.hiddenB.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.delete([library.hiddenA.id, library.hiddenB.id])
        }
        #expect(library.secrets.texts == [library.hiddenA.id: Self.secretA, library.hiddenB.id: Self.secretB])
        #expect(library.store.snippets.count == 4)

        library.secrets.refusedIDs = []
        try library.store.delete([library.hiddenA.id, library.hiddenB.id])
        #expect(library.secrets.texts.isEmpty)
        #expect(library.store.snippets.map(\.id) == [library.plainA.id, library.plainB.id])
    }

    @Test("Saving new text over a sensitive snippet whose item can't be read changes nothing")
    func editorRefusesAnUnreadableSecret() throws {
        let library = try Library()
        defer { library.folder.remove() }
        library.secrets.unreadableIDs = [library.hiddenA.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.update(library.hiddenA.id, with: SnippetDraft(name: "Hidden A", text: "made-up new text", isSensitive: true))
        }
        #expect(library.secrets.texts[library.hiddenA.id] == Self.secretA)
        #expect(library.store.text(for: library.hiddenA) == nil, "Copy and paste get nothing while it can't be read")
    }

    @Test("The editor's Sensitive switch also puts back a leftover item when the save fails")
    func editorPutsBackALeftoverItem() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let leftover = "made-up-leftover"
        try library.secrets.setText(leftover, for: library.plainA.id)
        try library.folder.setPermissions(0o500, of: library.folder.url)
        defer { try? library.folder.setPermissions(0o700, of: library.folder.url) }

        #expect(throws: SnippetStoreError.storage) {
            try library.store.update(library.plainA.id, with: SnippetDraft(name: "Plain A", text: "made-up plain a", isSensitive: true))
        }
        #expect(library.secrets.texts[library.plainA.id] == leftover)
        #expect(library.store.snippet(withID: library.plainA.id)?.isSensitive == false)

        // A leftover it can't read couldn't be put back, so the editor refuses before overwriting it.
        try library.folder.setPermissions(0o700, of: library.folder.url)
        library.secrets.unreadableIDs = [library.plainA.id]
        #expect(throws: SnippetStoreError.keychain) {
            try library.store.update(library.plainA.id, with: SnippetDraft(name: "Plain A", text: "made-up plain a", isSensitive: true))
        }
        #expect(library.secrets.texts[library.plainA.id] == leftover)
    }

    @Test("Nothing to change saves nothing, and snippets that no longer exist are reported")
    func nothingToChange() throws {
        let library = try Library()
        defer { library.folder.remove() }
        let savesBefore = library.files.saves

        try library.store.setSensitive(true, for: [library.hiddenA.id])
        try library.store.setSensitive(false, for: [library.plainA.id])
        #expect(library.files.saves == savesBefore)
        #expect(throws: SnippetStoreError.notFound) { try library.store.delete([UUID()]) }
        #expect(throws: SnippetStoreError.notFound) { try library.store.setSensitive(true, for: [UUID()]) }
        #expect(library.store.snippets.count == 4)
    }

    @Test("While the saved snippets can't be read, bulk changes are refused")
    func readOnlyRefusesBulkChanges() throws {
        let library = try Library()
        defer { library.folder.remove() }
        try library.folder.setPermissions(0o000, of: library.folder.storageURL)
        let store = library.reloaded()
        #expect(store.libraryState == .readOnly)

        #expect(throws: SnippetStoreError.readOnly) { try store.delete([library.plainA.id]) }
        #expect(throws: SnippetStoreError.readOnly) { try store.setSensitive(true, for: [library.plainA.id]) }
        #expect(library.secrets.texts.count == 2)
    }
}

// MARK: - Reading the Keychain

@Suite("Snippets: telling a missing Keychain item from a failed read")
struct SnippetKeychainReadTests {
    @Test("No item reads as none, an item as its text, and any other status throws")
    func statusMapping() throws {
        #expect(try KeychainSnippetSecretStore.text(status: errSecItemNotFound, result: nil) == nil)
        #expect(try KeychainSnippetSecretStore.text(status: errSecSuccess, result: Data("made-up".utf8) as NSData) == "made-up")
        #expect(try KeychainSnippetSecretStore.text(status: errSecSuccess, result: Data([0xFF, 0xFE]) as NSData) == nil, "Not text")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            #expect(throws: SnippetSecretError.keychain(status)) {
                try KeychainSnippetSecretStore.text(status: status, result: nil)
            }
        }
    }

    @Test("Copy, paste, and the editor's Show get nothing when the read fails")
    func failedReadIsNoText() throws {
        let id = UUID()
        let secrets = InMemorySnippetSecretStore([id: "made-up-secret"])
        secrets.unreadableIDs = [id]
        #expect(secrets.text(for: id) == nil)
        #expect(throws: SnippetSecretError.self) { try secrets.storedText(for: id) }
    }
}

/// Counts saves: `PrivateFile.write` makes sure the folder exists before every write.
final class SaveCountingFileManager: FileManager {
    private(set) var saves = 0

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        saves += 1
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
