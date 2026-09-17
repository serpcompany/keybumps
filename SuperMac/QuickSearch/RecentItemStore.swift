import Foundation
import Observation

struct RecentItem: Codable, Equatable, Identifiable {
    let result: QuickSearchResult
    let openedAt: Date

    var id: URL { result.url }
}

@MainActor
@Observable
final class RecentItemStore {
    private(set) var items: [RecentItem] = []

    private let storageURL: URL
    private let limit: Int
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        storageURL: URL? = nil,
        limit: Int = 10,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.limit = max(1, limit)
        self.now = now
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.storageURL = storageURL
            ?? applicationSupport.appendingPathComponent(
                "SuperMac/recent-items.json",
                isDirectory: false
            )
        load()
    }

    func record(_ result: QuickSearchResult) {
        items.removeAll { $0.id == result.id }
        items.insert(RecentItem(result: result, openedAt: now()), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        persist()
    }

    func delete(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        try? fileManager.removeItem(at: storageURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([RecentItem].self, from: data) else {
            return
        }
        var seen = Set<URL>()
        items = stored.filter { item in
            seen.insert(item.id).inserted
        }.prefix(limit).map { $0 }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(items).write(to: storageURL, options: .atomic)
        } catch {
            // Recent items are optional. A persistence failure must not block search.
        }
    }
}
