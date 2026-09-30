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
        #expect(harness.service.entries.first?.sourceDomain == nil, "No page address on the pasteboard, no domain")
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
        #expect(entry.sourceDomain == nil)

        harness.apps.frontmost = Self.browser
        harness.copy("made-up text", pageAddress: "https://example.com/made-up")
        loaded.pollForTesting()
        let reloaded = harness.reloaded()
        #expect(reloaded.entries.map(\.sourceApp) == [Self.browser, nil])
        #expect(reloaded.entries.map(\.sourceDomain) == ["example.com", nil])
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
    }

    @Test("Universal Clipboard items from another device have no source app")
    func universalClipboard() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.notes

        harness.copy("made-up text", fromAnotherDevice: true, pageAddress: "https://example.com/")
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.text == "made-up text")
        #expect(harness.service.entries.first?.sourceApp == nil)
        #expect(harness.service.entries.first?.sourceDomain == nil)
    }

    // MARK: Source domain

    @Test("A Chromium copy keeps only the page's domain, never its full address")
    func chromiumDomain() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser

        harness.copy(
            "made-up text",
            pageAddress: "https://someone:made-up-password@Docs.Example.com:8443/private/page?token=made-up-secret#section"
        )
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceDomain == "docs.example.com")
        let saved = try String(contentsOf: harness.storageURL, encoding: .utf8)
        #expect(saved.contains("docs.example.com"))
        // The scheme, user name, password, port, path, query, and fragment are all gone.
        for part in ["https", "someone", "made-up-password", ":8443", "private", "page?", "token", "made-up-secret", "section"] {
            #expect(!saved.contains(part), "The saved history must not keep \(part)")
        }
        #expect(harness.reloaded().entries.first?.sourceDomain == "docs.example.com")
    }

    @Test("Only http and https addresses give a domain, and only their host")
    func hostRules() {
        let cases: [(address: String?, host: String?)] = [
            ("https://www.example.com/a/b?c=d#e", "www.example.com"),
            ("http://example.org", "example.org"),
            ("HTTPS://EXAMPLE.NET/Path", "example.net"),
            ("https://someone:made-up@example.com/", "example.com"),
            ("https://example.com:8080/", "example.com"),
            ("chrome://settings", nil),
            ("file:///Users/example/page.html", nil),
            ("chrome-extension://abcdef/page.html", nil),
            ("about:blank", nil),
            ("data:text/html,made-up", nil),
            ("https://", nil),
            ("not an address", nil),
            ("", nil),
            (nil, nil),
            // A lookalike or international domain keeps its punycode form, as browsers show it.
            ("https://xn--xample-2of.com/", "xn--xample-2of.com"),
            ("https://\u{0435}xample.com/", "xn--xample-2of.com"),
            // Escapes and control characters aren't hostname characters, so nothing is kept.
            ("https://exa%0Ample.com/", nil),
            ("https://exa%2Fmple.com/", nil),
            ("https://exa\nmple.com/", nil),
            ("https://my_site.example.com/", nil),
            // A trailing dot is dropped; an empty label isn't a hostname.
            ("https://example.com./", "example.com"),
            ("https://example..com/", nil),
            // IP addresses and local names aren't websites.
            ("https://192.168.1.10/", nil),
            ("http://10.0.0.1:8080/", nil),
            ("https://[::1]:8080/", nil),
            ("https://[2001:db8::1]/", nil),
            ("https://localhost:3000/", nil),
            ("https://app.localhost/", nil),
            ("http://intranet/", nil),
            // Local and special-use names aren't websites either.
            ("http://nas.local/", nil),
            ("https://app.test/", nil),
            ("https://db.corp.internal/", nil),
            ("http://printer.home.arpa/", nil),
            ("https://site.invalid/", nil),
            // An ordinary multi-label domain under a country code is kept whole.
            ("https://shop.example.co.uk/", "shop.example.co.uk")
        ]
        for (address, host) in cases {
            #expect(ClipboardSourceDomain.host(ofPageAddress: address) == host, "\((address ?? "nil").debugDescription)")
        }
    }

    @Test("URLComponents decodes a host, while its encoded host stays ASCII, so only the encoded host is used")
    func foundationHostBehavior() {
        let lookalike = URLComponents(string: "https://xn--xample-2of.com/")
        #expect(lookalike?.host == "\u{0435}xample.com")
        #expect(lookalike?.encodedHost == "xn--xample-2of.com")
        let escaped = URLComponents(string: "https://exa%0Ample.com/")
        #expect(escaped?.host == "exa\nmple.com")
        #expect(escaped?.encodedHost == "exa%0Ample.com")
        #expect(URLComponents(string: "https://\u{0435}xample.com/")?.encodedHost == "xn--xample-2of.com")
        #expect(URLComponents(string: "https://example.com./")?.encodedHost == "example.com.")
        #expect(URLComponents(string: "https://[::1]:8080/")?.encodedHost == "[::1]")
        #expect(URLComponents(string: "https://exa\nmple.com/") == nil)
    }

    @Test("A non-http page records the source app but no domain")
    func nonWebPage() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser

        harness.copy("made-up text", pageAddress: "chrome://settings/")
        harness.service.pollForTesting()

        #expect(harness.service.entries.first?.sourceApp == Self.browser)
        #expect(harness.service.entries.first?.sourceDomain == nil)
    }

    @Test("A Safari copy's web archive gives the page's domain")
    func safariWebArchive() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser

        harness.copy("made-up text", webArchive: try Self.webArchive(mainResourceAddress: "https://news.example.org/story?id=made-up"))
        harness.service.pollForTesting()
        #expect(harness.service.entries.first?.sourceDomain == "news.example.org")

        harness.copy("second made-up text", webArchive: try Self.webArchive(mainResourceAddress: "about:blank"))
        harness.service.pollForTesting()
        harness.copy("third made-up text", webArchive: Data("not a property list".utf8))
        harness.service.pollForTesting()
        #expect(harness.service.entries.prefix(2).map(\.sourceDomain) == [nil, nil])
    }

    @Test("A web archive over the size cap isn't decoded, so that item gets no domain")
    func largeWebArchive() throws {
        let cap = ClipboardSourceDomain.maximumWebArchiveBytes
        let justUnder = try Self.webArchive(mainResourceAddress: "https://example.com/", imageBytes: cap - 4_096)
        let over = try Self.webArchive(mainResourceAddress: "https://example.com/", imageBytes: cap)
        #expect(justUnder.count <= cap)
        #expect(over.count > cap)
        #expect(ClipboardSourceDomain.mainResourceAddress(ofWebArchive: justUnder) == "https://example.com/")
        #expect(ClipboardSourceDomain.mainResourceAddress(ofWebArchive: over) == nil)

        let harness = Harness()
        defer { harness.cleanUp() }
        harness.apps.frontmost = Self.browser
        harness.copy("first made-up text", webArchive: justUnder)
        harness.service.pollForTesting()
        #expect(harness.service.entries.first?.sourceDomain == "example.com")

        harness.copy("second made-up text", webArchive: over)
        harness.service.pollForTesting()
        #expect(harness.service.entries.first?.text == "second made-up text")
        #expect(harness.service.entries.first?.sourceApp == Self.browser)
        #expect(harness.service.entries.first?.sourceDomain == nil)
    }

    /// The shape of WebKit's `com.apple.webarchive` data, with a made-up page and, optionally, a
    /// made-up image subresource of the given size.
    static func webArchive(mainResourceAddress: String, imageBytes: Int = 0) throws -> Data {
        var archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceURL": mainResourceAddress,
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceFrameName": "",
                "WebResourceData": Data("<p>made-up</p>".utf8)
            ] as [String: Any]
        ]
        if imageBytes > 0 {
            archive["WebSubresources"] = [[
                "WebResourceURL": "https://example.com/made-up.png",
                "WebResourceMIMEType": "image/png",
                "WebResourceData": Data(count: imageBytes)
            ] as [String: Any]]
        }
        return try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
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

    @Test("Search matches content anywhere, the source app from a word's start, and the domain from a label's start")
    func searchBySource() {
        let entry = ClipboardEntry(
            id: UUID(),
            text: "made-up text",
            capturedAt: Date(),
            sourceApp: ClipboardSourceApp(bundleIdentifier: "com.example.writer", name: "Example TextWriter"),
            sourceDomain: "www.docs.example.com"
        )
        for query in ["made-up", "de-up t", "example", "EXAMPLE TEXT", "writer", "docs", "docs.ex", "example.com", "www.docs"] {
            #expect(entry.matches(query), "\(query)")
        }
        for query in ["com", ".com", "www", "www.", "ample", "riter", "ocs", "e.com", "org"] {
            #expect(!entry.matches(query), "\(query)")
        }

        #expect(ClipboardSourceSearch.matchesWordStart("writer", in: "9Writer"))
        #expect(ClipboardSourceSearch.matchesWordStart("edit", in: "Example TextEdit"))
        #expect(!ClipboardSourceSearch.matchesWordStart("", in: "Example TextEdit"))

        // Under a country code, a common second-level label (`co.uk`, `com.au`) counts as the suffix.
        for (query, domain, matches) in [
            ("shop", "shop.example.com.au", true),
            ("example.com.au", "shop.example.com.au", true),
            ("com", "shop.example.com.au", false),
            ("au", "shop.example.com.au", false),
            ("example.co", "news.example.co.uk", true),
            ("co", "news.example.co.uk", false),
            ("uk", "news.example.co.uk", false),
            ("co", "example.co", false),
            ("example", "example.co", true)
        ] {
            #expect(ClipboardSourceSearch.matchesLabelStart(query, in: domain) == matches, "\(query) in \(domain)")
        }

        let unknown = ClipboardEntry(id: UUID(), text: "made-up text", capturedAt: Date())
        #expect(unknown.matches("made-up"))
        #expect(!unknown.matches("example"))
        #expect(unknown.searchableText == "made-up text", "The source isn't part of the content")
    }

    @Test("A copy made while a Keybumps window is key, such as the Command Palette, is credited to Keybumps")
    func keybumpsWindowIsKey() {
        let keybumps = ClipboardSourceApp(bundleIdentifier: "com.example.keybumps", name: "Keybumps")
        #expect(ClipboardSourceAppReader.appInFront(keybumpsHasKeyWindow: true, keybumps: keybumps, frontmost: Self.browser) == keybumps)
        #expect(ClipboardSourceAppReader.appInFront(keybumpsHasKeyWindow: false, keybumps: keybumps, frontmost: Self.browser) == Self.browser)
        #expect(ClipboardSourceAppReader.appInFront(keybumpsHasKeyWindow: true, keybumps: nil, frontmost: Self.browser) == Self.browser)
    }

    @Test("The inert reader used by tests and UI tests never names an app")
    func inertReader() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsClipboardInert-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsClipboardInert-\(UUID().uuidString)"))
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let service = ClipboardHistoryService(
            fileManager: TemporaryRootFileManager(root: root),
            storageURL: root.appendingPathComponent("history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true),
            sourceApps: .inert
        )
        pasteboard.clearContents()
        pasteboard.setString("made-up text", forType: .string)
        pasteboard.setString("com.example.writer", forType: .nspasteboardSource)
        service.pollForTesting()
        #expect(service.entries.first?.text == "made-up text")
        #expect(service.entries.first?.sourceApp == nil)
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

    @Test("The Screenshot Editor's Save marks its copy as Keybumps', so it isn't credited to the app in front")
    func screenshotEditorSaveMarksItsCopy() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let ownIdentifier = try #require(Bundle.main.bundleIdentifier)
        let keybumps = ClipboardSourceApp(bundleIdentifier: ownIdentifier, name: "Keybumps")
        harness.apps.frontmost = Self.browser
        harness.apps.installed = [ownIdentifier: keybumps]
        let saveFolder = harness.root.appendingPathComponent("edited", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)

        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())

        // Never presented, so no window appears; Save only renders, copies, and writes the edited file.
        let editor = ScreenshotEditorWindowController(
            source: ScreenshotRenderSource(cgImage: image, pointSize: CGSize(width: 8, height: 8)),
            sourceURL: nil,
            fallbackFolder: saveFolder,
            pasteboard: harness.pasteboard
        )
        var result: ScreenshotEditorWindowController.Result?
        editor.onFinish = { result = $0 }
        editor.save()

        #expect(result?.copied == true)
        #expect(result?.savedURL != nil, "A failed save would have shown an alert")
        #expect(harness.pasteboard.data(forType: .png) != nil)
        #expect(harness.pasteboard.string(forType: .nspasteboardSource) == ownIdentifier)
        harness.service.pollForTesting()
        #expect(harness.service.entries.first?.kind == .image)
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

    func copy(
        _ text: String,
        marker: String? = nil,
        fromAnotherDevice: Bool = false,
        pageAddress: String? = nil,
        webArchive: Data? = nil
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let marker { pasteboard.setString(marker, forType: .nspasteboardSource) }
        if fromAnotherDevice { pasteboard.setData(Data([0x31]), forType: .universalClipboard) }
        if let pageAddress { pasteboard.setString(pageAddress, forType: .chromiumSourceURL) }
        if let webArchive { pasteboard.setData(webArchive, forType: .webArchive) }
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

/// Keeps a service's Application Support folder inside a test's temporary root.
final class TemporaryRootFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}
