import Foundation

/// A translation saved from the Translate tab with Return (#362): what was typed, its translation,
/// the two languages (codes such as `en` or `zh-Hant`), and when it was saved.
struct TranslationRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceLanguage: String
    let targetLanguage: String
    let savedAt: Date
}

/// Recent translations (#362): the last `limit` saved, newest first, kept only on this Mac in their
/// own file next to Clipboard History's. They are user content: listed in the Translate tab and
/// never logged. A missing or unreadable file starts with none. Turning Translation off keeps them;
/// "Clear Recent Translations" in its settings removes them.
@MainActor
@Observable
final class RecentTranslations {
    static let fileName = "recent-translations.json"
    static let limit = 50

    private(set) var records: [TranslationRecord] = []
    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let now: () -> Date

    /// - Parameter storageURL: the JSON file, or nil to keep them in memory only.
    init(storageURL: URL?, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.now = now
        if let storageURL, let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([TranslationRecord].self, from: data) {
            records = Array(saved.prefix(Self.limit))
        }
    }

    static func makeDefault() -> RecentTranslations {
        RecentTranslations(storageURL: ProductPaths.keybumps().applicationSupport.appendingPathComponent(fileName))
    }

    /// Saves a translation at the top, keeping the newest `limit`. The same text saved again between
    /// the same languages moves its record to the top, with this translation, instead of adding
    /// another.
    @discardableResult
    func save(_ sourceText: String, translated translatedText: String, from source: String, to target: String) -> TranslationRecord {
        let source = TranslationLanguagePair.code(source)
        let target = TranslationLanguagePair.code(target)
        let existing = records.firstIndex {
            $0.sourceText == sourceText && $0.sourceLanguage == source && $0.targetLanguage == target
        }
        let record = TranslationRecord(
            id: existing.map { records[$0].id } ?? UUID(),
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: source,
            targetLanguage: target,
            savedAt: now()
        )
        if let existing { records.remove(at: existing) }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        persist()
        return record
    }

    func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        persist()
    }

    /// Removes every record, and the file.
    func clear() {
        records = []
        guard let storageURL, fileManager.fileExists(atPath: storageURL.path) else { return }
        try? fileManager.removeItem(at: storageURL)
    }

    /// A failed save keeps the records in memory; nothing about them is logged.
    private func persist() {
        guard let storageURL, let data = try? JSONEncoder().encode(records) else { return }
        try? PrivateFile.write(data, to: storageURL, fileManager: fileManager)
    }
}
