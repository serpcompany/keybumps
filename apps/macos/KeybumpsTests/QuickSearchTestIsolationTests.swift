import Foundation
import Testing
@testable import Keybumps

extension QuickSearchModel {
    /// Quick Search for a test: the given apps (none by default), no Spotlight search, and Recent
    /// Items and learned usage in `directory`, which the test removes.
    static func forTests(
        in directory: URL,
        applications: [QuickSearchResult] = [],
        now: @escaping () -> Date = Date.init
    ) -> QuickSearchModel {
        QuickSearchModel(
            recentItems: RecentItemStore(storageURL: directory.appendingPathComponent("recent-items.json"), now: now),
            applicationUsage: ApplicationUsageStore(storageURL: directory.appendingPathComponent("application-usage.json"), now: now),
            applications: applications,
            searchesFiles: false
        )
    }
}

/// Tests must never read or write the owner's Quick Search data (#186 review): a test's Recent Item
/// once showed up in the installed app. Like `InMemoryDefaultsTests` for preferences.
@MainActor
@Suite("Quick Search test isolation")
struct QuickSearchTestIsolationTests {
    private var installedAppSupport: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybumps", isDirectory: true).path
    }

    /// Checks stores built with their default location, including the ones a default
    /// `QuickSearchModel()` makes, which every `AppModel` composition without `quickSearch:` gets. So
    /// reverting either store's default, or the path helper, to the installed app's folder fails here.
    @Test("Under the unit-test host, stores built with their default location use this run's own temporary folder")
    func defaultStoresStayOutOfTheInstalledApp() {
        #expect(UnitTestHost.isActive)
        let temporary = FileManager.default.temporaryDirectory.path
        let model = QuickSearchModel()
        let defaults = [
            RecentItemStore().storageURL, model.recentItems.storageURL, RecentItemStore.defaultStorageURL(),
            ApplicationUsageStore().storageURL, model.applicationUsage.storageURL, ApplicationUsageStore.defaultStorageURL(),
        ]
        for url in defaults {
            #expect(!url.path.hasPrefix(installedAppSupport), "\(url.lastPathComponent) would be the installed app's")
            #expect(url.path.hasPrefix(UnitTestHost.dataDirectory.path), "\(url.path)")
            #expect(url.path.hasPrefix(temporary))
        }
    }

    @Test("Recording through default stores writes files only in this run's own folder")
    func defaultStoresWriteOnlyToTheRunsFolder() {
        let app = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Dictionary.app"), kind: .application)
        let recentItems = RecentItemStore()
        let usage = ApplicationUsageStore()
        defer {
            try? FileManager.default.removeItem(at: recentItems.storageURL)
            try? FileManager.default.removeItem(at: usage.storageURL)
        }

        recentItems.record(app)
        usage.record(app)
        usage.record(QuickSearchCommand.keybumpsSettings)

        for url in [recentItems.storageURL, usage.storageURL] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was written")
            #expect(url.deletingLastPathComponent().standardizedFileURL == UnitTestHost.dataDirectory.standardizedFileURL)
        }
    }

    @Test("Under the unit-test host, a default Quick Search lists no app folder and never starts Spotlight")
    func defaultModelReadsNoUserFolders() {
        let model = QuickSearchModel()
        #expect(!model.searchesFiles)
        model.query = "a"
        #expect(model.results.isEmpty, "No app folder was listed, and no file search ran")
        #expect(!QuickSearchModel(applications: [], searchesFiles: true).searchesFiles, "Spotlight stays off even if a test asks")
    }

    @Test("The shared test composition's palette keeps its Quick Search data in the harness's own folder")
    func harnessQuickSearchIsIsolated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsQuickSearchIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root)

        harness.model.commandPalette.choose(.capability(.clipboardHistory))

        let written = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { ($0 as? URL)?.lastPathComponent }
        #expect(written.contains("application-usage.json"), "Learned usage went to the harness's folder")
    }
}
