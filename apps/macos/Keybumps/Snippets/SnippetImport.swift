import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A snippet read from another app's export, before `SnippetStore.importSnippets` adds it.
struct ImportedSnippet: Equatable {
    /// The same for every import of the same export, so importing it again adds nothing.
    let id: UUID
    var name: String
    var keyword: String?
    var text: String
}

/// Everything an export offered: its snippets, and how many entries weren't snippets Keybumps could read.
struct SnippetImportBatch: Equatable {
    var snippets: [ImportedSnippet] = []
    var unreadableEntries = 0
}

/// What an import did, as counts only: never a snippet's name, keyword, or text.
struct SnippetImportSummary: Equatable {
    var imported = 0
    /// Already in the library (the same ID, from an earlier import), so skipped.
    var alreadyImported = 0
    /// Imported without their keyword, which had spaces or was already another snippet's.
    var keywordsDropped = 0
    /// Skipped: no name, no text, or an entry that couldn't be read.
    var invalid = 0

    var title: String {
        switch imported {
        case 0: "No snippets imported"
        case 1: "Imported 1 snippet"
        default: "Imported \(imported) snippets"
        }
    }

    var message: String {
        var lines: [String] = []
        if alreadyImported > 0 {
            lines.append(alreadyImported == 1 ? "1 was already imported." : "\(alreadyImported) were already imported.")
        }
        if keywordsDropped > 0 {
            lines.append(keywordsDropped == 1
                ? "1 was imported without its keyword, because it has spaces or another snippet uses it."
                : "\(keywordsDropped) were imported without their keywords, because they have spaces or other snippets use them.")
        }
        if invalid > 0 {
            lines.append(invalid == 1
                ? "1 was skipped because it has no name or text, or couldn’t be read."
                : "\(invalid) were skipped because they have no name or text, or couldn’t be read.")
        }
        if imported > 0 {
            lines.append("To hide a snippet’s text, edit it and turn on Sensitive.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads an Alfred snippets export (`.alfredsnippets`) for `SnippetStore.importSnippets`.
///
/// - **Format:** a zip holding one `<name> [<uid>].json` per snippet, each
///   `{"alfredsnippet": {"name", "keyword", "snippet", "uid"}}`, and an optional `info.plist` whose
///   `snippetkeywordprefix` and `snippetkeywordsuffix` wrap every non-empty keyword. Other entries,
///   macOS's `__MACOSX/` and `._` resource forks, and extra keys such as `dontautoexpand` are
///   ignored, and an `info.plist` that can't be read counts as none. Placeholders such as
///   `{clipboard}` stay literal text.
/// - **IDs:** each snippet takes Alfred's uid as its ID (a UUID derived from it when the uid isn't
///   one), so importing the same export again adds nothing, and the file needs no new field that an
///   older build saving it would drop.
/// - **Privacy:** nothing about the file, its entries, or its snippets is logged.
enum AlfredSnippetImport {
    static let fileExtension = "alfredsnippets"
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }

    enum Failure: Error, Equatable {
        /// The file couldn't be opened or read.
        case unreadable
        /// Not a zip, damaged, or holding no snippets.
        case notAnExport
        /// Over `ZipArchive.Limits`.
        case tooLarge

        var message: String {
            switch self {
            case .unreadable: "Keybumps couldn’t read this file."
            case .notAnExport: "This file isn’t an Alfred snippets export Keybumps can read, or it’s damaged."
            case .tooLarge: "This file is too large to be an Alfred snippets export."
            }
        }
    }

    /// Imports the export at `url` into `store` in one save, and returns the alert to show. An import
    /// that fails adds nothing.
    @MainActor
    static func importFile(at url: URL, into store: SnippetStore, limits: ZipArchive.Limits = .standard) -> SnippetImportAlert {
        do {
            let summary = try store.importSnippets(read(url, limits: limits))
            return SnippetImportAlert(title: summary.title, message: summary.message)
        } catch let failure as Failure {
            return .failed(failure.message)
        } catch let error as SnippetStoreError {
            return .failed("\(error.message) Nothing was imported.")
        } catch {
            return .failed("\(SnippetStoreError.storage.message) Nothing was imported.")
        }
    }

    /// Reads the export at `url`, which may be security-scoped (from an open panel).
    static func read(_ url: URL, limits: ZipArchive.Limits = .standard) throws -> SnippetImportBatch {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.unreadable }
        guard size <= limits.maxArchiveBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return try batch(fromArchive: data, limits: limits)
    }

    static func batch(fromArchive data: Data, limits: ZipArchive.Limits = .standard) throws -> SnippetImportBatch {
        do {
            let archive = try ZipArchive(data: data, limits: limits)
            let files = archive.entries.filter { entry in
                !entry.isDirectory && !entry.path.hasPrefix("__MACOSX/") && !entry.name.hasPrefix("._")
            }
            let snippetEntries = files.filter { $0.name.lowercased().hasSuffix(".json") }
            guard !snippetEntries.isEmpty else { throw Failure.notAnExport }
            let affixes = try files.first(where: { $0.name.lowercased() == "info.plist" })
                .map { try KeywordAffixes(plist: archive.contents(of: $0)) } ?? KeywordAffixes()

            var batch = SnippetImportBatch()
            for entry in snippetEntries {
                if let snippet = try snippet(from: archive.contents(of: entry), affixes: affixes) {
                    batch.snippets.append(snippet)
                } else {
                    batch.unreadableEntries += 1
                }
            }
            return batch
        } catch ZipArchive.Failure.tooLarge {
            throw Failure.tooLarge
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.notAnExport
        }
    }

    /// The snippet ID for an Alfred uid: the uid itself when it's a UUID, as Alfred's are, and
    /// otherwise a UUID derived from it (SHA-256, version 8), so the same uid always gives the same ID.
    static func snippetID(forUID uid: String) -> UUID {
        if let id = UUID(uuidString: uid) { return id }
        var bytes = Array(SHA256.hash(data: Data("alfredsnippet:\(uid)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// One entry's snippet, or nil when it isn't one or has no uid. The store judges its name,
    /// keyword, and text.
    private static func snippet(from data: Data, affixes: KeywordAffixes) -> ImportedSnippet? {
        guard let entry = try? JSONDecoder().decode(ExportEntry.self, from: data).alfredsnippet else { return nil }
        let uid = entry.uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !uid.isEmpty else { return nil }
        let keyword = entry.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped = keyword.flatMap { $0.isEmpty ? nil : affixes.prefix + $0 + affixes.suffix }
        return ImportedSnippet(id: snippetID(forUID: uid), name: entry.name ?? "", keyword: wrapped, text: entry.snippet ?? "")
    }

    private struct ExportEntry: Decodable {
        struct Snippet: Decodable {
            let snippet: String?
            let uid: String?
            let name: String?
            let keyword: String?
        }

        let alfredsnippet: Snippet
    }

    /// The collection's keyword prefix and suffix from `info.plist`.
    private struct KeywordAffixes {
        var prefix = ""
        var suffix = ""

        init() {}

        init(plist data: Data) {
            let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            prefix = values?["snippetkeywordprefix"] as? String ?? ""
            suffix = values?["snippetkeywordsuffix"] as? String ?? ""
        }
    }
}

/// The alert Settings › Snippets shows after an import.
struct SnippetImportAlert: Equatable {
    let title: String
    let message: String

    static func failed(_ message: String) -> SnippetImportAlert {
        SnippetImportAlert(title: "Couldn’t import snippets", message: message)
    }
}
