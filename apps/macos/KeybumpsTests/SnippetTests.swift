import AppKit
import Carbon.HIToolbox
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

    @Test("An undecodable file is kept as a copy before anything overwrites it, and only once")
    func undecodableFileIsCopiedAside() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: folder.storageURL)

        let store = folder.makeStore()
        #expect(store.snippets.isEmpty)
        guard case .recovered(let copyName) = store.libraryState else {
            Issue.record("Expected a kept copy, got \(store.libraryState)")
            return
        }
        #expect(copyName.hasPrefix("snippets.unreadable-"))
        let copyURL = folder.url.appendingPathComponent(copyName)
        #expect(try Data(contentsOf: copyURL) == garbage)
        #expect(try folder.permissions(of: copyURL) == 0o600)

        // Another launch before any save reuses the identical copy instead of making another.
        #expect(folder.makeStore().libraryState == .recovered(copyName: copyName))
        #expect(folder.unreadableCopies() == [copyName])

        try store.add(SnippetDraft(name: "Made-up", text: "text"))
        #expect(try Data(contentsOf: copyURL) == garbage, "Saving never touches the kept copy")
        #expect(folder.makeStore().libraryState == .ready)
    }

    @Test("A file that exists but can't be read is never overwritten; Try Again reads it once it can")
    func unreadableFileMakesTheStoreReadOnly() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let seeded = folder.makeStore()
        let kept = try seeded.add(SnippetDraft(name: "Made-up", text: "text"))
        let original = try Data(contentsOf: folder.storageURL)
        try folder.setPermissions(0o000, of: folder.storageURL)

        let store = folder.makeStore()
        #expect(store.libraryState == .readOnly)
        #expect(store.snippets.isEmpty)
        #expect(throws: SnippetStoreError.readOnly) { try store.add(SnippetDraft(name: "New", text: "text")) }
        store.markUsed(kept.id)
        #expect(folder.unreadableCopies().isEmpty)

        try folder.setPermissions(0o600, of: folder.storageURL)
        #expect(try Data(contentsOf: folder.storageURL) == original, "The file is untouched")
        store.reload()
        #expect(store.libraryState == .ready)
        #expect(store.snippets.map(\.id) == [kept.id])
    }

    @Test("While the saved snippets can't be read, Settings offers no way to add or change one")
    func settingsOffersChangesOnlyWhileWritable() throws {
        #expect(SnippetLibraryState.ready.isWritable)
        #expect(SnippetLibraryState.recovered(copyName: "snippets.unreadable-made-up.json").isWritable)
        #expect(!SnippetLibraryState.readOnly.isWritable)

        // Settings turns off +, −, and Edit… exactly when the store would refuse the save.
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try folder.makeStore().add(SnippetDraft(name: "Made-up", text: "text"))
        try folder.setPermissions(0o000, of: folder.storageURL)
        let store = folder.makeStore()
        #expect(!store.libraryState.isWritable)
        #expect(throws: SnippetStoreError.readOnly) { try store.add(SnippetDraft(name: "New", text: "text")) }
    }

    @Test("Start Over renames an unreadable file aside, unread, and keeps its sensitive text across launches")
    func startOverKeepsTheUnreadableFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        // One Keychain across every launch, as on a real Mac.
        let secrets = InMemorySnippetSecretStore()
        let sensitive = try folder.makeStore(secrets: secrets)
            .add(SnippetDraft(name: "Made-up key", text: "made-up-secret", isSensitive: true))
        let original = try Data(contentsOf: folder.storageURL)
        try folder.setPermissions(0o000, of: folder.storageURL)

        let store = folder.makeStore(secrets: secrets)
        try store.startOver()
        guard case .recovered(let copyName) = store.libraryState else {
            Issue.record("Expected the file to be set aside, got \(store.libraryState)")
            return
        }
        try store.add(SnippetDraft(name: "New", text: "text"))
        let relaunched = folder.makeStore(secrets: secrets)
        #expect(relaunched.snippets.map(\.name) == ["New"])
        #expect(secrets.texts[sensitive.id] == "made-up-secret", "The kept file's secret survives the new library")
        #expect(secrets.removals == 0)

        let copyURL = folder.url.appendingPathComponent(copyName)
        try folder.setPermissions(0o600, of: copyURL)
        #expect(try Data(contentsOf: copyURL) == original)
    }

    @Test("Start Over with nothing left to set aside mentions no kept copy")
    func startOverWithoutAFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try folder.makeStore().add(SnippetDraft(name: "Made-up", text: "text"))
        try folder.setPermissions(0o000, of: folder.storageURL)
        let store = folder.makeStore()
        #expect(store.libraryState == .readOnly)
        try folder.setPermissions(0o600, of: folder.storageURL)
        try FileManager.default.removeItem(at: folder.storageURL)

        try store.startOver()
        #expect(store.libraryState == .ready)
        #expect(folder.unreadableCopies().isEmpty)
    }

    @Test("If the copy of an undecodable file can't be written, nothing is saved over it")
    func failedCopyBlocksSaving() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: folder.storageURL)
        try folder.setPermissions(0o500, of: folder.url)

        let store = folder.makeStore()
        #expect(store.libraryState == .readOnly)
        #expect(throws: SnippetStoreError.readOnly) { try store.add(SnippetDraft(name: "New", text: "text")) }
        try folder.setPermissions(0o700, of: folder.url)
        #expect(try Data(contentsOf: folder.storageURL) == garbage)
    }

    @Test("Only a missing file is an empty library")
    func missingFileIsEmpty() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        #expect(store.libraryState == .ready)
        #expect(store.snippets.isEmpty)
        #expect(SnippetStore.isMissingFile(CocoaError(.fileReadNoSuchFile)))
        #expect(!SnippetStore.isMissingFile(CocoaError(.fileReadNoPermission)))
        #expect(!SnippetStore.isMissingFile(CocoaError(.fileReadCorruptFile)))
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
        if case .recovered = store.libraryState {} else { Issue.record("Expected a kept copy") }
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
        #expect(store.draft(for: snippet.id)?.text.isEmpty == true, "The editor reads it only on Show")

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

    @Test("Keychain items are this app's, one per snippet, not synchronizable, with a generic label")
    func keychainItemAttributes() {
        let store = KeychainSnippetSecretStore(bundleIdentifier: "com.example.made-up")
        let id = UUID()
        let query = store.query(for: id)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.example.made-up.snippets")
        #expect(query[kSecAttrAccount as String] as? String == id.uuidString)

        let attributes = store.newItemAttributes(for: id, data: Data("made-up".utf8))
        // Items go to the login keychain; without the data protection keychain an accessibility
        // class would have no effect, so none is claimed.
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attributes[kSecAttrAccessible as String] == nil)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrLabel as String] as? String == "Keybumps snippet", "No name or keyword in the Keychain")
        #expect(attributes[kSecValueData as String] as? Data == Data("made-up".utf8))
    }
}

