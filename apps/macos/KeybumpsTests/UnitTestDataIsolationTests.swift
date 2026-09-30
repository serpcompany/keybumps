import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Tests must never read or write the owner's data (#191). An `AppModel` built without its
/// Dictation History once listed the real Documents folder, so macOS asked for Documents access on
/// every test run. Like `InMemoryDefaultsTests` for preferences, this fails if a default location
/// goes back to the owner's folders. Paths are only computed here; the owner's folders are never
/// opened.
@MainActor
@Suite("Unit-test data isolation")
struct UnitTestDataIsolationTests {
    /// The installed app's folders.
    private static let ownerFolders: [URL] = [
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        FileManager.default.temporaryDirectory,
    ].map { $0.appendingPathComponent("Keybumps", isDirectory: true) }

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
        expectInRunFolder(paths.dictationModels, "\(what) Dictation models", sourceLocation: sourceLocation)
        expectInRunFolder(paths.translatedSpeechTemporary, "\(what) translated audio", sourceLocation: sourceLocation)
    }

    @Test("Under the unit-test host, every Keybumps folder is in this run's own temporary folder")
    func productPathsUseTheRunsFolder() {
        #expect(UnitTestHost.isActive)
        #expect(ProductPaths.sandboxRoot == nil, "Only UI test mode sets the sandbox")
        #expect(Self.isInside(UnitTestHost.dataDirectory, FileManager.default.temporaryDirectory))
        #expect(!Self.ownerFolders.contains { Self.isInside(UnitTestHost.dataDirectory, $0) })

        expectInRunFolder(ProductPaths.keybumps(), "The default")
        expectInRunFolder(ProductPaths.keybumps(fileManager: FileManager()), "A new file manager's")
    }

    @Test("Stores built with their default location keep their data in this run's folder")
    func defaultStoresUseTheRunsFolder() {
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
    }

    @Test("An AppModel built without its stores keeps every one in this run's folder")
    func appModelDefaultsUseTheRunsFolder() {
        let model = AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: NoEventPersistence()),
            presenceController: NoPresenceChanges(),
            detector: ManualActionDetector(),
            updater: DisabledUpdateController(reason: "Unit-test data isolation")
        )

        expectInRunFolder(model.dictationHistory.recordingsDirectoryURL, "AppModel's Dictation History")
        expectInRunFolder(model.clipboard.storageURL, "AppModel's Clipboard History")
        expectInRunFolder(model.clipboard.mediaDirectoryURL, "AppModel's Clipboard History media")
        expectInRunFolder(model.dictation.recoveryURL, "AppModel's Dictation recovery file")
        expectInRunFolder(model.dictationModels.modelsRoot, "AppModel's Dictation models")
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
        for url in [sandboxed.applicationSupport, sandboxed.recordings, sandboxed.dictationModels, sandboxed.translatedSpeechTemporary] {
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
        #expect(Self.isInside(rooted.dictationModels, rootedRoot))
        // That file manager keeps the real temporary folder, so it moves to the run's folder.
        #expect(Self.isInside(rooted.translatedSpeechTemporary, run))
    }
}

private struct NoEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

private struct NoPresenceChanges: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}
