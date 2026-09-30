import Darwin
import Foundation
import Observation

enum SnippetStoreError: Error, Equatable {
    case invalid(SnippetDraft.Problem)
    case notFound
    /// The Keychain refused a sensitive snippet's text.
    case keychain
    /// `snippets.json` couldn't be written.
    case storage

    var message: String {
        switch self {
        case .invalid(let problem): problem.message
        case .notFound: "This snippet no longer exists."
        case .keychain: "Keybumps couldn’t save the text in the Keychain."
        case .storage: "Keybumps couldn’t save your snippets."
        }
    }
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
    /// Set when the saved file couldn't be read in full; Keybumps kept a copy under this name.
    private(set) var unreadableCopyName: String?

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

    /// The editor's starting fields for a snippet, including a sensitive snippet's text.
    func draft(for id: Snippet.ID) -> SnippetDraft? {
        guard let snippet = snippet(withID: id) else { return nil }
        return SnippetDraft(
            name: snippet.name,
            keyword: snippet.keyword ?? "",
            text: text(for: snippet) ?? "",
            isSensitive: snippet.isSensitive
        )
    }

    /// The first problem that stops `draft` from being saved over `id` (or as a new snippet).
    func problem(with draft: SnippetDraft, editing id: Snippet.ID? = nil) -> SnippetDraft.Problem? {
        draft.problem(otherKeywords: snippets.filter { $0.id != id }.compactMap(\.keyword))
    }

    @discardableResult
    func add(_ draft: SnippetDraft) throws -> Snippet {
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
            if draft.isSensitive { secrets.removeText(for: snippet.id) }
            throw error
        }
        return snippet
    }

    func update(_ id: Snippet.ID, with draft: SnippetDraft) throws {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { throw SnippetStoreError.notFound }
        if let problem = problem(with: draft, editing: id) { throw SnippetStoreError.invalid(problem) }
        let original = snippets[index]
        let originalSecret = original.isSensitive ? secrets.text(for: id) : nil
        var updated = original
        updated.name = draft.trimmedName
        updated.keyword = draft.normalizedKeyword
        updated.isSensitive = draft.isSensitive
        updated.text = draft.isSensitive ? "" : draft.text
        updated.updatedAt = now()
        if draft.isSensitive {
            do { try secrets.setText(draft.text, for: id) } catch { throw SnippetStoreError.keychain }
        }
        var next = snippets
        next[index] = updated
        do {
            try commit(next)
        } catch {
            // Put the Keychain back the way the file still describes it.
            if let originalSecret {
                try? secrets.setText(originalSecret, for: id)
            } else if draft.isSensitive {
                secrets.removeText(for: id)
            }
            throw error
        }
        // No longer sensitive: its text is in the file now, so the Keychain copy goes.
        if original.isSensitive, !draft.isSensitive { secrets.removeText(for: id) }
    }

    func delete(_ id: Snippet.ID) throws {
        guard let snippet = snippet(withID: id) else { throw SnippetStoreError.notFound }
        try commit(snippets.filter { $0.id != id })
        if snippet.isSensitive { secrets.removeText(for: id) }
    }

    /// Records a copy or paste, so the snippet comes first when the search is empty.
    func markUsed(_ id: Snippet.ID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        var next = snippets
        next[index].lastUsedAt = now()
        // Only the order depends on it, so a failed write keeps the change in memory.
        if (try? commit(next)) == nil { snippets = next }
    }

    // MARK: Storage

    private func commit(_ next: [Snippet]) throws {
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
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        let decoded = try? JSONDecoder().decode([LenientSnippet].self, from: data)
        let readable = decoded?.compactMap(\.snippet) ?? []
        snippets = readable
        // Keep whatever couldn't be read, so the next save doesn't lose it for good.
        if decoded == nil || readable.count != decoded?.count {
            unreadableCopyName = setAside(storageURL)
        }
    }

    /// Copies the file beside itself as `snippets.unreadable-<date>.json`, readable only by the user.
    private func setAside(_ url: URL) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "snippets.unreadable-\(formatter.string(from: now())).json"
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              (try? PrivateFile.write(data, to: copy, fileManager: fileManager)) != nil else { return nil }
        return name
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