// MARK: - No sensitive text outlives its snippet

@MainActor
@Suite("Snippets: no sensitive text outlives its snippet")
struct SnippetKeychainCleanupTests {
    static let secret = "made-up-secret-7f3a"

    @Test("Deleting removes the snippet's Keychain item even when it isn't sensitive now")
    func deleteAlwaysRemovesTheItem() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: "text"))
        try secrets.setText(Self.secret, for: snippet.id)
        try store.delete(snippet.id)
        #expect(secrets.texts.isEmpty)
    }

    @Test("If the Keychain won't remove the item, the snippet isn't deleted")
    func failedRemovalKeepsTheSnippet() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        secrets.failsNextRemoval = true
        #expect(throws: SnippetStoreError.keychain) { try store.delete(snippet.id) }
        #expect(folder.makeStore(secrets: secrets).snippet(withID: snippet.id) != nil)
        #expect(secrets.texts[snippet.id] == Self.secret)
    }

    @Test("Turning Sensitive off fails as a whole if the Keychain won't remove the item")
    func failedRemovalKeepsItSensitive() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        secrets.failsNextRemoval = true
        #expect(throws: SnippetStoreError.keychain) {
            try store.update(snippet.id, with: SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: false))
        }
        #expect(store.snippet(withID: snippet.id)?.isSensitive == true)
        #expect(secrets.texts[snippet.id] == Self.secret)
        #expect(!(try String(contentsOf: folder.storageURL, encoding: .utf8).contains(Self.secret)))
    }

    @Test("If the file can't be written after the Keychain changed, the Keychain is put back")
    func keychainIsRestoredWhenTheFileFails() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        try folder.setPermissions(0o500, of: folder.url)
        defer { try? folder.setPermissions(0o700, of: folder.url) }

        #expect(throws: SnippetStoreError.storage) {
            try store.update(snippet.id, with: SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: false))
        }
        #expect(secrets.texts[snippet.id] == Self.secret)
        #expect(throws: SnippetStoreError.storage) { try store.delete(snippet.id) }
        #expect(secrets.texts[snippet.id] == Self.secret)
        #expect(store.snippet(withID: snippet.id)?.isSensitive == true)
    }

    @Test("A rename-only save of a sensitive snippet never reads or needs its text")
    func renameOnlySaveLeavesTheKeychainAlone() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        let hidden = try #require(store.draft(for: snippet.id))
        #expect(store.problem(with: hidden, editing: snippet.id, keepsText: true) == nil)

        var renamed = hidden
        renamed.name = "Renamed"
        renamed.keyword = ";new"
        let readsBefore = secrets.reads
        try store.update(snippet.id, with: renamed, keepsText: true)
        #expect(secrets.reads == readsBefore, "The Keychain wasn't read")
        #expect(store.snippet(withID: snippet.id)?.name == "Renamed")
        #expect(secrets.texts[snippet.id] == Self.secret)

        // Even with the text gone from the Keychain, a rename still saves and blanks nothing.
        secrets.removeTextForTesting(snippet.id)
        renamed.name = "Renamed again"
        try store.update(snippet.id, with: renamed, keepsText: true)
        #expect(folder.makeStore(secrets: secrets).snippet(withID: snippet.id)?.name == "Renamed again")
        #expect(secrets.removals == 0)
    }

    @Test("Turning Sensitive off without showing the text needs it, and fails cleanly without it")
    func sensitiveOffNeedsTheText() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let snippet = try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        secrets.removeTextForTesting(snippet.id)
        #expect(throws: SnippetStoreError.keychain) {
            try store.update(snippet.id, with: SnippetDraft(name: "Made-up", isSensitive: false), keepsText: true)
        }
        #expect(store.snippet(withID: snippet.id)?.isSensitive == true)
    }

    @Test("If adding a sensitive snippet can't write the file, its new Keychain item is removed")
    func addRollsBackTheKeychain() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        try folder.setPermissions(0o500, of: folder.url)
        defer { try? folder.setPermissions(0o700, of: folder.url) }

        #expect(throws: SnippetStoreError.storage) {
            try store.add(SnippetDraft(name: "Made-up", text: Self.secret, isSensitive: true))
        }
        #expect(secrets.texts.isEmpty)
        #expect(store.snippets.isEmpty)
    }

    @Test("No secret is ever deleted because the file doesn't mention it, across launches")
    func noSecretIsDeletedByInference() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        // One Keychain across every launch and both "builds", as on a real Mac.
        let secrets = InMemorySnippetSecretStore()

        // A corrupt file, recovered, then saved over: the kept copy's secret survives.
        let first = try folder.makeStore(secrets: secrets)
            .add(SnippetDraft(name: "In the corrupt file", text: "made-up-secret-1", isSensitive: true))
        var corrupt = try Data(contentsOf: folder.storageURL)
        corrupt.append(Data("}".utf8))
        try corrupt.write(to: folder.storageURL)
        let recovered = folder.makeStore(secrets: secrets)
        if case .recovered = recovered.libraryState {} else { Issue.record("Expected a kept copy") }
        try recovered.add(SnippetDraft(name: "After recovery", text: "text"))
        _ = folder.makeStore(secrets: secrets)
        _ = folder.makeStore(secrets: secrets)
        #expect(secrets.texts[first.id] == "made-up-secret-1")

        // Last writer wins: one build adds a sensitive snippet, another saves its older list.
        let installed = folder.makeStore(secrets: secrets)
        let debug = folder.makeStore(secrets: secrets)
        let added = try installed.add(SnippetDraft(name: "Added by one build", text: "made-up-secret-2", isSensitive: true))
        try debug.add(SnippetDraft(name: "Saved by the other", text: "text"))
        let relaunched = folder.makeStore(secrets: secrets)
        #expect(relaunched.snippet(withID: added.id) == nil, "The older list won")
        #expect(secrets.texts[added.id] == "made-up-secret-2", "…but its secret wasn't deleted")

        #expect(secrets.removals == 0, "Nothing was removed without the user deleting it")
    }

    @Test("Only deleting or turning Sensitive off removes an item")
    func onlyExplicitActionsRemoveItems() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let deleted = try store.add(SnippetDraft(name: "Deleted", text: "made-up-1", isSensitive: true))
        let unhidden = try store.add(SnippetDraft(name: "Unhidden", text: "made-up-2", isSensitive: true))
        let kept = try store.add(SnippetDraft(name: "Kept", text: "made-up-3", isSensitive: true))

        try store.delete(deleted.id)
        try store.update(unhidden.id, with: SnippetDraft(name: "Unhidden", text: "made-up-2", isSensitive: false))
        _ = folder.makeStore(secrets: secrets)
        #expect(Set(secrets.texts.keys) == [kept.id])
        #expect(secrets.removals == 2)
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
        // An unreadable library never looks empty.
        #expect(SnippetPaletteContent.resolve(snippets: [], query: "", isEnabled: true, libraryState: .readOnly) == .unreadable)
        #expect(SnippetPaletteContent.resolve(snippets: [], query: "", isEnabled: false, libraryState: .readOnly) == .disabled)
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

    @Test("Without Accessibility, ⌘Return copies instead of pasting and offers the setup")
    func pasteWithoutAccessibilityCopies() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { false }
        var offers = 0
        fixture.palette.offerPasteSetup = { offers += 1 }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.paster.pasted.isEmpty)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty)
        #expect(fixture.snippets.snippet(withID: snippet.id)?.lastUsedAt != nil)
        #expect(fixture.notices.shown == [.init(message: "Copied · Paste needs Accessibility", isWarning: true)])
        #expect(offers == 1)
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
        fixture.palette.openSettings = { section in #expect(section == .snippets); settingsOpened += 1 }
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

    @Test("⌘Return with Keybumps itself in front copies, and says there's no app to paste into")
    func pasteWithKeybumpsInFrontCopies() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        fixture.palette.frontmostApp = { PasteTarget(processIdentifier: 1, isKeybumps: true) }
        fixture.palette.rememberPasteTarget()
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        #expect(fixture.paster.pasted.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.notices.shown == [.init(message: "Copied · No app to paste into", isWarning: true)])
    }

    @Test("If another app comes to the front during the wait, ⌘Return copies instead")
    func pasteIntoAChangedAppCopies() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        fixture.palette.pasteDelay = .milliseconds(30)
        fixture.palette.rememberPasteTarget()
        fixture.palette.frontmostApp = { PasteTarget(processIdentifier: 99, isKeybumps: false) }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        try await fixture.waitUntil { !fixture.notices.shown.isEmpty }
        #expect(fixture.paster.pasted.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.notices.shown == [.init(message: "Copied · Couldn’t paste", isWarning: true)])
    }

    @Test("Opening the palette again during the wait cancels the paste")
    func reopeningCancelsThePaste() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        fixture.palette.pasteDelay = .milliseconds(30)
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))

        fixture.palette.pasteSnippet(snippet)
        fixture.palette.rememberPasteTarget()
        try await fixture.waitUntil { !fixture.notices.shown.isEmpty }
        #expect(fixture.paster.pasted.isEmpty)
        #expect(fixture.notices.shown == [.init(message: "Copied · Couldn’t paste", isWarning: true)])
    }

    @Test("The paste route: another app, still in front, with the palette closed and Accessibility")
    func pasteRoute() {
        let app = PasteTarget(processIdentifier: 42, isKeybumps: false)
        let keybumps = PasteTarget(processIdentifier: 7, isKeybumps: true)
        #expect(SnippetPasteRoute.beforeClosing(canPaste: true, target: app) == .paste)
        #expect(SnippetPasteRoute.beforeClosing(canPaste: false, target: app) == .copy(.needsAccessibility))
        #expect(SnippetPasteRoute.beforeClosing(canPaste: true, target: keybumps) == .copy(.noOtherApp))
        #expect(SnippetPasteRoute.beforeClosing(canPaste: false, target: nil) == .copy(.noOtherApp))
        #expect(SnippetPasteRoute.canPasteNow(into: app, frontmost: app, paletteIsVisible: false, isStillWanted: true))
        #expect(!SnippetPasteRoute.canPasteNow(into: app, frontmost: keybumps, paletteIsVisible: false, isStillWanted: true))
        #expect(!SnippetPasteRoute.canPasteNow(into: app, frontmost: nil, paletteIsVisible: false, isStillWanted: true))
        #expect(!SnippetPasteRoute.canPasteNow(into: app, frontmost: app, paletteIsVisible: true, isStillWanted: true))
        #expect(!SnippetPasteRoute.canPasteNow(into: app, frontmost: app, paletteIsVisible: false, isStillWanted: false))
    }

    @Test("The shared paste step writes, keeps the write out of Clipboard History, then presses ⌘V")
    func systemPasteStepOrder() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let paster = try #require(
            AppModel.makeTextPaster(clipboard: fixture.clipboard, allowsSystemAccess: true, isUnitTestHost: false)
                as? SystemTextPaster
        )
        var steps: [String] = []
        var recording = paster
        recording.pasteboard = { fixture.pasteboard }
        let suppress = paster.didWritePasteboard
        recording.didWritePasteboard = {
            steps.append("write:\(fixture.pasteboard.string(forType: .string) ?? "")")
            suppress()
        }
        recording.postCommandV = { steps.append("⌘V") }

        try recording.paste("made-up text", concealed: true)
        #expect(steps == ["write:made-up text", "⌘V"])
        #expect(fixture.pasteboard.data(forType: .concealed) != nil)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "The shell's paste step keeps its write out of Clipboard History")

        // Without that suppression, the same write would be recorded.
        fixture.pasteboard.writeText("made-up copy")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.map(\.text) == ["made-up copy"])
    }

    @Test("Unit tests and sessions without system access get the inert paste step")
    func pasteStepIsInertInTests() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        #expect(AppModel.makeTextPaster(clipboard: fixture.clipboard, allowsSystemAccess: true) is InertTextPaster)
        #expect(AppModel.makeTextPaster(clipboard: fixture.clipboard, allowsSystemAccess: false, isUnitTestHost: false) is InertTextPaster)
    }

    @Test("Quick Search finds the Snippets command by name or keyword, and it goes to the tab or, while off, Settings")
    func capabilityCommand() {
        let command = QuickSearchCommand.capability(.snippets)
        #expect(command.title == "Snippets")
        #expect(command.match("snippets") == QuickSearchCommand.Match.name)
        #expect(command.match("snippet") == QuickSearchCommand.Match.keyword)
        #expect(command.match("snip") == QuickSearchCommand.Match.keyword)
        #expect(command.match("sni") == QuickSearchCommand.Match.prefix)
        #expect(command.destination(enabledCapabilities: [.snippets]) == .paletteTab(.snippets))
        #expect(command.destination(enabledCapabilities: []) == .settings(.snippets))
    }

    @Test("A text write can carry nspasteboard.org's concealed marker")
    func writeTextMarksConcealed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsSnippetWrite-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeText("made-up", concealed: true))
        #expect(pasteboard.string(forType: .string) == "made-up")
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        // One item carries both, so the text never appears without the marker.
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.types.contains(.string) == true)
        #expect(items.first?.types.contains(.concealed) == true)
        #expect(pasteboard.writeText("plain"))
        #expect(pasteboard.data(forType: .concealed) == nil)
        #expect(pasteboard.pasteboardItems?.count == 1)
        // A concealed write stays on this Mac, so Universal Clipboard doesn't send it to other devices.
        #expect(NSPasteboard.contentsOptions(concealed: true) == .currentHostOnly)
        #expect(NSPasteboard.contentsOptions(concealed: false) == [])
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

