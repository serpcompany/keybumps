import Foundation

struct ApplicationUsageRecord: Codable, Equatable {
    var launchCount: Int
    var lastOpenedAt: Date
}

/// Quick Search's learned usage: how often and how recently the user opened each app, or ran each
/// Quick Search command, from Quick Search. It is kept per item, not per query, and only ranks
/// results; it never lists anything (Recent Items does). Apps are keyed by their standardized path
/// and commands by `command:<id>`, so the keys never collide and older builds ignore command keys.
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
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        load()
    }

    /// The app's Application Support folder, or under the unit-test host that run's own folder.
    nonisolated static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        let folder = UnitTestHost.isActive
            ? UnitTestHost.dataDirectory
            : ProductPaths.keybumps(fileManager: fileManager).applicationSupport
        return folder.appendingPathComponent("application-usage.json", isDirectory: false)
    }

    func record(_ result: QuickSearchResult) {
        guard result.kind == .application else { return }
        record(key: result.url.standardizedFileURL.path)
    }

    /// Learns a command the user ran from Quick Search's results, exactly as an opened app.
    func record(_ command: QuickSearchCommand) {
        record(key: Self.key(for: command))
    }

    func record(for url: URL) -> ApplicationUsageRecord? {
        records[url.standardizedFileURL.path]
    }

    func record(for command: QuickSearchCommand) -> ApplicationUsageRecord? {
        records[Self.key(for: command)]
    }

    func priorityScore(for result: QuickSearchResult) -> Int {
        priorityScore(for: record(for: result.url))
    }

    func priorityScore(for command: QuickSearchCommand) -> Int {
        priorityScore(for: record(for: command))
    }

    private static func key(for command: QuickSearchCommand) -> String {
        "command:\(command.id)"
    }

    private func record(key: String) {
        let existing = records[key]
        records[key] = ApplicationUsageRecord(
            launchCount: (existing?.launchCount ?? 0) + 1,
            lastOpenedAt: now()
        )
        persist()
    }

    private func priorityScore(for record: ApplicationUsageRecord?) -> Int {
        guard let record else { return 0 }
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
        let term = normalized(rawTerm)
        return applications
            .filter { normalizedName(for: $0).contains(term) }
            .sorted { lhs, rhs in
                let lhsScore = score(for: lhs, normalizedTerm: term, usage: usage)
                let rhsScore = score(for: rhs, normalizedTerm: term, usage: usage)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// An app's rank for a query: how well its name matches, from 10,000 for the exact name down to
    /// 1,000 for a late substring, plus its learned usage. Commands are ranked on the same scale
    /// (`QuickSearchCommand.Match.textScore`).
    @MainActor
    static func score(for result: QuickSearchResult, normalizedTerm term: String, usage: ApplicationUsageStore?) -> Int {
        textScore(for: result, term: term) + (usage?.priorityScore(for: result) ?? 0)
    }

    /// A query as the rankings compare it: case and accents ignored.
    static func normalized(_ term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
        normalized(result.name)
    }
}
