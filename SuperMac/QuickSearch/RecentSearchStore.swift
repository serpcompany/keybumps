import Foundation
import Observation

@MainActor
@Observable
final class RecentSearchStore {
    private(set) var queries: [String] = []

    private let storageURL: URL
    private let limit: Int
    private let fileManager: FileManager

    init(
        storageURL: URL? = nil,
        limit: Int = 10,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.limit = max(1, limit)
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.storageURL = storageURL
            ?? applicationSupport.appendingPathComponent(
                "SuperMac/recent-searches.json",
                isDirectory: false
            )
        load()
    }

    func record(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        queries.insert(query, at: 0)
        if queries.count > limit {
            queries.removeLast(queries.count - limit)
        }
        persist()
    }

    func clear() {
        queries.removeAll()
        try? fileManager.removeItem(at: storageURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        var unique: [String] = []
        for rawQuery in stored {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty,
                  !unique.contains(where: {
                      $0.caseInsensitiveCompare(query) == .orderedSame
                  }) else { continue }
            unique.append(query)
            if unique.count == limit { break }
        }
        queries = unique
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(queries).write(to: storageURL, options: .atomic)
        } catch {
            // Search history is optional. A persistence failure must not block search.
        }
    }
}
