import AppKit
import Foundation
import Observation

struct QuickSearchResult: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case application = "Application", file = "File", folder = "Folder" }
    let url: URL
    let kind: Kind
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var detail: String { kind == .application ? url.path : url.deletingLastPathComponent().path }
}

@MainActor
@Observable
final class QuickSearchModel {
    var query = "" { didSet { refresh() } }
    /// The rows for the current query, ranked by `QuickSearchRanking.items`.
    private(set) var items: [QuickSearchItem] = []
    /// The apps, files, and folders among `items`.
    var results: [QuickSearchResult] { items.compactMap(\.result) }

    /// The highlighted result, if any. With an empty query the palette lists Recent Items instead,
    /// even if a late Spotlight update refilled `items`.
    func highlightedItem(at selection: Int) -> QuickSearchItem? {
        Self.highlightedItem(in: items, query: query, selection: selection)
    }

    nonisolated static func highlightedItem(in items: [QuickSearchItem], query: String, selection: Int) -> QuickSearchItem? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, items.indices.contains(selection) else { return nil }
        return items[selection]
    }
    let recentItems: RecentItemStore
    let applicationUsage: ApplicationUsageStore
    /// The snippets a query can find: none until the palette supplies them, which it does only while
    /// Snippets is on.
    @ObservationIgnored var snippets: () -> [Snippet] = { [] }
    /// Every emoji a query can find: none until Emoji Picker supplies them (#333), which it does only
    /// while it's on and Show emoji in Quick Search is too. The palette shows a few of them, or all
    /// under `/`'s Emoji filter (`QuickSearchEmoji.limited`).
    @ObservationIgnored var emoji: (_ query: String) -> [QuickSearchEmoji] = { _ in [] }

    private let applications: [QuickSearchResult]
    /// Whether a query also runs the Spotlight search of the home folder for files and folders.
    /// Always false under the unit-test host.
    let searchesFiles: Bool
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    /// Tests supply their own applications and their own `recentItems` and `applicationUsage` stores
    /// in a temporary folder. Under the unit-test host, the defaults are isolated anyway: no app
    /// folder is listed, Spotlight never runs, and the stores use `UnitTestHost.dataDirectory`, so a
    /// test never reads the owner's folders or the installed app's Quick Search files.
    init(
        fileManager: FileManager = .default,
        recentItems: RecentItemStore? = nil,
        applicationUsage: ApplicationUsageStore? = nil,
        applications suppliedApplications: [QuickSearchResult]? = nil,
        searchesFiles: Bool = true
    ) {
        self.recentItems = recentItems ?? RecentItemStore(fileManager: fileManager)
        self.applicationUsage = applicationUsage ?? ApplicationUsageStore(fileManager: fileManager)
        self.searchesFiles = searchesFiles && !UnitTestHost.isActive
        if let suppliedApplications {
            applications = suppliedApplications.filter { !Self.isKeybumps($0) }
            return
        }
        guard !UnitTestHost.isActive else {
            applications = []
            return
        }
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"), fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var seen = Set<URL>()
        var apps: [QuickSearchResult] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where url.pathExtension == "app" && seen.insert(url).inserted {
                apps.append(QuickSearchResult(url: url, kind: .application))
            }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isApplicationKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" && seen.insert(url).inserted {
                apps.append(QuickSearchResult(url: url, kind: .application))
            }
        }
        applications = apps
            .filter { !Self.isKeybumps($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Recent Items as the palette lists them: never Keybumps itself, even an entry saved before
    /// Quick Search hid it. Keybumps Settings covers it.
    var displayedRecentItems: [RecentItem] {
        recentItems.items.filter { !Self.isKeybumps($0.result) }
    }

    /// Whether a result is a copy of Keybumps (`QuickSearchCommand.standIn(for:)`), which Quick
    /// Search never lists as an app: opening it would only reopen Keybumps, and Keybumps Settings is
    /// listed instead. Its old learned usage is then never looked up.
    nonisolated static func isKeybumps(_ result: QuickSearchResult) -> Bool {
        QuickSearchCommand.standIn(for: result) != nil
    }

    func refresh() {
        metadataQuery?.stop()
        clearObservers()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            items = []
            return
        }

        let appMatches = QuickSearchRanking.sortedApplications(
            matching: term,
            from: applications,
            usage: applicationUsage
        )
        items = QuickSearchRanking.items(
            matching: term, applications: Array(appMatches.prefix(12)), files: [], snippets: snippets(),
            emoji: emoji(term), usage: applicationUsage
        )
        guard searchesFiles else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@ AND (%K == %@ OR %K == %@)", NSMetadataItemFSNameKey, term, NSMetadataItemContentTypeTreeKey, "public.item", NSMetadataItemContentTypeKey, "public.folder")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self, weak query] _ in
                guard let query else { return }
                Task { @MainActor in self?.consume(query: query, term: term, appMatches: appMatches) }
            })
        }
        metadataQuery = query
        query.start()
    }

    func recordOpenResult(_ result: QuickSearchResult, succeeded: Bool) {
        guard succeeded else { return }
        recentItems.record(result)
        applicationUsage.record(result)
    }

    /// Learns a command the user ran from the results, so it ranks like an app opened as often.
    /// Commands never become Recent Items.
    func recordRunCommand(_ command: QuickSearchCommand) {
        applicationUsage.record(command)
    }

    private func consume(query: NSMetadataQuery, term: String, appMatches: [QuickSearchResult]) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var seen = Set(appMatches.map(\.url))
        var files: [QuickSearchResult] = []
        for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension != "app", seen.insert(url).inserted else { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            files.append(QuickSearchResult(url: url, kind: isDirectory.boolValue ? .folder : .file))
            if files.count == 30 { break }
        }
        items = QuickSearchRanking.items(
            matching: term, applications: Array(appMatches.prefix(12)), files: files, snippets: snippets(),
            emoji: emoji(term), usage: applicationUsage
        )
    }

    private func clearObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