// MARK: - Palette keys

@MainActor
@Suite("Snippets: palette keys")
struct SnippetPaletteKeyTests {
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
    static let escapeKey = key(kVK_Escape, "\u{1b}")
    static let downKey = key(kVK_DownArrow)

    @Test("Return copies the selected snippet and ⌘Return pastes it")
    func returnAndCommandReturn() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))
        fixture.palette.state.select(.snippets)

        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.notices.shown.map(\.message) == ["Copied to Clipboard"])

        #expect(fixture.palette.handleKeyDown(Self.commandReturn) == nil)
        try await fixture.waitUntil { !fixture.paster.pasted.isEmpty }
        #expect(fixture.paster.pasted.map(\.text) == ["made-up text"])
    }

    @Test("⌘N makes a new snippet and ⌘E edits the selected one, in Settings")
    func newAndEdit() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        var settingsOpened = 0
        fixture.palette.openSettings = { section in #expect(section == .snippets); settingsOpened += 1 }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "text"))
        fixture.palette.state.select(.snippets)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_N, "n", command: true)) == nil)
        #expect(fixture.snippets.editorRequest == .new)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_E, "e", command: true)) == nil)
        #expect(fixture.snippets.editorRequest == .edit(snippet.id))
        #expect(settingsOpened == 2)
    }

    @Test("⌘N and ⌘E do nothing while Snippets is off")
    func newAndEditNeedSnippetsOn() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        var settingsOpened = 0
        fixture.palette.openSettings = { section in #expect(section == .snippets); settingsOpened += 1 }
        try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "text"))
        fixture.preferences.setCapability(.snippets, enabled: false)
        fixture.palette.state.select(.snippets)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_N, "n", command: true)) == nil)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_E, "e", command: true)) == nil)
        #expect(fixture.snippets.editorRequest == nil)
        #expect(settingsOpened == 0)
    }

    @Test("Delete asks first, and while the alert shows the palette leaves its keys alone")
    func deleteAsksAndTheAlertKeepsItsKeys() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "text"))
        fixture.palette.state.select(.snippets)

        #expect(fixture.palette.handleKeyDown(Self.deleteKey) == nil)
        #expect(fixture.palette.state.snippetPendingDeletion == snippet)
        #expect(fixture.snippets.snippets.count == 1)

        let passedOn = fixture.palette.handleKeyDown(Self.returnKey)
        #expect(passedOn != nil, "Return goes to the alert")
        #expect(fixture.pasteboard.string(forType: .string) == nil, "Nothing was copied")
    }

    @Test("Opening the palette while the Delete alert shows gives the palette its keys back")
    func openingThePaletteEndsTheDeleteAlert() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        try fixture.snippets.add(SnippetDraft(name: "Made-up", text: "made-up text"))
        fixture.palette.state.select(.snippets)
        #expect(fixture.palette.handleKeyDown(Self.deleteKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.escapeKey) != nil, "Escape goes to the alert")

        // A hot key or a Dock click opens another tab: what `show(_:)` runs, with no panel on screen.
        fixture.palette.selectOnOpening(.clipboard)
        #expect(fixture.palette.state.snippetPendingDeletion == nil)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_5, "5", command: true)) == nil)
        #expect(fixture.palette.state.tab == .snippets)

        // Opening the same tab again drops the alert too.
        #expect(fixture.palette.handleKeyDown(Self.deleteKey) == nil)
        fixture.palette.selectOnOpening(.snippets)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.snippets.snippets.count == 1, "Nothing was deleted")
    }

    @Test("A new search starts on its top match, so Return copies that, not the row highlighted before")
    func searchStartsOnTheTopMatch() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        try fixture.snippets.add(SnippetDraft(name: "Made-up reply", keyword: ";ship", text: "made-up reply"))
        try fixture.snippets.add(SnippetDraft(name: "Mentions it", text: "we ship on Mondays"))
        try fixture.snippets.add(SnippetDraft(name: "Shipping delay", text: "made-up delay"))
        fixture.palette.state.select(.snippets)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.handleKeyDown(Self.downKey) == nil)
        #expect(fixture.palette.state.selection == 2, "Shipping delay, by name")

        // "ship" ranks the keyword match first and the text match last, where the old row now points.
        fixture.palette.state.historyQuery = "ship"
        #expect(fixture.palette.state.selection == 0)
        #expect(fixture.palette.handleKeyDown(Self.returnKey) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up reply")
    }

    @Test("While the library can't be read, ⌘N and New Snippet open the Snippets page instead of the editor")
    func unreadableLibraryOpensSettings() throws {
        let fixture = PaletteFixture(unreadableLibrary: true)
        defer { fixture.tearDown() }
        var settingsOpened = 0
        fixture.palette.openSettings = { section in #expect(section == .snippets); settingsOpened += 1 }
        #expect(fixture.snippets.libraryState == .readOnly)
        fixture.palette.state.select(.snippets)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_N, "n", command: true)) == nil)
        #expect(fixture.snippets.editorRequest == nil)
        #expect(settingsOpened == 1)
    }

    @Test("Snippets flags an unreadable library in Settings, and nothing else")
    func attentionForAnUnreadableLibrary() throws {
        let readable = PaletteFixture()
        defer { readable.tearDown() }
        let unreadable = PaletteFixture(unreadableLibrary: true)
        defer { unreadable.tearDown() }
        #expect(readable.module().attentionCount(readable.context(enabled: [.snippets])) == 0)
        #expect(readable.module().attentionCount(readable.context(enabled: [.snippets], granted: false)) == 0,
                "Paste's optional Accessibility is never flagged")
        let module = unreadable.module()
        #expect(module.attentionCount(unreadable.context(enabled: [.snippets])) == 1)
        #expect(module.attentionCount(unreadable.context(enabled: [])) == 0)
    }

    @Test("Snippets listens for keywords only while it, the switch, and both permissions are on")
    func expansionFollowsTheModule() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let monitor = FakeTypingMonitor()
        let module = fixture.module(monitor: monitor)

        module.apply(fixture.context(enabled: [.snippets]))
        #expect(!monitor.isRunning, "The switch is off by default")
        fixture.preferences.expandsSnippetKeywords = true
        module.apply(fixture.context(enabled: [.snippets]))
        #expect(monitor.isRunning)
        module.permissionsDidRefresh(fixture.context(enabled: [.snippets], granted: false))
        #expect(!monitor.isRunning, "A permission was taken away")
        module.permissionsDidRefresh(fixture.context(enabled: [.snippets]))
        #expect(monitor.isRunning)
        module.apply(fixture.context(enabled: []))
        #expect(!monitor.isRunning, "Snippets off, or the license locked")
        module.apply(fixture.context(enabled: [.snippets]))
        module.deactivate(fixture.context(enabled: [.snippets]))
        #expect(!monitor.isRunning)
    }

    @Test("With keyword expansion on, Snippets flags each permission it still needs")
    func attentionForExpansionPermissions() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.preferences.expandsSnippetKeywords = true
        let module = fixture.module()
        #expect(module.attentionCount(fixture.context(enabled: [.snippets])) == 0)
        let denied = fixture.context(enabled: [.snippets], granted: false)
        #expect(SnippetsModule.missingExpansionPermissions(denied) == [.inputMonitoring, .accessibility])
        #expect(module.attentionCount(denied) == 2)
        #expect(module.attentionCount(fixture.context(enabled: [], granted: false)) == 0, "Not while Snippets is off")
        fixture.preferences.expandsSnippetKeywords = false
        #expect(module.attentionCount(denied) == 0)
    }

    @Test("⌘5 selects Snippets; ⌘6 does nothing while the Hotkeys tab is hidden")
    func tabKeys() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.state.select(.search)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_5, "5", command: true)) == nil)
        #expect(fixture.palette.state.tab == .snippets)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_ANSI_6, "6", command: true)) != nil)
        #expect(fixture.palette.state.tab == .snippets)
    }
}

