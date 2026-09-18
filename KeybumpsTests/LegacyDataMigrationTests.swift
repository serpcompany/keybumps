import AppKit
import CryptoKit
import XCTest
@testable import Keybumps

@MainActor
final class LegacyDataMigrationTests: XCTestCase {
    private var temporaryRoot: URL!
    private var legacyDefaults: UserDefaults!
    private var destinationDefaults: UserDefaults!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        legacyDefaults = isolatedDefaults(named: "legacy")
        destinationDefaults = isolatedDefaults(named: "destination")
    }

    override func tearDownWithError() throws {
        legacyDefaults.removePersistentDomain(forName: suiteName("legacy"))
        destinationDefaults.removePersistentDomain(forName: suiteName("destination"))
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testFirstMigrationCopiesDurableDataRebasesClipboardMediaAndLeavesLegacyBytesUntouched() throws {
        let fixture = try makeFixture()
        let imageID = UUID()
        let legacyMedia = fixture.legacy.applicationSupport
            .appendingPathComponent("clipboard-media/\(imageID.uuidString).png")
        try write(Data([0x89, 0x50, 0x4e, 0x47]), to: legacyMedia)
        let legacyClipboard: [[String: Any]] = [[
            "id": imageID.uuidString,
            "text": "",
            "capturedAt": 0,
            "kind": "image",
            "mediaPath": legacyMedia.path,
            "mediaPasteboardType": NSPasteboard.PasteboardType.png.rawValue,
            "fingerprint": "image:fixture"
        ]]
        try writeJSON(legacyClipboard, to: fixture.legacy.applicationSupport.appendingPathComponent("clipboard-history.json"))
        try write(Data("transcript".utf8), to: fixture.legacy.applicationSupport.appendingPathComponent("last-dictation.txt"))
        try write(Data("audio".utf8), to: fixture.legacy.recordings.appendingPathComponent("123/output.wav"))
        try write(Data("metadata".utf8), to: fixture.legacy.recordings.appendingPathComponent("123/meta.json"))

        legacyDefaults.set(["quickSearch", "shortcutCoaching"], forKey: "enabledCapabilities")
        legacyDefaults.set(true, forKey: "didCompleteOnboarding")
        legacyDefaults.set(true, forKey: "launchAtLogin")
        let legacyDefaultsSnapshot = try XCTUnwrap(
            legacyDefaults.persistentDomain(forName: suiteName("legacy"))
        ) as NSDictionary
        let sourceSnapshot = try directorySnapshot(fixture.legacy.applicationSupport)
        let recordingsSnapshot = try directorySnapshot(fixture.legacy.recordings)

        try fixture.migrator.migrateIfNeeded()

        XCTAssertEqual(destinationDefaults.integer(forKey: LegacyDataMigrator.markerKey), 1)
        XCTAssertEqual(
            destinationDefaults.stringArray(forKey: "enabledCapabilities"),
            ["quickSearch", "keyboardShortcutter"]
        )
        XCTAssertNil(destinationDefaults.object(forKey: "didCompleteOnboarding"))
        XCTAssertNil(destinationDefaults.object(forKey: "launchAtLogin"))
        XCTAssertEqual(
            legacyDefaults.persistentDomain(forName: suiteName("legacy")) as NSDictionary?,
            legacyDefaultsSnapshot
        )
        XCTAssertEqual(try directorySnapshot(fixture.legacy.applicationSupport), sourceSnapshot)
        XCTAssertEqual(try directorySnapshot(fixture.legacy.recordings), recordingsSnapshot)

        let migratedData = try Data(contentsOf: fixture.destination.applicationSupport.appendingPathComponent("clipboard-history.json"))
        let migratedEntries = try JSONDecoder().decode([ClipboardEntry].self, from: migratedData)
        let migratedEntry = try XCTUnwrap(migratedEntries.first)
        XCTAssertEqual(
            migratedEntry.mediaPath,
            fixture.destination.applicationSupport
                .appendingPathComponent("clipboard-media/\(imageID.uuidString).png").path
        )

        try FileManager.default.moveItem(
            at: fixture.legacy.applicationSupport,
            to: fixture.legacy.applicationSupport.appendingPathExtension("unavailable")
        )
        let pasteboard = NSPasteboard(name: .init("KeybumpsMigrationTests-\(UUID().uuidString)"))
        let clipboard = ClipboardHistoryService(
            storageURL: fixture.destination.applicationSupport.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: fixture.destination.applicationSupport.appendingPathComponent("clipboard-media")
        )
        XCTAssertTrue(clipboard.restore(migratedEntry))
        XCTAssertEqual(pasteboard.data(forType: .png), Data([0x89, 0x50, 0x4e, 0x47]))
    }

    func testPartialDestinationAndConflictsKeepDestinationRecordsAndDoNotCreateHybridRecordings() throws {
        let fixture = try makeFixture()
        try writeJSON([["id": "legacy", "text": "legacy"]], to: fixture.legacy.applicationSupport.appendingPathComponent("coaching-events.json"))
        try writeJSON([["id": "destination", "text": "newer"]], to: fixture.destination.applicationSupport.appendingPathComponent("coaching-events.json"))
        try write(Data("legacy audio".utf8), to: fixture.legacy.recordings.appendingPathComponent("123/output.wav"))
        try write(Data("legacy metadata".utf8), to: fixture.legacy.recordings.appendingPathComponent("123/meta.json"))
        try write(Data("destination metadata".utf8), to: fixture.destination.recordings.appendingPathComponent("123/meta.json"))

        try fixture.migrator.migrateIfNeeded()

        let records = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.destination.applicationSupport.appendingPathComponent("coaching-events.json"))
        ) as? [[String: Any]]
        XCTAssertEqual(records?.compactMap { $0["id"] as? String }, ["destination", "legacy"])
        XCTAssertEqual(
            try String(contentsOf: fixture.destination.recordings.appendingPathComponent("123/meta.json")),
            "destination metadata"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.destination.recordings.appendingPathComponent("123/output.wav").path
        ))
    }

    func testSecondMigrationIsIdempotent() throws {
        let fixture = try makeFixture()
        try writeJSON([["id": "legacy", "text": "legacy"]], to: fixture.legacy.applicationSupport.appendingPathComponent("coaching-events.json"))
        try fixture.migrator.migrateIfNeeded()
        let firstSnapshot = try directorySnapshot(fixture.destination.applicationSupport)

        try fixture.migrator.migrateIfNeeded()

        XCTAssertEqual(try directorySnapshot(fixture.destination.applicationSupport), firstSnapshot)
    }

    func testFailureDoesNotSetMarkerAndRetryCanComplete() throws {
        let fixture = try makeFixture()
        try write(Data("blocking file".utf8), to: fixture.destination.applicationSupport)

        XCTAssertThrowsError(try fixture.migrator.migrateIfNeeded())
        XCTAssertEqual(destinationDefaults.integer(forKey: LegacyDataMigrator.markerKey), 0)

        try FileManager.default.removeItem(at: fixture.destination.applicationSupport)
        try fixture.migrator.migrateIfNeeded()
        XCTAssertEqual(destinationDefaults.integer(forKey: LegacyDataMigrator.markerKey), 1)
    }

    func testLegacyProcessBlocksPreparationBeforeMigration() throws {
        let fixture = try makeFixture()
        let preparation = KeybumpsStartupPreparation(
            processDetector: LegacyAppProcessDetector(isRunningHandler: { _ in true }),
            migrator: fixture.migrator
        )

        XCTAssertThrowsError(try preparation.prepare()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .legacyAppRunning)
        }
        XCTAssertEqual(destinationDefaults.integer(forKey: LegacyDataMigrator.markerKey), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.applicationSupport.path))
    }

    func testClipboardNeverDeletesMediaOutsideItsOwnedDirectory() throws {
        let fixture = try makeFixture()
        let outsideFile = temporaryRoot.appendingPathComponent("must-remain.png")
        try write(Data("outside".utf8), to: outsideFile)
        let entry = ClipboardEntry(
            id: UUID(),
            text: "",
            capturedAt: .now,
            kind: .image,
            mediaPath: outsideFile.path,
            mediaPasteboardType: NSPasteboard.PasteboardType.png.rawValue,
            fingerprint: "image:outside"
        )
        let storageURL = fixture.destination.applicationSupport.appendingPathComponent("clipboard-history.json")
        try write(JSONEncoder().encode([entry]), to: storageURL)
        let clipboard = ClipboardHistoryService(
            storageURL: storageURL,
            pasteboard: NSPasteboard(name: .init("KeybumpsMigrationTests-\(UUID().uuidString)")),
            mediaDirectoryURL: fixture.destination.applicationSupport.appendingPathComponent("clipboard-media")
        )

        clipboard.clear()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testLegacyInstallationDetectionUsesOnlyReadOnlyLegacySignals() throws {
        let fixture = try makeFixture()
        let detector = LegacyInstallationDetector(
            paths: fixture.legacy,
            defaults: legacyDefaults,
            defaultsDomainName: suiteName("legacy"),
            applicationURLs: []
        )
        XCTAssertFalse(detector.isPresent)

        try write(Data("legacy".utf8), to: fixture.legacy.applicationSupport.appendingPathComponent("sentinel"))

        XCTAssertTrue(detector.isPresent)
    }

    private func makeFixture() throws -> (
        legacy: ProductPaths,
        destination: ProductPaths,
        migrator: LegacyDataMigrator
    ) {
        let legacy = ProductPaths(
            applicationSupport: temporaryRoot.appendingPathComponent("legacy/Application Support", isDirectory: true),
            recordings: temporaryRoot.appendingPathComponent("legacy/Documents/recordings", isDirectory: true),
            translatedSpeechTemporary: temporaryRoot.appendingPathComponent("legacy/tmp", isDirectory: true)
        )
        let destination = ProductPaths(
            applicationSupport: temporaryRoot.appendingPathComponent("destination/Application Support", isDirectory: true),
            recordings: temporaryRoot.appendingPathComponent("destination/Documents/recordings", isDirectory: true),
            translatedSpeechTemporary: temporaryRoot.appendingPathComponent("destination/tmp", isDirectory: true)
        )
        return (
            legacy,
            destination,
            LegacyDataMigrator(
                legacyPaths: legacy,
                destinationPaths: destination,
                legacyDefaults: legacyDefaults,
                destinationDefaults: destinationDefaults
            )
        )
    }

    private func isolatedDefaults(named name: String) -> UserDefaults {
        let suite = suiteName(name)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func suiteName(_ name: String) -> String {
        "com.serp.keybumps.tests.migration.\(name).\(temporaryRoot?.lastPathComponent ?? "setup")"
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
    }

    private func directorySnapshot(_ root: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )!
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return result
    }
}
