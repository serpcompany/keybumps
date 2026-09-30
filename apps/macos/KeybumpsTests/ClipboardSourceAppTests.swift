import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Clipboard History's source app. Every app here is made up; tests never read the app in front,
/// the real pasteboard, or real folders.
@MainActor
@Suite("Clipboard History source app")
struct ClipboardSourceAppTests {
    static let notes = ClipboardSourceApp(bundleIdentifier: "com.example.notes", name: "Example Notes")
    static let browser = ClipboardSourceApp(bundleIdentifier: "com.example.browser", name: "Example Browser")
    static let writer = ClipboardSourceApp(bundleIdentifier: "com.example.writer", name: "Example Writer")
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!

    @Test("A new copy records the app in front, and it is still there after a relaunch")
    func recordsAppInFront() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes

        harness.copy("made-up text")
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == Self.notes)
        #expect(harness.reloaded().entries.first?.sourceApp == Self.notes)
    }

    @Test("History saved before source apps existed loads unchanged, with no source app")
    func legacyHistoryLoads() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","text":"saved before","capturedAt":700000000,"kind":"text",\
        "fingerprint":"text:saved before","isScreenCapture":false}]
        """
        try Data(legacy.utf8).write(to: harness.storageURL)

        let loaded = harness.reloaded()
        let entry = try #require(loaded.entries.first)
        #expect(loaded.entries.count == 1)
        #expect(entry.id == id)
        #expect(entry.text == "saved before")
        #expect(entry.kind == .text)
        #expect(entry.sourceApp == nil)

        harness.apps.frontmost = Self.notes
        harness.copy("made-up text")
        loaded.pollForTesting()
        #expect(harness.reloaded().entries.map(\.sourceApp) == [Self.notes, nil])
    }

    @Test("An app switch just before the poll credits the app that was in front at the previous poll")
    func switchJustBeforePoll() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes
        harness.apps.uptime = 100
        harness.service.pollForTesting()

        harness.copy("made-up text")
        harness.apps.frontmost = Self.browser
        harness.apps.uptime = 100.45
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == Self.notes)
    }

    @Test("Polls far apart, as with a throttled timer, credit the app in front now")
    func pollsFarApart() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes
        harness.apps.uptime = 100
        harness.service.pollForTesting()

        harness.copy("made-up text")
        harness.apps.frontmost = Self.browser
        harness.apps.uptime = 105
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == Self.browser)
    }

    @Test("Choosing between two polls")
    func frontmostSourceRules() {
        typealias Sample = ClipboardSourceTracker.Sample
        let notesEarlier = Sample(app: Self.notes, uptime: 10)
        #expect(ClipboardSourceTracker.frontmostSource(latest: nil, previous: nil) == nil)
        #expect(ClipboardSourceTracker.frontmostSource(latest: Sample(app: Self.notes, uptime: 10), previous: nil) == Self.notes)
        #expect(ClipboardSourceTracker.frontmostSource(latest: Sample(app: Self.notes, uptime: 10.45), previous: notesEarlier) == Self.notes)
        #expect(ClipboardSourceTracker.frontmostSource(latest: Sample(app: Self.browser, uptime: 11), previous: notesEarlier) == Self.notes)
        #expect(ClipboardSourceTracker.frontmostSource(latest: Sample(app: Self.browser, uptime: 11.01), previous: notesEarlier) == Self.browser)
        #expect(
            ClipboardSourceTracker.frontmostSource(latest: Sample(app: Self.browser, uptime: 10.45), previous: Sample(app: nil, uptime: 10))
                == Self.browser,
            "Nothing in front at the previous poll leaves the app in front now"
        )
        #expect(ClipboardSourceTracker.frontmostSource(latest: Sample(app: nil, uptime: 10.45), previous: notesEarlier) == Self.notes)
    }

    @Test("An org.nspasteboard.source marker names the source app, whatever is in front")
    func markerNamesSource() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser
        harness.apps.installed = ["com.example.writer": Self.writer]

        harness.copy("made-up text", marker: "com.example.writer")
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == Self.writer)
    }

    @Test("An empty marker, or one naming an app this Mac doesn't have, means no source app")
    func unknownMarker() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser

        harness.copy("first made-up text", marker: "")
        harness.service.pollForTesting()
        harness.copy("second made-up text", marker: "com.example.missing")
        harness.service.pollForTesting()

        #expect(harness.service.entries.map(\.text) == ["second made-up text", "first made-up text"])
        #expect(harness.service.entries.allSatisfy { $0.sourceApp == nil })
        #expect(ClipboardSourceApp.installed(bundleIdentifier: "com.example.keybumps-tests.missing") == nil)
    }

    @Test("Universal Clipboard items from another device have no source app")
    func universalClipboard() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes

        harness.copy("made-up text", fromAnotherDevice: true)
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.text == "made-up text")
        #expect(harness.service.entries.first?.sourceApp == nil)
    }

    @Test("Screenshots from Screenshot Tools have no source app")
    func screenshotsHaveNone() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes
        let shot = harness.root.appendingPathComponent("Screenshot made-up.png")
        try Self.png.write(to: shot)

        #expect(harness.service.ingestImageFile(at: shot))

        #expect(harness.service.entries.first?.isScreenshot == true)
        #expect(harness.service.entries.first?.sourceApp == nil)
    }

    @Test("A copied image file records the app it was copied from")
    func copiedImageFile() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes
        let file = harness.root.appendingPathComponent("made-up.png")
        try Self.png.write(to: file)

        harness.pasteboard.clearContents()
        harness.pasteboard.writeObjects([file as NSURL])
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.kind == .image)
        #expect(harness.service.entries.first?.sourceApp == Self.notes)
    }

    @Test("Search finds items by their source app's name")
    func searchBySourceApp() {
        let fromNotes = ClipboardEntry(id: UUID(), text: "made-up text", capturedAt: Date(), sourceApp: Self.notes)
        let unknown = ClipboardEntry(id: UUID(), text: "made-up text", capturedAt: Date())

        #expect(fromNotes.searchableText.localizedCaseInsensitiveContains("example notes"))
        #expect(fromNotes.searchableText.localizedCaseInsensitiveContains("made-up"))
        #expect(!unknown.searchableText.localizedCaseInsensitiveContains("example notes"))
        #expect(unknown.searchableText == "made-up text")
    }

    @Test("Keybumps marks its own recorded copies, so they aren't credited to the app in front")
    func keybumpsMarksItsCopies() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let ownIdentifier = try #require(Bundle.main.bundleIdentifier)
        let keybumps = ClipboardSourceApp(bundleIdentifier: ownIdentifier, name: "Keybumps")
        harness.apps.frontmost = Self.browser
        harness.apps.installed = [ownIdentifier: keybumps]

        #expect(DictationHistoryClipboard.copy("made-up transcript", to: harness.pasteboard))
        #expect(harness.pasteboard.string(forType: .string) == "made-up transcript")
        #expect(harness.pasteboard.string(forType: .nspasteboardSource) == ownIdentifier)
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == keybumps)
    }
}

@MainActor
private final class FakeSourceApps {
    var frontmost: ClipboardSourceApp?
    var installed: [String: ClipboardSourceApp] = [:]
    var uptime: TimeInterval = 1_000

    var reader: ClipboardSourceAppReader {
        ClipboardSourceAppReader(
            frontmost: { self.frontmost },
            application: { self.installed[$0] },
            uptime: { self.uptime }
        )
    }
}

@MainActor
private struct Harness {
    let root: URL
    let pasteboard: NSPasteboard
    let apps: FakeSourceApps
    let service: ClipboardHistoryService

    init() {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsClipboardSource-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsClipboardSource-\(id)"))
        apps = FakeSourceApps()
        service = Self.makeService(root: root, pasteboard: pasteboard, apps: apps)
    }

    var storageURL: URL { root.appendingPathComponent("history.json") }

    func reloaded() -> ClipboardHistoryService {
        Self.makeService(root: root, pasteboard: pasteboard, apps: apps)
    }

    func copy(_ text: String, marker: String? = nil, fromAnotherDevice: Bool = false) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let marker { pasteboard.setString(marker, forType: .nspasteboardSource) }
        if fromAnotherDevice { pasteboard.setData(Data([0x31]), forType: .universalClipboard) }
    }

    func cleanUp() {
        service.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeService(root: URL, pasteboard: NSPasteboard, apps: FakeSourceApps) -> ClipboardHistoryService {
        ClipboardHistoryService(
            fileManager: TemporaryRootFileManager(root: root),
            storageURL: root.appendingPathComponent("history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true),
            sourceApps: apps.reader
        )
    }
}

/// Keeps the service's Application Support folder inside the test's temporary root.
private final class TemporaryRootFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}