@MainActor
@Suite("Snippets: in Quick Search")
struct SnippetQuickSearchTests {
    @Test("Quick Search lists a snippet by keyword: Return copies it and ⌘Return pastes it")
    func copiesAndPastes() async throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        fixture.palette.canPaste = { true }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up reply", keyword: ";reply", text: "made-up text"))
        fixture.palette.state.select(.search)

        fixture.search.query = "reply"
        #expect(fixture.search.items.first == .snippet(snippet))
        #expect(fixture.palette.handleKeyDown(SnippetPaletteKeyTests.returnKey) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up text")
        #expect(fixture.notices.shown.map(\.message) == ["Copied to Clipboard"])
        #expect(fixture.snippets.snippet(withID: snippet.id)?.lastUsedAt != nil, "The use is recorded")
        // …as a snippet's use, never as a Recent Item or Quick Search's learned usage.
        #expect(fixture.search.displayedRecentItems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.url.appendingPathComponent("recent-items.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.url.appendingPathComponent("application-usage.json").path))

        fixture.palette.state.select(.search)
        fixture.search.query = ";reply"
        #expect(fixture.palette.handleKeyDown(SnippetPaletteKeyTests.commandReturn) == nil)
        try await fixture.waitUntil { !fixture.paster.pasted.isEmpty }
        #expect(fixture.paster.pasted.map(\.text) == ["made-up text"])
    }

    @Test("The footer names the highlighted result's actions only while there's a query")
    func footerFollowsTheQuery() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up reply", keyword: ";reply", text: "made-up text"))
        fixture.search.query = "reply"
        #expect(fixture.search.highlightedItem(at: 0) == .snippet(snippet))
        #expect(fixture.search.highlightedItem(at: 5) == nil)
        fixture.search.query = "  "
        #expect(fixture.search.highlightedItem(at: 0) == nil, "Recent Items show; their actions are the tab's")
        // Even if a late Spotlight update refilled the results after the query was cleared.
        #expect(QuickSearchModel.highlightedItem(in: [.snippet(snippet)], query: "  ", selection: 0) == nil)
        #expect(QuickSearchModel.highlightedItem(in: [.snippet(snippet)], query: "reply", selection: 0) == .snippet(snippet))
    }

    @Test("Quick Search lists no snippets while Snippets is off, and finds them again when it's on")
    func onlyWhileOn() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let snippet = try fixture.snippets.add(SnippetDraft(name: "Made-up reply", keyword: ";reply", text: "made-up text"))

        fixture.preferences.setCapability(.snippets, enabled: false)
        fixture.search.query = "reply"
        #expect(!fixture.search.items.contains(.snippet(snippet)))

        fixture.preferences.setCapability(.snippets, enabled: true)
        fixture.search.query = "repl"
        #expect(fixture.search.items.contains(.snippet(snippet)))
    }
}

