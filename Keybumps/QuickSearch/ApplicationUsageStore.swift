import Foundation

struct ApplicationUsageRecord: Codable, Equatable {
    var launchCount: Int
    var lastOpenedAt: Date
}

@MainActor
final class ApplicationUsageStore {
    private var records: [String: ApplicationUsageRecord] = [:]
    private let storageURL: URL
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.storageURL = storageURL
            ?? ProductPaths.keybumps(fileManager: fileManager).applicationSupport
                .appendingPathComponent("application-usage.json", isDirectory: false)
        load()
    }

    func record(_ result: QuickSearchResult) {
        guard result.kind == .application else { return }
        let key = result.url.standardizedFileURL.path
        let existing = records[key]
        records[key] = ApplicationUsageRecord(
            launchCount: (existing?.launchCount ?? 0) + 1,
            lastOpenedAt: now()
        )
        persist()
    }

    func record(for url: URL) -> ApplicationUsageRecord? {
        records[url.standardizedFileURL.path]
    }

    func priorityScore(for result: QuickSearchResult) -> Int {
        guard let record = record(for: result.url) else { return 0 }
        let frequencyScore = min(record.launchCount, 20) * 1_500
        let age = max(0, now().timeIntervalSince(record.lastOpenedAt))
        let recencyScore: Int
        switch age {
        case 0..<(24 * 60 * 60): recencyScore = 1_000
        case 0..<(7 * 24 * 60 * 60): recencyScore = 600
        case 0..<(30 * 24 * 60 * 60): recencyScore = 250
        default: recencyScore = 0
        }
        return frequencyScore + recencyScore
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode(
                [String: ApplicationUsageRecord].self,
                from: data
              ) else { return }
        records = stored.filter { $0.value.launchCount > 0 }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: storageURL, options: .atomic)
        } catch {
            // Learned ranking is optional. Search must keep working if persistence fails.
        }
    }
}

enum QuickSearchRanking {
    @MainActor
    static func sortedApplications(
        matching rawTerm: String,
        from applications: [QuickSearchResult],
        usage: ApplicationUsageStore
    ) -> [QuickSearchResult] {
        let term = rawTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return applications
            .filter { normalizedName(for: $0).contains(term) }
            .sorted { lhs, rhs in
                let lhsScore = textScore(for: lhs, term: term) + usage.priorityScore(for: lhs)
                let rhsScore = textScore(for: rhs, term: term) + usage.priorityScore(for: rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func textScore(for result: QuickSearchResult, term: String) -> Int {
        let name = normalizedName(for: result)
        if name == term { return 10_000 }
        if name.hasPrefix(term) { return 6_000 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(term) }) {
            return 5_000
        }
        let offset = name.range(of: term).map { name.distance(from: name.startIndex, to: $0.lowerBound) } ?? 100
        return 3_000 - min(offset, 100) * 20
    }

    private static func normalizedName(for result: QuickSearchResult) -> String {
        result.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
