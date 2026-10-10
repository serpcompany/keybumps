import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Tests must never read or write the owner's data (#191). An `AppModel` built without its
/// Dictation History once listed the real Documents folder, so macOS asked for Documents access on
/// every test run. Like `InMemoryDefaultsTests` for preferences, this fails if a default location
/// goes back to the owner's folders.
///
/// The guard itself never opens the owner's folders, even when it fails. Path checks only compute
/// URLs. Every default store here takes its location from `ProductPaths` or the screenshot
/// resolver, and each test that builds one first requires (`requireIsolatedDefaults`) that those
/// resolve inside this run's folder, so a regression stops the test before any store is built.
@MainActor
@Suite("Unit-test data isolation")
struct UnitTestDataIsolationTests {
    /// The installed app's folders, spelled as `FileManager.default` spells them. Never opened.
    private static let ownerFolders: [URL] = [
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        FileManager.default.temporaryDirectory,
    ].map { $0.appendingPathComponent("Keybumps", isDirectory: true) }

    /// A lexical check: it never touches the file system.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }

    private func expectInRunFolder(_ url: URL, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            Self.isInside(url, UnitTestHost.dataDirectory),
            "\(what) is outside this run's own folder",
            sourceLocation: sourceLocation
        )
        for folder in Self.ownerFolders {
            #expect(!Self.isInside(url, folder), "\(what) is in the installed app's folder", sourceLocation: sourceLocation)
        }
    }

    private func expectInRunFolder(_ paths: ProductPaths, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectInRunFolder(paths.applicationSupport, "\(what) Application Support", sourceLocation: sourceLocation)
        expectInRunFolder(paths.recordings, "\(what) recordings", sourceLocation: sourceLocation)
        expectInRunFolder(paths.captures, "\(what) Screencast captures", sourceLocation: sourceLocation)
        expectInRunFolder(paths.dictationModels, "\(what) Dictation models", sourceLocation: sourceLocation)
        expectInRunFolder(paths.translatedSpeechTemporary, "\(what) translated audio", sourceLocation: sourceLocation)
    }

    /// Stops the test unless every default location resolves inside this run's folder. Call it
    /// before building any store: if a default regressed, building one would open the owner's folders.
    private func requireIsolatedDefaults(sourceLocation: SourceLocation = #_sourceLocation) throws {
        try #require(UnitTestHost.isActive, sourceLocation: sourceLocation)
        try #require(ProductPaths.sandboxRoot == nil, "Only UI test mode sets the sandbox", sourceLocation: sourceLocation)
        let paths = ProductPaths.keybumps()
        let locations = [
            paths.applicationSupport, paths.recordings, paths.captures, paths.dictationModels, paths.translatedSpeechTemporary,
            ScreenshotLocationResolver.system.homeDirectory,
        ]
        for url in locations {
            try #require(
                Self.isInside(url, UnitTestHost.dataDirectory),
                "A default location left this run's folder; no store is built",
                sourceLocation: sourceLocation
            )
        }
    }

    private func makeDefaultModel() -> AppModel {
        AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: NoEventPersistence()),
            presenceController: NoPresenceChanges(),
            detector: ManualActionDetector(),
            updater: DisabledUpdateController(reason: "Unit-test data isolation")
        )
    }

    @Test("Under the unit-test host, every Keybumps folder is in this run's own temporary folder")
    func productPathsUseTheRunsFolder() {
        #expect(UnitTestHost.isActive)
        #expect(ProductPaths.sandboxRoot == nil, "Only UI test mode sets the sandbox")
        #expect(Self.isInside(UnitTestHost.dataDirectory, FileManager.default.temporaryDirectory))
        #expect(!Self.ownerFolders.contains { Self.isInside(UnitTestHost.dataDirectory, $0) })

        expectInRunFolder(ProductPaths.keybumps(), "The default")
        expectInRunFolder(ProductPaths.keybumps(fileManager: FileManager()), "A new file manager's")
        expectInRunFolder(ScreenshotLocationResolver.system.homeDirectory, "The screenshot home folder")
    }

    @Test("Stores built with their default location keep their data in this run's folder")
    func defaultStoresUseTheRunsFolder() throws {
        try requireIsolatedDefaults()

        let history = DictationHistoryService()
        expectInRunFolder(history.recordingsDirectoryURL, "Dictation History")
        #expect(FileManager.default.fileExists(atPath: history.recordingsDirectoryURL.path), "It made its folder there")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsDataIsolation-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardHistoryService(pasteboard: pasteboard, sourceApps: .inert)
        expectInRunFolder(clipboard.storageURL, "Clipboard History")
        expectInRunFolder(clipboard.mediaDirectoryURL, "Clipboard History media")

        expectInRunFolder(JSONEventPersistence().url, "Shortcut Coach history")
        expectInRunFolder(DictationService(language: "en-US", allowsSystemAccess: false).recoveryURL, "The Dictation recovery file")
        expectInRunFolder(ScreenshotLocationResolver.system.resolve(), "The screenshot folder")
        expectInRunFolder(ScreencastRepositoryMemory.defaultStorageURL, "Screencast's repository memory")
    }

    @Test("An AppModel built without its stores keeps every one in this run's folder")
    func appModelDefaultsUseTheRunsFolder() throws {
        try requireIsolatedDefaults()
        let model = makeDefaultModel()

        expectInRunFolder(model.dictationHistory.recordingsDirectoryURL, "AppModel's Dictation History")
        expectInRunFolder(model.clipboard.storageURL, "AppModel's Clipboard History")
        expectInRunFolder(model.clipboard.mediaDirectoryURL, "AppModel's Clipboard History media")
        expectInRunFolder(model.dictation.recoveryURL, "AppModel's Dictation recovery file")
        expectInRunFolder(model.dictationModels.modelsRoot, "AppModel's Dictation models")
        expectInRunFolder(model.preferences.screencast.capturesFolder, "AppModel's Screencast captures")
    }

    /// Checked by type only: nothing reads or writes symbolic hotkeys here.
    @Test("Under the unit-test host, an AppModel's default symbolic-hotkey preferences are inert")
    func symbolicHotKeyDefaultsAreInert() throws {
        #expect(AppModel.defaultSymbolicHotKeyPreferences is InertSymbolicHotKeyPreferences)
        try requireIsolatedDefaults()
        let model = makeDefaultModel()

        let spotlight = try #require(model.spotlightShortcutResolver as? SpotlightShortcutConflictResolver)
        #expect(spotlight.preferences is InertSymbolicHotKeyPreferences, "The Spotlight shortcut check")
        let screenshots = try #require(model.capabilities.module(for: .screenshotTools) as? ScreenshotToolsModule)
        #expect(screenshots.systemShortcuts.preferences is InertSymbolicHotKeyPreferences, "The Screenshot Tools takeover")
    }

    @Test("Outside the unit-test host, Keybumps's folders are the user's own, as before")
    func productionPathsAreUnchanged() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybumps", isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybumps", isDirectory: true)

        let paths = ProductPaths.make(productDirectoryName: "Keybumps", fileManager: .default, sandboxRoot: nil, unitTestRoot: nil)

        #expect(paths.applicationSupport == support)
        #expect(paths.recordings == documents.appendingPathComponent("recordings", isDirectory: true))
        #expect(paths.captures == documents.appendingPathComponent("captures", isDirectory: true))
        #expect(paths.dictationModels == support.appendingPathComponent("DictationModels", isDirectory: true))
        #expect(paths.translatedSpeechTemporary == FileManager.default.temporaryDirectory
            .appendingPathComponent("Keybumps", isDirectory: true)
            .appendingPathComponent("TranslatedAudio", isDirectory: true))
    }

    @Test("The UI-test sandbox comes first, and a test's own rooted file manager is kept")
    func sandboxAndRootedFileManagersWin() {
        let sandbox = URL(fileURLWithPath: "/private/tmp/KeybumpsSandbox-\(UUID().uuidString)", isDirectory: true)
        let run = URL(fileURLWithPath: "/private/tmp/KeybumpsRun-\(UUID().uuidString)", isDirectory: true)
        let rootedRoot = URL(fileURLWithPath: "/private/tmp/KeybumpsRooted-\(UUID().uuidString)", isDirectory: true)

        let sandboxed = ProductPaths.make(productDirectoryName: "Keybumps", fileManager: .default, sandboxRoot: sandbox, unitTestRoot: run)
        for url in [sandboxed.applicationSupport, sandboxed.recordings, sandboxed.captures, sandboxed.dictationModels, sandboxed.translatedSpeechTemporary] {
            #expect(Self.isInside(url, sandbox))
        }

        let rooted = ProductPaths.make(
            productDirectoryName: "Keybumps",
            fileManager: TemporaryRootFileManager(root: rootedRoot),
            sandboxRoot: nil,
            unitTestRoot: run
        )
        #expect(Self.isInside(rooted.applicationSupport, rootedRoot))
        #expect(Self.isInside(rooted.recordings, rootedRoot))
        #expect(Self.isInside(rooted.captures, rootedRoot))
        #expect(Self.isInside(rooted.dictationModels, rootedRoot))
        // That file manager keeps the real temporary folder, so it moves to the run's folder.
        #expect(Self.isInside(rooted.translatedSpeechTemporary, run))
    }

    /// Scratch folders stand in for the user's: the owner's folders are never involved.
    @Test("A folder that is the user's own, or inside it, moves however it's spelled; one elsewhere is kept")
    func spellingsOfTheUsersFoldersMove() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("KeybumpsSpellings-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let user = scratch.appendingPathComponent("user", isDirectory: true)
        let link = scratch.appendingPathComponent("link", isDirectory: true)
        let run = scratch.appendingPathComponent("run", isDirectory: true)
        try fileManager.createDirectory(at: user, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: user)

        let users = FixedFoldersFileManager(in: user)
        func make(_ folders: FileManager) -> ProductPaths {
            ProductPaths.make(productDirectoryName: "Keybumps", fileManager: folders, sandboxRoot: nil, unitTestRoot: run, userFolders: users)
        }
        func moved(into subfolder: String?) -> ProductPaths {
            func root(_ name: String) -> URL {
                let folder = run.appendingPathComponent(name, isDirectory: true)
                return subfolder.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
            }
            let support = root("Application Support").appendingPathComponent("Keybumps", isDirectory: true)
            let documents = root("Documents").appendingPathComponent("Keybumps", isDirectory: true)
            return ProductPaths(
                applicationSupport: support,
                recordings: documents.appendingPathComponent("recordings", isDirectory: true),
                captures: documents.appendingPathComponent("captures", isDirectory: true),
                dictationModels: support.appendingPathComponent("DictationModels", isDirectory: true),
                translatedSpeechTemporary: root("tmp").appendingPathComponent("Keybumps", isDirectory: true)
                    .appendingPathComponent("TranslatedAudio", isDirectory: true)
            )
        }

        #expect(make(users) == moved(into: nil), "The user's folders as spelled")
        #expect(make(FixedFoldersFileManager(in: user, trailingSlash: false)) == moved(into: nil), "No trailing slash")
        // The temporary folder is under /private/var; its other spelling drops or adds /private.
        let otherSpelling = user.path.hasPrefix("/private/") ? String(user.path.dropFirst("/private".count)) : "/private" + user.path
        #expect(make(FixedFoldersFileManager(in: URL(fileURLWithPath: otherSpelling, isDirectory: true))) == moved(into: nil), "/var or /private/var")
        #expect(make(FixedFoldersFileManager(in: link)) == moved(into: nil), "Through a symlink")
        #expect(make(FixedFoldersFileManager(in: user.appendingPathComponent("x/..", isDirectory: true))) == moved(into: nil), "With ..")
        #expect(make(FixedFoldersFileManager(in: user, subfolder: "Nested")) == moved(into: "Nested"), "Inside the user's folders")

        let sibling = FixedFoldersFileManager(in: user, suffix: "-sibling")
        #expect(make(sibling) == ProductPaths.make(productDirectoryName: "Keybumps", fileManager: sibling, sandboxRoot: nil, unitTestRoot: nil),
                "A folder that only starts with the same name is kept")
        let elsewhere = FixedFoldersFileManager(in: scratch.appendingPathComponent("elsewhere", isDirectory: true))
        #expect(make(elsewhere) == ProductPaths.make(productDirectoryName: "Keybumps", fileManager: elsewhere, sandboxRoot: nil, unitTestRoot: nil),
                "A folder elsewhere is kept")
    }
}

/// Answers Application Support, Documents, and the temporary folder with folders under `root`.
private final class FixedFoldersFileManager: FileManager {
    private let support: URL
    private let documents: URL
    private let temporary: URL

    init(in root: URL, subfolder: String? = nil, suffix: String = "", trailingSlash: Bool = true) {
        func folder(_ name: String) -> URL {
            var url = root.appendingPathComponent(name + suffix, isDirectory: true)
            if let subfolder { url.appendPathComponent(subfolder, isDirectory: true) }
            return trailingSlash ? url : URL(fileURLWithPath: url.path, isDirectory: false)
        }
        support = folder("support")
        documents = folder("documents")
        temporary = folder("tmp")
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        switch directory {
        case .applicationSupportDirectory: [support]
        case .documentDirectory: [documents]
        default: []
        }
    }

    override var temporaryDirectory: URL { temporary }
}

private struct NoEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

private struct NoPresenceChanges: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}