// MARK: - Plain text entry

@MainActor
@Suite("Snippets: text is saved exactly as typed")
struct SnippetPlainTextTests {
    @Test("The Snippet field has smart quotes, dashes, replacement, and correction off")
    func editorSubstitutionIsOff() {
        let textView = PlainTextEditor.makeTextView()
        #expect(!textView.isRichText)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.smartInsertDeleteEnabled)

        // Typed quotes and dashes stay as typed.
        textView.insertText("git commit -m \"x\" --amend", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.string == "git commit -m \"x\" --amend")
    }

    @Test("The Keyword field's shared field editor is put back exactly as it was")
    func fieldEditorIsRestored() {
        let editor = NSTextView()
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        let before = PlainTextInput.Settings(of: editor)
        PlainTextInput.configure(editor)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        before.restore(to: editor)
        #expect(PlainTextInput.Settings(of: editor) == before)
    }
}

// MARK: - Helpers

/// A temporary folder holding one `snippets.json`.
@MainActor
struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsSnippets-\(UUID().uuidString)", isDirectory: true)

    var storageURL: URL { url.appendingPathComponent(SnippetStore.fileName) }

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeStore(
        secrets: any SnippetSecretStoring = InMemorySnippetSecretStore(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) -> SnippetStore {
        SnippetStore(storageURL: storageURL, secrets: secrets, fileManager: fileManager, now: now)
    }

    func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func setPermissions(_ mode: Int, of file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    func unreadableCopies() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasPrefix("snippets.unreadable-") }
            .sorted()
    }

    func leftoverTemporaryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    /// Restores permissions a test took away, then deletes the folder.
    func remove() {
        try? setPermissions(0o700, of: url)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            try? setPermissions(0o600, of: url.appendingPathComponent(name))
        }
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
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let search: QuickSearchModel
    let palette: CommandPaletteController
    /// Another app, in front when the palette opened and still in front.
    static let otherApp = PasteTarget(processIdentifier: 4242, isKeybumps: false)

    init(unreadableLibrary: Bool = false) {
        let root = folder.url
        if unreadableLibrary {
            try? Data("[]".utf8).write(to: folder.storageURL)
            try? folder.setPermissions(0o000, of: folder.storageURL)
        }
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        snippets = folder.makeStore()
        search = QuickSearchModel.forTests(in: root)
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
            preferences: preferences,
            snippets: snippets,
            paster: paster,
            pasteboard: pasteboard,
            notices: notices,
            search: search
        )
        palette.pasteDelay = .zero
        palette.frontmostApp = { Self.otherApp }
        palette.rememberPasteTarget()
    }

    /// What the shell hands a module, with fakes that grant every permission.
    /// The Snippets module, with keyword expansion that never listens to the keyboard or posts keys.
    func module(monitor: any KeyTypingMonitoring = InertKeyTypingMonitor()) -> SnippetsModule {
        SnippetsModule(
            palette: palette,
            snippets: snippets,
            expansion: KeywordExpansionController(snippets: snippets, monitor: monitor, replacer: InertTextPaster())
        )
    }

    func context(enabled: Set<Capability>, granted: Bool = true) -> CapabilityContext {
        let permissions = PermissionCoordinator(
            accessibilityTrusted: { granted },
            inputMonitoringAuthorized: { granted },
            microphoneAuthorizationStatus: { .authorized },
            speechAuthorizationStatus: { .authorized },
            screenRecordingAuthorized: { true },
            requestScreenRecording: {},
            openSettings: { _ in }
        )
        return CapabilityContext(
            enabledCapabilities: enabled,
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: NoHotKeys()),
            permissions: permissions,
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        )
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

/// Registers no global hot keys.
@MainActor
private final class NoHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
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

