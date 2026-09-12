import Foundation
import Observation

struct DictationHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let language: String
    let capturedAt: Date
}

@MainActor
@Observable
final class DictationHistoryService {
    private(set) var entries: [DictationHistoryEntry] = []

    private let limit: Int
    private let storageURL: URL

    init(
        limit: Int = 25,
        fileManager: FileManager = .default,
        storageURL: URL? = nil
    ) {
        self.limit = limit
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperMac", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storageURL = storageURL ?? directory.appendingPathComponent("dictation-history.json")

        if let data = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) {
            entries = Array(decoded.prefix(limit))
        }
    }

    func record(_ text: String, language: String, capturedAt: Date = .now) {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        entries.insert(
            DictationHistoryEntry(
                id: UUID(),
                text: transcript,
                language: language,
                capturedAt: capturedAt
            ),
            at: 0
        )
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
    }

    func delete(_ entry: DictationHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
