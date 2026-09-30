import Compression
import Foundation
import Testing
@testable import Keybumps

// Every export here is written by the test from made-up snippets, into a temporary folder. The
// store keeps sensitive text in an in-memory secret store, so no test reads a real Alfred export
// or touches the owner's Application Support folder or Keychain.

// MARK: - Importing

@MainActor
@Suite("Snippets: import from Alfred")
struct SnippetImportTests {
    @Test("Name, keyword, and text carry over as plain snippets, in one save, with Alfred's uid as the ID")
    func importsEveryField() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let export = try folder.write(ZipFixture(entries: [
            .alfred(uid: Uid.greeting, name: "Made-up greeting", keyword: ";hi", snippet: "Hello from nowhere"),
            .alfred(uid: Uid.signOff, name: "Made-up sign-off", keyword: "", snippet: "Line one\nLine two", method: .deflated),
            // Alfred's placeholders stay literal text, and extra keys are ignored.
            .alfred(uid: Uid.placeholder, name: " Made-up placeholder ", keyword: "ph", snippet: "Hi {clipboard} on {date}",
                    extra: ["dontautoexpand": true, "madeUpFutureKey": ["nested": 1]], method: .deflated),
        ]))

        let alert = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(alert == SnippetImportAlert(title: "Imported 3 snippets", message: "To hide a snippet’s text, edit it and turn on Sensitive."))

