import AppKit
import XCTest
@testable import Keybumps

@MainActor
final class ScreenshotToolsTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-tools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Location

    func testLocationFallsBackToDesktopWhenUnsetBlankOrMissing() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        for preferred in [nil, "", "   ", "/Volumes/Gone/Shots"] as [String?] {
            let resolver = ScreenshotLocationResolver(preferredLocation: { preferred }, homeDirectory: home, isDirectory: { _ in false })
            XCTAssertEqual(resolver.resolve(), desktop)
        }
    }

    func testLocationExpandsTildeAndAcceptsExistingFolders() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let tilde = ScreenshotLocationResolver(preferredLocation: { "~/Pictures/Shots" }, homeDirectory: home, isDirectory: { _ in true })
        XCTAssertEqual(tilde.resolve().path, "/Users/example/Pictures/Shots")
        let absolute = ScreenshotLocationResolver(preferredLocation: { "/tmp/shots/" }, homeDirectory: home, isDirectory: { _ in true })
        XCTAssertEqual(absolute.resolve().path, "/tmp/shots")
    }

    // MARK: Filtering and file-system reader

    func testFilterAcceptsOnlyNewScreenCaptureImages() {
        let start = Date(timeIntervalSince1970: 1_000)
        func entry(_ name: String, created: TimeInterval, capture: Bool) -> ScreenshotDirectoryEntry {
            ScreenshotDirectoryEntry(url: root.appendingPathComponent(name), createdAt: Date(timeIntervalSince1970: created), size: 10, isScreenCapture: capture)
        }
        XCTAssertTrue(ScreenshotFileFilter.accepts(entry("a.png", created: 1_001, capture: true), since: start))
        XCTAssertTrue(ScreenshotFileFilter.accepts(entry("a.HEIC", created: 1_000, capture: true), since: start))
        XCTAssertFalse(ScreenshotFileFilter.accepts(entry("old.png", created: 999, capture: true), since: start))
        XCTAssertFalse(ScreenshotFileFilter.accepts(entry("photo.png", created: 1_001, capture: false), since: start))
        XCTAssertFalse(ScreenshotFileFilter.accepts(entry("doc.pdf", created: 1_001, capture: true), since: start))
    }

    func testFileSystemReaderDetectsScreenCaptureAttributeAndSkipsHiddenFiles() throws {
        let capture = root.appendingPathComponent("capture.png")
        let plain = root.appendingPathComponent("plain.png")
        let hidden = root.appendingPathComponent(".pending.png")
        let text = root.appendingPathComponent("notes.txt")
        for url in [capture, plain, hidden, text] { try png.write(to: url) }
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let result = value.withUnsafeBytes {
            setxattr(capture.path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, $0.baseAddress, value.count, 0, 0)
        }
        XCTAssertEqual(result, 0)

        let entries = try FileSystemScreenshotDirectoryReader().entries(in: root)
        XCTAssertEqual(Set(entries.map(\.url.lastPathComponent)), ["capture.png", "plain.png"])
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "capture.png" }?.isScreenCapture, true)
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "plain.png" }?.isScreenCapture, false)
        XCTAssertEqual(entries.first?.size, png.count)
    }

    func testFileSystemReaderReportsMissingFolderAsUnavailable() {
        XCTAssertThrowsError(try FileSystemScreenshotDirectoryReader().entries(in: root.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? ScreenshotFolderReadError, .unavailable)
        }
    }

    // MARK: Service

    func testServiceRequiresClipboardHistoryAndStopsWhenDisabled() {
        let reader = FakeScreenshotReader()
        var ingested: [URL] = []
        let service = makeService(reader: reader) { ingested.append($0); return true }

        service.apply(enabled: true, clipboardHistoryEnabled: false)
        XCTAssertEqual(service.status, .requiresClipboardHistory)

        service.apply(enabled: true, clipboardHistoryEnabled: true)
        XCTAssertEqual(service.status, .watching(root))

        service.apply(enabled: false, clipboardHistoryEnabled: true)
        XCTAssertEqual(service.status, .stopped)
        reader.entries = [screenshot("new.png", created: 2_000)]
        service.scanForTesting(); service.scanForTesting()
        XCTAssertTrue(ingested.isEmpty)
    }

    func testServiceReportsDeniedFolderAccess() {
        let reader = FakeScreenshotReader()
        reader.error = .accessDenied
        let service = makeService(reader: reader) { _ in true }
        service.apply(enabled: true, clipboardHistoryEnabled: true)
        XCTAssertEqual(service.status, .folderAccessDenied(root))
    }

    func testServiceIngestsEachNewScreenshotOnceAfterItsSizeSettles() {
        let reader = FakeScreenshotReader()
        reader.entries = [screenshot("before.png", created: 500)]
        var ingested: [String] = []
        let service = makeService(reader: reader) { ingested.append($0.lastPathComponent); return true }
        service.apply(enabled: true, clipboardHistoryEnabled: true)

        reader.entries.append(screenshot("new.png", created: 2_000, size: 10))
        reader.entries.append(ScreenshotDirectoryEntry(url: root.appendingPathComponent("photo.png"), createdAt: Date(timeIntervalSince1970: 2_000), size: 10, isScreenCapture: false))
        service.scanForTesting()
        XCTAssertTrue(ingested.isEmpty, "first sighting only records the size")

        reader.entries[1] = screenshot("new.png", created: 2_000, size: 20)
        service.scanForTesting()
        XCTAssertTrue(ingested.isEmpty, "a growing file is still being written")

        service.scanForTesting()
        XCTAssertEqual(ingested, ["new.png"])
        service.scanForTesting(); service.scanForTesting()
        XCTAssertEqual(ingested, ["new.png"])
    }

    // MARK: Clipboard History ingestion

    func testClipboardIngestsScreenshotFilesWithSourceAndRestoresExactImage() throws {
        let storageURL = root.appendingPathComponent("history.json")
        let mediaURL = root.appendingPathComponent("media", isDirectory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreenshotClipboard-\(UUID().uuidString)"))
        let shot = root.appendingPathComponent("Screenshot 2026-09-28 at 9.41.00 AM.png")
        try png.write(to: shot)
        let service = ClipboardHistoryService(storageURL: storageURL, pasteboard: pasteboard, mediaDirectoryURL: mediaURL)
        let changeCountBefore = pasteboard.changeCount

        XCTAssertTrue(service.ingestImageFile(at: shot))
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore, "ingestion must not write the pasteboard")
        let entry = try XCTUnwrap(service.entries.first)
        XCTAssertTrue(entry.isScreenshot)
        XCTAssertEqual(entry.kindLabel, "Screenshot")
        XCTAssertEqual(entry.displayText, "Screenshot 2026-09-28 at 9.41.00 AM")
        XCTAssertEqual(entry.sourceURL, shot)
        XCTAssertNotEqual(entry.imageURL, shot, "Clipboard History keeps its own media copy")

        let reloaded = ClipboardHistoryService(storageURL: storageURL, pasteboard: pasteboard, mediaDirectoryURL: mediaURL)
        XCTAssertEqual(reloaded.entries.first, entry)

        XCTAssertTrue(service.restore(entry))
        XCTAssertEqual(pasteboard.data(forType: .png), png)

        service.delete(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.path), "deleting history never deletes the original screenshot")
    }

    func testClipboardRejectsNonImageAndEmptyFiles() throws {
        let service = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("history.json"),
            pasteboard: NSPasteboard(name: NSPasteboard.Name("KeybumpsScreenshotReject-\(UUID().uuidString)")),
            mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true)
        )
        let pdf = root.appendingPathComponent("capture.pdf")
        let empty = root.appendingPathComponent("empty.png")
        try png.write(to: pdf)
        try Data().write(to: empty)
        XCTAssertFalse(service.ingestImageFile(at: pdf))
        XCTAssertFalse(service.ingestImageFile(at: empty))
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testCopiedImagesKeepTheirExistingLabels() {
        let copied = ClipboardEntry(id: UUID(), text: "", capturedAt: Date(), kind: .image, mediaPath: "/tmp/x.png", mediaPasteboardType: "public.png")
        XCTAssertFalse(copied.isScreenshot)
        XCTAssertEqual(copied.displayText, "Image")
        XCTAssertEqual(copied.kindLabel, "Image")
    }

    // MARK: Capability migration

    func testScreenshotToolsIsEnabledOnceForExistingInstallsAndThenRespected() {
        let suite = "KeybumpsScreenshotMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clipboardHistory", "quickSearch", "windowManagement"], forKey: "enabledCapabilities")

        let upgraded = AppPreferences(defaults: defaults)
        XCTAssertEqual(upgraded.enabledCapabilities, [.clipboardHistory, .quickSearch, .windowManagement, .screenshotTools])
        XCTAssertEqual(AppPreferences(defaults: defaults).enabledCapabilities, upgraded.enabledCapabilities)

        upgraded.setCapability(.screenshotTools, enabled: false)
        XCTAssertFalse(AppPreferences(defaults: defaults).enabledCapabilities.contains(.screenshotTools))
    }

    // MARK: Helpers

    private func makeService(reader: FakeScreenshotReader, ingest: @escaping (URL) -> Bool) -> ScreenshotToolsService {
        let folder = root!
        return ScreenshotToolsService(
            resolver: ScreenshotLocationResolver(preferredLocation: { folder.path }, homeDirectory: folder, isDirectory: { _ in true }),
            reader: reader,
            now: { Date(timeIntervalSince1970: 1_000) },
            ingest: ingest
        )
    }

    private func screenshot(_ name: String, created: TimeInterval, size: Int = 10) -> ScreenshotDirectoryEntry {
        ScreenshotDirectoryEntry(url: root.appendingPathComponent(name), createdAt: Date(timeIntervalSince1970: created), size: size, isScreenCapture: true)
    }
}

private final class FakeScreenshotReader: ScreenshotDirectoryReading {
    var entries: [ScreenshotDirectoryEntry] = []
    var error: ScreenshotFolderReadError?

    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
        if let error { throw error }
        return entries
    }
}
