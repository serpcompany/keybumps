import Darwin
import Foundation
import Observation

enum SnippetStoreError: Error, Equatable {
    case invalid(SnippetDraft.Problem)
    case notFound
    /// The Keychain refused to save, read, or remove a sensitive snippet's text.
    case keychain
    /// `snippets.json` couldn't be written.
    case storage
    /// `snippets.json` couldn't be read, so nothing is saved until it can be (`SnippetLibraryState.readOnly`).
    case readOnly

    var message: String {
        switch self {
        case .invalid(let problem): problem.message
        case .notFound: "This snippet no longer exists."
        case .keychain: "The Keychain didn’t allow it. Nothing was changed."
        case .storage: "Keybumps couldn’t save your snippets."
        case .readOnly: "Keybumps can’t read your saved snippets, so it won’t save changes until it can. See Settings › Snippets."
        }
    }
}

/// Whether the saved snippets were read, and so whether saving is safe.
enum SnippetLibraryState: Equatable {
    case ready
    /// Some or all of the file couldn't be decoded. A copy of it was kept under this name first,
    /// so saving (which drops what couldn't be read) is safe.
    case recovered(copyName: String)
    /// The file exists but couldn't be read, or a copy of an undecodable file couldn't be kept.
    /// Nothing is saved until it can be read (`reload()`) or the user sets it aside (`startOver()`).
    case readOnly
}

/// The user's snippets: one JSON array in `snippets.json` in Keybumps' Application Support folder,
/// readable only by the user (0600), never synced. A sensitive snippet's text is kept in the
/// Keychain (`SnippetSecretStoring`) instead of the file. Names, keywords, and text are never logged.
@MainActor
@Observable
final class SnippetStore {
    static let fileName = "snippets.json"

    /// Every snippet, in the order they were created.
    private(set) var snippets: [Snippet] = []
    /// The editor Settings shows, if any. The palette sets it to open the editor in Settings.
    var editorRequest: SnippetEditorRequest?
    private(set) var libraryState: SnippetLibraryState = .ready

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let secrets: any SnippetSecretStoring
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let now: () -> Date

    /// - Parameter storageURL: the JSON file, or nil to keep snippets in memory only.
    init(
        storageURL: URL?,
        secrets: any SnippetSecretStoring,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.secrets = secrets
        self.fileManager = fileManager
        self.now = now
        load()
    }

    /// The app's store: `snippets.json` in Application Support and the Keychain. Under unit tests
    /// it lives only in memory, so tests never touch the owner's snippets or Keychain.
    static func makeDefault() -> SnippetStore {
        if UnitTestHost.isActive {
            return SnippetStore(storageURL: nil, secrets: InMemorySnippetSecretStore())
        }
        return SnippetStore(
            storageURL: ProductPaths.keybumps().applicationSupport.appendingPathComponent(fileName),
            secrets: KeychainSnippetSecretStore()
        )
    }

