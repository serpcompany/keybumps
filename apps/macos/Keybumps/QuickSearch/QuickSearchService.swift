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
    /// The rows for the current query: Keybumps commands, apps, then files and folders.
    private(set) var items: [QuickSearchItem] = []
    /// The apps, files, and folders among `items`.
    var results: [QuickSearchResult] { items.compactMap(\.result) }
    let recentItems: RecentItemStore
    let applicationUsage: ApplicationUsageStore

    private let applications: [QuickSearchResult]
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    init(
        fileManager: FileManager = .default,
        recentItems: RecentItemStore? = nil,
        applicationUsage: ApplicationUsageStore? = nil,
        applications suppliedApplications: [QuickSearchResult]? = nil
    ) {
        self.recentItems = recentItems ?? RecentItemStore(fileManager: fileManager)
        self.applicationUsage = applicationUsage ?? ApplicationUsageStore(fileManager: fileManager)
        if let suppliedApplications {
            applications = suppliedApplications
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
        applications = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        items = QuickSearchRanking.items(matching: term, applications: Array(appMatches.prefix(12)), files: [])

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
        items = QuickSearchRanking.items(matching: term, applications: Array(appMatches.prefix(12)), files: files)
    }

    private func clearObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