        let expected: [(uid: String, name: String, keyword: String?, text: String)] = [
            (Uid.greeting, "Made-up greeting", ";hi", "Hello from nowhere"),
            (Uid.signOff, "Made-up sign-off", nil, "Line one\nLine two"),
            (Uid.placeholder, "Made-up placeholder", "ph", "Hi {clipboard} on {date}"),
        ]
        for reloaded in [store, folder.makeStore(secrets: secrets)] {
            #expect(reloaded.snippets.map(\.id) == expected.compactMap { UUID(uuidString: $0.uid) })
            #expect(reloaded.snippets.map(\.name) == expected.map { $0.name })
            #expect(reloaded.snippets.map(\.keyword) == expected.map { $0.keyword })
            #expect(reloaded.snippets.map(\.text) == expected.map { $0.text })
            #expect(reloaded.snippets.allSatisfy { !$0.isSensitive }, "Imported snippets are plain")
        }
        #expect(secrets.texts.isEmpty && secrets.reads == 0 && secrets.removals == 0, "The Keychain isn't touched")
        // The only file written is snippets.json, beside the export in the test's folder.
        #expect(folder.contents() == [SnippetStore.fileName, export.lastPathComponent].sorted())
        #expect(try folder.permissions(of: folder.storageURL) == 0o600)
    }

    @Test("The collection's keyword prefix and suffix wrap every keyword; an empty keyword stays none")
    func appliesPrefixAndSuffix() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let export = try folder.write(ZipFixture(entries: [
            .infoPlist(prefix: ";", suffix: "!", method: .deflated),
            .alfred(uid: Uid.greeting, name: "Made-up greeting", keyword: "hi", snippet: "Hello"),
            .alfred(uid: Uid.signOff, name: "Made-up sign-off", keyword: "", snippet: "Bye"),
        ]))

        _ = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(store.snippets.map(\.keyword) == [";hi!", nil])

        // Empty affixes change nothing.
        let plain = try AlfredSnippetImport.batch(fromArchive: ZipFixture(entries: [
            .infoPlist(prefix: "", suffix: ""),
            .alfred(uid: Uid.greeting, name: "Made-up", keyword: "hi", snippet: "Hello"),
        ]).archive())
        #expect(plain.snippets.map(\.keyword) == ["hi"])
    }

    @Test("A keyword with spaces, or one already in use (ignoring case), is dropped and the snippet imported without it")
    func dropsKeywordsThatCantCarryOver() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        try store.add(SnippetDraft(name: "Made-up existing", keyword: ";Ship", text: "Already here"))
        let export = try folder.write(ZipFixture(entries: [
            .infoPlist(prefix: ";", suffix: ""),
            .alfred(uid: Uid.greeting, name: "Clashes with an existing one", keyword: "SHIP", snippet: "one"),
            .alfred(uid: Uid.signOff, name: "First with its keyword", keyword: "dup", snippet: "two"),
            .alfred(uid: Uid.placeholder, name: "Second with it", keyword: "Dup", snippet: "three"),
            .alfred(uid: Uid.spaces, name: "Has spaces", keyword: "two words", snippet: "four"),
            .alfred(uid: Uid.fine, name: "Keeps its keyword", keyword: "ok", snippet: "five"),
        ]))

        let alert = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(alert.title == "Imported 5 snippets")
        #expect(alert.message.hasPrefix("3 were imported without their keywords, because they have spaces or other snippets use them."))
        #expect(store.snippets.count == 6, "Every snippet is imported")
        #expect(store.snippets.map(\.keyword) == [";Ship", nil, ";dup", nil, nil, ";ok"])
        #expect(store.snippet(withID: try #require(UUID(uuidString: Uid.spaces)))?.text == "four")
    }

    @Test("An entry with no name, no text, or no uid, or that isn't a snippet, is skipped as invalid")
    func skipsInvalidEntries() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let export = try folder.write(ZipFixture(entries: [
            .alfred(uid: UUID().uuidString, name: "", keyword: "a", snippet: "no name"),
            .alfred(uid: UUID().uuidString, name: "  ", keyword: "", snippet: "blank name"),
            .alfred(uid: UUID().uuidString, name: "No text", keyword: "", snippet: ""),
            // A bad keyword doesn't save an entry that has no text.
            .alfred(uid: UUID().uuidString, name: "Blank text", keyword: "two words", snippet: " \n\t"),
            .alfred(uid: "", name: "No uid", keyword: "", snippet: "text"),
            .json(path: "Missing uid.json", ["alfredsnippet": ["name": "Made-up", "snippet": "text"]]),
            .json(path: "Not a snippet.json", ["something": "else"]),
            .json(path: "Wrong type.json", ["alfredsnippet": ["uid": UUID().uuidString, "name": "Made-up", "snippet": 42]]),
            ZipFixture.Entry(path: "Not JSON.json", data: Data("made-up, not json".utf8)),
            .alfred(uid: Uid.fine, name: "Valid", keyword: "", snippet: "kept"),
            // Ignored entirely: folders, other files, and macOS resource forks.
            ZipFixture.Entry(path: "folder/", data: Data()),
            ZipFixture.Entry(path: "readme.txt", data: Data("made up".utf8)),
            ZipFixture.Entry(path: "__MACOSX/._Valid.json", data: Data("resource fork".utf8)),
            ZipFixture.Entry(path: "._Valid.json", data: Data("resource fork".utf8)),
        ]))

        let alert = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(alert == SnippetImportAlert(
            title: "Imported 1 snippet",
            message: "9 were skipped because they have no name or text, or couldn’t be read.\nTo hide a snippet’s text, edit it and turn on Sensitive."
        ))
        #expect(store.snippets.map(\.name) == ["Valid"])
    }

    @Test("Importing the same export again adds nothing, doesn't write the file, and leaves edits alone")
    func reimportAddsNothing() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let secrets = InMemorySnippetSecretStore()
        let store = folder.makeStore(secrets: secrets)
        let export = try folder.write(ZipFixture(entries: [
            .alfred(uid: Uid.greeting, name: "Made-up greeting", keyword: "hi", snippet: "Hello"),
            .alfred(uid: Uid.signOff, name: "Made-up sign-off", keyword: "bye", snippet: "Bye", method: .deflated),
            // The same uid twice in one file is imported once.
            .alfred(uid: Uid.signOff.lowercased(), name: "Made-up repeat", keyword: "", snippet: "Again"),
        ]))
        #expect(AlfredSnippetImport.importFile(at: export, into: store).title == "Imported 2 snippets")

        // The user marks one sensitive and renames it.
        let edited = try #require(UUID(uuidString: Uid.greeting))
        try store.update(edited, with: SnippetDraft(name: "Renamed", keyword: "hi", text: "Hello", isSensitive: true))
        let saved = try Data(contentsOf: folder.storageURL)

        // A folder that can't be written proves the second import doesn't try.
        try folder.setPermissions(0o500, of: folder.url)
        let again = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(again == SnippetImportAlert(title: "No snippets imported", message: "3 were already imported."))
        try folder.setPermissions(0o700, of: folder.url)
        #expect(try Data(contentsOf: folder.storageURL) == saved)
        #expect(store.snippets.count == 2)
        #expect(store.snippet(withID: edited)?.name == "Renamed")
        #expect(store.snippet(withID: edited)?.isSensitive == true)
        #expect(secrets.texts[edited] == "Hello")

        // After a relaunch too.
        let relaunched = folder.makeStore(secrets: secrets)
        #expect(AlfredSnippetImport.importFile(at: export, into: relaunched).title == "No snippets imported")
        #expect(relaunched.snippets.count == 2)
    }

    @Test("A uid that isn't a UUID gets the same derived ID every time")
    func nonUUIDUIDsGetAStableID() throws {
        let derived = AlfredSnippetImport.snippetID(forUID: "made-up-uid-1")
        #expect(derived == AlfredSnippetImport.snippetID(forUID: "made-up-uid-1"))
        #expect(derived != AlfredSnippetImport.snippetID(forUID: "made-up-uid-2"))
        #expect(derived.uuidString.dropFirst(14).first == "8", "A version 8 UUID")
        #expect(AlfredSnippetImport.snippetID(forUID: Uid.greeting.lowercased()) == UUID(uuidString: Uid.greeting))

        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let export = try folder.write(ZipFixture(entries: [
            .alfred(uid: "made-up-uid-1", name: "Made-up", keyword: "", snippet: "text"),
        ]))
        _ = AlfredSnippetImport.importFile(at: export, into: store)
        _ = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(store.snippets.map(\.id) == [derived])
    }

    @Test("A file that isn't a readable export gets a clear error, and nothing is added")
    func refusesFilesThatArentExports() throws {
        let valid = ZipFixture(entries: [
            .alfred(uid: Uid.greeting, name: "Made-up", keyword: "", snippet: "Hello from a made-up export", method: .deflated),
        ])
        var encrypted = valid
        encrypted.entries[0].flags |= 0x1
        var otherMethod = ZipFixture(entries: [.alfred(uid: Uid.greeting, name: "Made-up", keyword: "", snippet: "text")])
        otherMethod.entries[0].rawMethod = 12
        var badCRC = otherMethod
        badCRC.entries[0].rawMethod = nil
        badCRC.entries[0].crc = 0xDEAD_BEEF
        var damagedDeflate = valid.archive()
        let dataStart = 30 + "Made-up [\(Uid.greeting)].json".utf8.count
        damagedDeflate[dataStart + 2] ^= 0xFF
        let noSnippets = ZipFixture(entries: [
            .infoPlist(prefix: ";", suffix: ""),
            ZipFixture.Entry(path: "readme.txt", data: Data("made up".utf8)),
            ZipFixture.Entry(path: "__MACOSX/._Made-up.json", data: Data("resource fork".utf8)),
        ])

        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("not a zip", Data("made-up text, not a zip archive at all".utf8)),
            ("truncated", valid.archive().dropLast(10)),
            ("cut before the directory", valid.archive().prefix(30)),
            ("encrypted", encrypted.archive()),
            ("another compression method", otherMethod.archive()),
            ("a CRC that doesn't match", badCRC.archive()),
            ("a damaged deflate stream", damagedDeflate),
            ("no snippets", noSnippets.archive()),
        ]
        for (label, data) in cases {
            let folder = ImportFolder()
            defer { folder.remove() }
            let store = folder.makeStore()
            let file = folder.url.appendingPathComponent("Made-up.alfredsnippets")
            try data.write(to: file)
            let alert = AlfredSnippetImport.importFile(at: file, into: store)
            #expect(alert == .failed(AlfredSnippetImport.Failure.notAnExport.message), "\(label)")
            #expect(store.snippets.isEmpty, "\(label)")
            #expect(!FileManager.default.fileExists(atPath: folder.storageURL.path), "\(label)")
        }

        let folder = ImportFolder()
        defer { folder.remove() }
        let missing = folder.url.appendingPathComponent("Missing.alfredsnippets")
        #expect(AlfredSnippetImport.importFile(at: missing, into: folder.makeStore()) == .failed(AlfredSnippetImport.Failure.unreadable.message))
    }

    @Test("Oversized files and entries are refused before they're read or decoded")
    func refusesOversizedFiles() throws {
        let fixture = ZipFixture(entries: [
            .alfred(uid: Uid.greeting, name: "Made-up one", keyword: "", snippet: String(repeating: "a", count: 400), method: .deflated),
            .alfred(uid: Uid.signOff, name: "Made-up two", keyword: "", snippet: String(repeating: "b", count: 400)),
        ])
        let archive = fixture.archive()
        let roomy = ZipArchive.Limits(maxArchiveBytes: 10_000, maxEntries: 10, maxEntryBytes: 1_000, maxTotalBytes: 2_000)
        #expect(try AlfredSnippetImport.batch(fromArchive: archive, limits: roomy).snippets.count == 2)

        var limits = roomy
        limits.maxArchiveBytes = archive.count - 1
        #expect(throws: AlfredSnippetImport.Failure.tooLarge) { try AlfredSnippetImport.batch(fromArchive: archive, limits: limits) }
        limits = roomy
        limits.maxEntries = 1
        #expect(throws: AlfredSnippetImport.Failure.tooLarge) { try AlfredSnippetImport.batch(fromArchive: archive, limits: limits) }
        limits = roomy
        limits.maxEntryBytes = 300
        #expect(throws: AlfredSnippetImport.Failure.tooLarge) { try AlfredSnippetImport.batch(fromArchive: archive, limits: limits) }
        limits = roomy
        limits.maxTotalBytes = 800
        #expect(throws: AlfredSnippetImport.Failure.tooLarge) { try AlfredSnippetImport.batch(fromArchive: archive, limits: limits) }

        // A deflated entry that decodes to more than it declares is refused, not decoded in full.
        var understated = fixture
        understated.entries[0].declaredSize = 100
        #expect(throws: AlfredSnippetImport.Failure.notAnExport) { try AlfredSnippetImport.batch(fromArchive: understated.archive()) }

        // The file's size is checked before it's read.
        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let export = try folder.write(fixture)
        limits = roomy
        limits.maxArchiveBytes = 100
        #expect(throws: AlfredSnippetImport.Failure.tooLarge) { try AlfredSnippetImport.read(export, limits: limits) }
        #expect(AlfredSnippetImport.importFile(at: export, into: store, limits: limits) == .failed(AlfredSnippetImport.Failure.tooLarge.message))
        #expect(store.snippets.isEmpty)
    }

    @Test("While the saved snippets can't be read, import is refused and the file is untouched")
    func readOnlyLibraryRefuses() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        try folder.makeStore().add(SnippetDraft(name: "Made-up existing", text: "text"))
        let original = try Data(contentsOf: folder.storageURL)
        try folder.setPermissions(0o000, of: folder.storageURL)
        let store = folder.makeStore()
        #expect(!store.libraryState.isWritable, "Settings turns Import from Alfred… off")
        let export = try folder.write(ZipFixture(entries: [.alfred(uid: Uid.greeting, name: "Made-up", keyword: "", snippet: "text")]))

        let alert = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(alert == .failed("\(SnippetStoreError.readOnly.message) Nothing was imported."))
        #expect(throws: SnippetStoreError.readOnly) { try store.importSnippets(SnippetImportBatch()) }
        #expect(store.snippets.isEmpty)
        try folder.setPermissions(0o600, of: folder.storageURL)
        #expect(try Data(contentsOf: folder.storageURL) == original)
    }

    @Test("If the file can't be written, nothing is added")
    func failedSaveAddsNothing() throws {
        let folder = ImportFolder()
        defer { folder.remove() }
        let store = folder.makeStore()
        let existing = try store.add(SnippetDraft(name: "Made-up existing", keyword: "hi", text: "text"))
        let original = try Data(contentsOf: folder.storageURL)
        let export = try folder.write(ZipFixture(entries: [
            .alfred(uid: Uid.greeting, name: "Made-up one", keyword: "one", snippet: "1"),
            .alfred(uid: Uid.signOff, name: "Made-up two", keyword: "two", snippet: "2"),
        ]))
        try folder.setPermissions(0o500, of: folder.url)

        let alert = AlfredSnippetImport.importFile(at: export, into: store)
        #expect(alert == .failed("\(SnippetStoreError.storage.message) Nothing was imported."))
        #expect(store.snippets == [existing])
        try folder.setPermissions(0o700, of: folder.url)
        #expect(try Data(contentsOf: folder.storageURL) == original)
        #expect(folder.contents().allSatisfy { !$0.hasSuffix(".tmp") })

        // Once it can be written, the same import adds both.
        #expect(AlfredSnippetImport.importFile(at: export, into: store).title == "Imported 2 snippets")
        #expect(folder.makeStore().snippets.count == 3)
    }

    @Test("The summary gives counts only")
    func summaryIsCountsOnly() {
        #expect(SnippetImportSummary().title == "No snippets imported")
        #expect(SnippetImportSummary().message.isEmpty)
        #expect(SnippetImportSummary(imported: 1).title == "Imported 1 snippet")
        let one = SnippetImportSummary(imported: 1, alreadyImported: 1, keywordsDropped: 1, invalid: 1)
        #expect(one.message == """
        1 was already imported.
        1 was imported without its keyword, because it has spaces or another snippet uses it.
        1 was skipped because it has no name or text, or couldn’t be read.
        To hide a snippet’s text, edit it and turn on Sensitive.
        """)
        let many = SnippetImportSummary(imported: 0, alreadyImported: 4, keywordsDropped: 0, invalid: 2)
        #expect(many.message == "4 were already imported.\n2 were skipped because they have no name or text, or couldn’t be read.")
    }

    @Test("The open panel offers .alfredsnippets files")
    func openPanelOffersAlfredExports() {
        #expect(AlfredSnippetImport.contentType.tags[.filenameExtension]?.contains("alfredsnippets") == true)
    }
}

// MARK: - Zip reader

@Suite("Zip reader")
struct ZipArchiveTests {
    @Test("CRC-32 matches the standard check value")
    func crc32() {
        #expect(ZipArchive.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32([UInt8]()) == 0)
    }

    @Test("Stored and deflated entries read back exactly, past an archive comment")
    func readsEntries() throws {
        let text = Data(String(repeating: "made-up line\n", count: 200).utf8)
        var fixture = ZipFixture(entries: [
            ZipFixture.Entry(path: "folder/", data: Data()),
            ZipFixture.Entry(path: "folder/stored.txt", data: Data("stored".utf8)),
            ZipFixture.Entry(path: "deflated.txt", data: text, method: .deflated),
            ZipFixture.Entry(path: "empty.txt", data: Data()),
        ])
        fixture.comment = Data("a made-up archive comment".utf8)
        let archive = try ZipArchive(data: fixture.archive())

        #expect(archive.entries.map(\.path) == ["folder/", "folder/stored.txt", "deflated.txt", "empty.txt"])
        #expect(archive.entries.map(\.isDirectory) == [true, false, false, false])
        #expect(archive.entries[1].name == "stored.txt")
        #expect(try archive.contents(of: archive.entries[1]) == Data("stored".utf8))
        #expect(try archive.contents(of: archive.entries[2]) == text)
        #expect(try archive.contents(of: archive.entries[3]).isEmpty)
    }
}

// MARK: - Helpers

/// Made-up Alfred uids.
private enum Uid {
    static let greeting = "6B1B0C77-1F0A-4E43-9C43-0D2F1E6A0001"
    static let signOff = "6B1B0C77-1F0A-4E43-9C43-0D2F1E6A0002"
    static let placeholder = "6B1B0C77-1F0A-4E43-9C43-0D2F1E6A0003"
    static let spaces = "6B1B0C77-1F0A-4E43-9C43-0D2F1E6A0004"
    static let fine = "6B1B0C77-1F0A-4E43-9C43-0D2F1E6A0005"
}

/// A zip archive written in memory, laid out as Alfred's export is: each entry's local header and
/// data, then the central directory and its end record.
private struct ZipFixture {
    enum Method { case stored, deflated }

    struct Entry {
        var path: String
        var data: Data
        var method: Method = .stored
        /// General-purpose flags; bit 11 marks a UTF-8 path.
        var flags: UInt16 = 0x0800
        /// Overrides the method written, for an unsupported one.
        var rawMethod: UInt16?
        /// Overrides the CRC-32 written.
        var crc: UInt32?
        /// Overrides the uncompressed size written.
        var declaredSize: Int?

        static func alfred(
            uid: String,
            name: String,
            keyword: String,
            snippet: String,
            extra: [String: Any] = [:],
            method: Method = .stored
        ) -> Entry {
            var fields: [String: Any] = ["uid": uid, "name": name, "keyword": keyword, "snippet": snippet]
            fields.merge(extra) { $1 }
            var entry = json(path: "\(name) [\(uid)].json", ["alfredsnippet": fields])
            entry.method = method
            return entry
        }

        static func json(path: String, _ object: [String: Any]) -> Entry {
            Entry(path: path, data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }

        static func infoPlist(prefix: String, suffix: String, method: Method = .stored) -> Entry {
            let plist: [String: Any] = ["snippetkeywordprefix": prefix, "snippetkeywordsuffix": suffix, "madeUpKey": true]
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return Entry(path: "info.plist", data: data, method: method)
        }
    }

    var entries: [Entry]
    var comment = Data()

    func archive() -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let raw = [UInt8](entry.data)
            let deflates = entry.method == .deflated && !raw.isEmpty
            let stored = deflates ? Self.deflate(raw) : raw
            let method = entry.rawMethod ?? (deflates ? 8 : 0)
            let crc = entry.crc ?? ZipArchive.crc32(raw)
            let size = entry.declaredSize ?? raw.count
            let name = [UInt8](entry.path.utf8)
            let offset = body.count
            // Version, flags, method, time, date, CRC-32, and sizes: the same in both headers.
            var fields = le16(20) + le16(entry.flags) + le16(method) + le16(0) + le16(0)
            fields += le32(crc) + le32(stored.count) + le32(size) + le16(name.count)

            body += le32(0x0403_4B50) + fields
            body += le16(0) + name + stored
            directory += le32(0x0201_4B50) + le16(20) + fields
            // Extra field, comment, disk, attributes, and where the local header is.
            directory += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        var end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        end += le32(directory.count) + le32(body.count) + le16(comment.count) + [UInt8](comment)
        return body + directory + Data(end)
    }

    private static func deflate(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + 1_024)
        let count = compression_encode_buffer(&output, output.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        precondition(count > 0, "The fixture couldn't be deflated")
        return Array(output.prefix(count))
    }

    private func le16<Value: BinaryInteger>(_ value: Value) -> [UInt8] {
        let value = UInt16(value)
        return [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func le32<Value: BinaryInteger>(_ value: Value) -> [UInt8] {
        let value = UInt32(value)
        return (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) }
    }
}

/// A temporary folder holding one `snippets.json` and the exports a test writes.
@MainActor
private struct ImportFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsSnippetImport-\(UUID().uuidString)", isDirectory: true)

    var storageURL: URL { url.appendingPathComponent(SnippetStore.fileName) }

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeStore(secrets: any SnippetSecretStoring = InMemorySnippetSecretStore()) -> SnippetStore {
        SnippetStore(storageURL: storageURL, secrets: secrets)
    }

    /// Writes a made-up export into the folder.
    func write(_ fixture: ZipFixture) throws -> URL {
        let file = url.appendingPathComponent("Made-up collection.alfredsnippets")
        try fixture.archive().write(to: file)
        return file
    }

    func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func setPermissions(_ mode: Int, of file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    /// Restores permissions a test took away, then deletes the folder.
    func remove() {
        try? setPermissions(0o700, of: url)
        for name in contents() {
            try? setPermissions(0o600, of: url.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: url)
    }
}