    func snippet(withID id: Snippet.ID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    /// The text to copy or paste: from the Keychain for a sensitive snippet (nil if it can't be read).
    func text(for snippet: Snippet) -> String? {
        snippet.isSensitive ? secrets.text(for: snippet.id) : snippet.text
    }

    /// The editor's starting fields for a snippet. A sensitive snippet's text is left empty: the
    /// editor reads it with `text(for:)` only when the user asks to show it.
    func draft(for id: Snippet.ID) -> SnippetDraft? {
        guard let snippet = snippet(withID: id) else { return nil }
        return SnippetDraft(
            name: snippet.name,
            keyword: snippet.keyword ?? "",
            text: snippet.isSensitive ? "" : snippet.text,
            isSensitive: snippet.isSensitive
        )
    }

    /// The first problem that stops `draft` from being saved over `id` (or as a new snippet).
    /// `keepsText` means the editor kept a sensitive snippet's saved text hidden, so the draft has none.
    func problem(with draft: SnippetDraft, editing id: Snippet.ID? = nil, keepsText: Bool = false) -> SnippetDraft.Problem? {
        var checked = draft
        if keepsText { checked.text = SnippetPresentation.maskedText }
        return checked.problem(otherKeywords: snippets.filter { $0.id != id }.compactMap(\.keyword))
    }

    @discardableResult
    func add(_ draft: SnippetDraft) throws -> Snippet {
        try requireWritable()
        if let problem = problem(with: draft) { throw SnippetStoreError.invalid(problem) }
        let snippet = Snippet(
            name: draft.trimmedName,
            text: draft.text,
            keyword: draft.normalizedKeyword,
            isSensitive: draft.isSensitive,
            createdAt: now()
        )
        if draft.isSensitive {
            do { try secrets.setText(draft.text, for: snippet.id) } catch { throw SnippetStoreError.keychain }
        }
        do {
            try commit(snippets + [snippet])
        } catch {
            if draft.isSensitive { try? secrets.removeText(for: snippet.id) }
            throw error
        }
        return snippet
    }

    /// Saves the editor's fields over a snippet. With `keepsText`, a sensitive snippet keeps the
    /// text already in the Keychain, which the editor never showed.
    func update(_ id: Snippet.ID, with draft: SnippetDraft, keepsText: Bool = false) throws {
        try requireWritable()
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { throw SnippetStoreError.notFound }
        if let problem = problem(with: draft, editing: id, keepsText: keepsText) { throw SnippetStoreError.invalid(problem) }
        let original = snippets[index]
        let originalSecret = original.isSensitive ? secrets.text(for: id) : nil
        if original.isSensitive, originalSecret == nil, keepsText || !draft.isSensitive {
            // The saved text is needed and the Keychain won't give it back.
            throw SnippetStoreError.keychain
        }
        let text = keepsText ? (originalSecret ?? original.text) : draft.text

        var updated = original
        updated.name = draft.trimmedName
        updated.keyword = draft.normalizedKeyword
        updated.isSensitive = draft.isSensitive
        updated.text = draft.isSensitive ? "" : text
        updated.updatedAt = now()

        // The Keychain changes first, and is put back if the file can't be written.
        if draft.isSensitive {
            if text != originalSecret {
                do { try secrets.setText(text, for: id) } catch { throw SnippetStoreError.keychain }
            }
        } else if original.isSensitive {
            // Sensitive off: the text moves into the file, so its Keychain item goes.
            do { try secrets.removeText(for: id) } catch { throw SnippetStoreError.keychain }
        }
        var next = snippets
        next[index] = updated
        do {
            try commit(next)
        } catch {
            if let originalSecret {
                try? secrets.setText(originalSecret, for: id)
            } else if draft.isSensitive, !original.isSensitive {
                try? secrets.removeText(for: id)
            }
            throw error
        }
    }

    /// Deletes a snippet and its Keychain item, whether or not it's sensitive now, so no text outlives
    /// it. If the item can't be removed, nothing is deleted.
    func delete(_ id: Snippet.ID) throws {
        try requireWritable()
        guard let snippet = snippet(withID: id) else { throw SnippetStoreError.notFound }
        let secret = snippet.isSensitive ? secrets.text(for: id) : nil
        do { try secrets.removeText(for: id) } catch { throw SnippetStoreError.keychain }
        do {
            try commit(snippets.filter { $0.id != id })
        } catch {
            if let secret { try? secrets.setText(secret, for: id) }
            throw error
        }
    }

    /// Records a copy or paste, so the snippet comes first when the search is empty.
    func markUsed(_ id: Snippet.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        var next = snippets
        next[index].lastUsedAt = now()
        // Only the order depends on it, so an unsaved change is kept in memory.
        if libraryState == .readOnly || (try? commit(next)) == nil { snippets = next }
    }

    /// Reads the file again, for example after its permissions were fixed.
    func reload() {
        snippets = []
        libraryState = .ready
        load()
    }

    /// Moves a file that can't be read aside, unread, as `snippets.unreadable-<date>.json`, and
    /// starts an empty library that saves normally.
    func startOver() throws {
        guard libraryState == .readOnly, let storageURL else { return }
        let name = Self.unreadableCopyName(at: now())
        let copy = storageURL.deletingLastPathComponent().appendingPathComponent(name)
        if fileManager.fileExists(atPath: storageURL.path) {
            guard rename(storageURL.path, copy.path) == 0 else { throw SnippetStoreError.storage }
        }
        snippets = []
        libraryState = .recovered(copyName: name)
    }

    // MARK: Storage

    private func requireWritable() throws {
        if libraryState == .readOnly { throw SnippetStoreError.readOnly }
    }

    private func commit(_ next: [Snippet]) throws {
        try requireWritable()
        if let storageURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                try PrivateFile.write(try encoder.encode(next), to: storageURL, fileManager: fileManager)
            } catch {
                throw SnippetStoreError.storage
            }
        }
        snippets = next
    }

    private func load() {
        guard let storageURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch where Self.isMissingFile(error) {
            // No file yet: an empty library. Keychain items are left alone until a file is read.
            return
        } catch {
            // It exists but can't be read. Treating it as empty would let the next save replace it.
            libraryState = .readOnly
            return
        }
        let decoded = try? JSONDecoder().decode([LenientSnippet].self, from: data)
        let readable = decoded?.compactMap(\.snippet) ?? []
        guard let decoded, readable.count == decoded.count else {
            // Keep what couldn't be read before anything can overwrite it; if that fails, save nothing.
            if let copyName = keepCopy(of: data, beside: storageURL) {
                snippets = readable
                libraryState = .recovered(copyName: copyName)
            } else {
                libraryState = .readOnly
            }
            return
        }
        snippets = readable
        removeUnusedSecrets()
    }

    /// Removes Keychain items that no sensitive snippet uses: text left by a snippet deleted in
    /// another build, or by a removal that failed. Runs only when the whole file was read.
    private func removeUnusedSecrets() {
        guard storageURL != nil, libraryState == .ready, let stored = secrets.storedIDs() else { return }
        let inUse = Set(snippets.filter(\.isSensitive).map(\.id))
        for id in stored.subtracting(inUse) {
            try? secrets.removeText(for: id)
        }
    }

    /// Writes `data` beside the file as `snippets.unreadable-<date>.json`, readable only by the user,
    /// unless an identical copy is already there. Returns the copy's name, or nil if it couldn't be kept.
    private func keepCopy(of data: Data, beside url: URL) -> String? {
        let directory = url.deletingLastPathComponent()
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing.sorted() where name.hasPrefix("snippets.unreadable-") && name.hasSuffix(".json") {
            if (try? Data(contentsOf: directory.appendingPathComponent(name))) == data { return name }
        }
        let name = Self.unreadableCopyName(at: now())
        guard (try? PrivateFile.write(data, to: directory.appendingPathComponent(name), fileManager: fileManager)) != nil else {
            return nil
        }
        return name
    }

    private static func unreadableCopyName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "snippets.unreadable-\(formatter.string(from: date)).json"
    }

    /// Only a missing file means "no snippets yet"; any other read error keeps the file untouched.
    static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
        }
        return false
    }
}

/// One array element that decodes to nil instead of failing the whole file.
private struct LenientSnippet: Decodable {
    let snippet: Snippet?

    init(from decoder: Decoder) throws {
        snippet = try? Snippet(from: decoder)
    }
}

/// Writes files only the user can read: a new file is created with mode 0600, written in full, and
/// then renamed over the destination, so a reader never sees a partial file.
enum PrivateFile {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
