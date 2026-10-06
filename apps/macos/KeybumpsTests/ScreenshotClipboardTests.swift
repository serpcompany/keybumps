import AppKit
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("New screenshots on the clipboard")
struct ScreenshotClipboardTests {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!

    @Test("A new screenshot goes on the clipboard, and Clipboard History doesn't add that copy again")
    func copiesNewScreenshots() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })

        #expect(delivery.add(shot))
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: shot)))
        // A newer item keeps the newest-item duplicate check from hiding a second add.
        fixture.clipboard.ingestForTesting("newer")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.map(\.kind) == [.text, .image])
        #expect(fixture.clipboard.entries.last?.isScreenshot == true)
        #expect(fixture.clipboard.entries.last?.sourceURL == shot)
    }

    @Test("Something copied after the screenshot was taken stays on the clipboard and reaches Clipboard History")
    func neverReplacesANewerCopy() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.clipboard.start()
        defer { fixture.clipboard.stop() }

        // Copied after the file landed but before the watcher delivered it, and not yet polled.
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("copied since", forType: .string)
        #expect(delivery.add(shot))

        #expect(fixture.pasteboard.string(forType: .string) == "copied since")
        #expect(fixture.clipboard.entries.map(\.kind) == [.image, .text])
        #expect(fixture.clipboard.entries.last?.text == "copied since")
    }

    @Test("Something copied before the screenshot was taken doesn't stop it being copied")
    func copiesOverAnOlderCopy() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.clipboard.start()
        defer { fixture.clipboard.stop() }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("copied before", forType: .string)
        fixture.clipboard.pollForTesting()

        let shot = try fixture.screenshot(createdAt: Date().addingTimeInterval(1))
        #expect(delivery.add(shot))
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: shot)))
    }

    @Test("Each new screenshot replaces the previous screenshot's copy")
    func newerScreenshotReplacesOlderCopy() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.clipboard.start()
        defer { fixture.clipboard.stop() }
        // Both files exist before either is delivered, like two displays or two quick shots.
        let first = try fixture.screenshot("Screenshot 1.png")
        let second = try fixture.screenshot("Screenshot 2.png")

        #expect(delivery.add(first))
        #expect(delivery.add(second))
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: second)))
    }

    @Test("Dictation's pasteboard write and a palette copy each count as newer copies")
    func suppressedWritesAndRestoresCountAsCopies() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.clipboard.start()
        defer { fixture.clipboard.stop() }

        let beforeDictation = try fixture.screenshot("Screenshot 1.png")
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("transcript", forType: .string)
        fixture.clipboard.suppressCurrentChange()
        #expect(delivery.add(beforeDictation))
        #expect(fixture.pasteboard.string(forType: .string) == "transcript")
        #expect(fixture.clipboard.entries.map(\.kind) == [.image], "Dictation's write is never recorded")

        fixture.clipboard.ingestForTesting("earlier item")
        let beforeRestore = try fixture.screenshot("Screenshot 2.png")
        let earlier = try #require(fixture.clipboard.entries.first)
        #expect(fixture.clipboard.restore(earlier))
        #expect(delivery.add(beforeRestore))
        #expect(fixture.pasteboard.string(forType: .string) == "earlier item")
    }

    @Test("While Clipboard History is stopped, adding a screenshot never records the pasteboard")
    func neverReadsThePasteboardWhileStopped() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("not for history", forType: .string)

        #expect(delivery.add(try fixture.screenshot()))
        #expect(fixture.clipboard.entries.map(\.kind) == [.image])
    }

    @Test("Screen and Edit adds every display's shot without copying, the main display's newest")
    func addsEditCaptureWithoutCopying() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        let main = try fixture.screenshot("Screenshot 1.png")
        let second = try fixture.screenshot("Screenshot 1 (2).png")
        let changeCount = fixture.pasteboard.changeCount

        #expect(delivery.addForEditing([main, second]) == main)
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.clipboard.entries.map(\.sourceURL) == [main, second])
    }

    @Test("With the setting off, or for the Screen and Edit hotkey, screenshots reach Clipboard History but leave the clipboard alone")
    func leavesClipboardAloneWhenNotCopying() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let off = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { false })
        let on = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        let changeCount = fixture.pasteboard.changeCount

        #expect(off.add(try fixture.screenshot("Screenshot 1.png")))
        #expect(on.add(try fixture.screenshot("Screenshot 2.png"), copying: false))
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.clipboard.entries.map(\.isScreenshot) == [true, true])
    }

    @Test("A screenshot file is added and copied once, so a later copy (like an edit's Save) stays on the clipboard")
    func addsEachFileOnce() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        #expect(delivery.add(shot))

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("copied since", forType: .string)
        fixture.clipboard.pollForTesting()

        #expect(!delivery.add(shot), "the watcher seeing the Screen and Edit hotkey's file again")
        #expect(fixture.pasteboard.string(forType: .string) == "copied since")
        #expect(fixture.clipboard.entries.map(\.kind) == [.text, .image])
    }

    @Test("Copying new screenshots is on by default and remembers being turned off")
    func preferenceDefaultsOn() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.copiesScreenshotsToClipboard)

        preferences.copiesScreenshotsToClipboard = false
        #expect(!AppPreferences(defaults: defaults).copiesScreenshotsToClipboard)
    }

    @MainActor
    fileprivate struct Fixture {
        let root: URL
        let pasteboard: NSPasteboard
        let clipboard: ClipboardHistoryService

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreenshotClipboard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreenshotClipboard-\(UUID().uuidString)"))
            clipboard = ClipboardHistoryService(
                storageURL: root.appendingPathComponent("history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true),
                sourceApps: .inert
            )
        }

        /// Each file gets its own pixels, so Clipboard History never treats two as the same item.
        func screenshot(_ name: String = "Screenshot 2026-09-30 at 10.00.00.png", createdAt: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(name)
            try (ScreenshotClipboardTests.png + Data(name.utf8)).write(to: url)
            if let createdAt { try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path) }
            return url
        }

        func tearDown() {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
@Suite("Clearing the Clipboard tab keeps screenshots in the Screenshots tab")
struct ClipboardTabClearTests {
    private typealias Fixture = ScreenshotClipboardTests.Fixture

    /// One item of each kind, newest first, and the original files two of them came from.
    private struct History {
        let text: ClipboardEntry
        let copiedImage: ClipboardEntry
        let copiedFile: ClipboardEntry
        let screenshot: ClipboardEntry
        let originals: [URL]
    }

    @Test("Clear All empties the Clipboard tab, deletes other items and their media, and keeps screenshots and their media")
    func clearingTheClipboardTabKeepsScreenshots() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)

        fixture.clipboard.clearClipboardTab()

        #expect(fixture.clipboard.clipboardTabEntries.isEmpty)
        #expect(fixture.clipboard.entries.map(\.id) == [history.screenshot.id])
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [history.screenshot.id])
        #expect(Self.exists(history.screenshot.imageURL), "the screenshot's media copy stays")
        #expect(!Self.exists(history.copiedImage.imageURL))
        #expect(!Self.exists(history.copiedFile.imageURL))
    }

    @Test("A cleared screenshot stays out of the Clipboard tab after a reload")
    func hiddenScreenshotsStayHiddenAfterReload() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        let reloaded = Self.reload(fixture)
        #expect(reloaded.clipboardTabEntries.isEmpty)
        #expect(Self.screenshotsTab(reloaded).map(\.id) == [history.screenshot.id])
    }

    @Test("History saved before this change loads with every item in the Clipboard tab")
    func olderHistoryDecodes() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let text = UUID()
        let screenshot = UUID()
        let saved = [
            #"{"id":"\#(text.uuidString)","text":"copied","capturedAt":1,"kind":"text","fingerprint":"text:copied"}"#,
            #"{"id":"\#(screenshot.uuidString)","text":"","capturedAt":0,"kind":"image","mediaPath":"/tmp/a.png","mediaPasteboardType":"public.png","sourcePath":"/d/Screenshot.png","isScreenCapture":true}"#
        ]
        try Data("[\(saved.joined(separator: ","))]".utf8).write(to: fixture.clipboard.storageURL)

        let loaded = Self.reload(fixture)
        #expect(loaded.clipboardTabEntries.map(\.id) == [text, screenshot])
        #expect(Self.screenshotsTab(loaded).map(\.id) == [screenshot])
    }

    @Test("A screenshot taken after the clear shows in both tabs")
    func newScreenshotShowsInBothTabs() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot("Screenshot 2.png")))
        let newShot = try #require(fixture.clipboard.entries.first)

        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [newShot.id])
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [newShot.id, history.screenshot.id])
    }

    @Test("Copying a cleared screenshot again, or taking one with the same pixels, puts it back in the Clipboard tab")
    func copyingAgainShowsItInTheClipboardTab() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        // Copied from the Screenshots tab.
        #expect(fixture.clipboard.restore(history.screenshot))
        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [history.screenshot.id])

        // A new file with the same pixels as the newest item adds nothing new.
        fixture.clipboard.clearClipboardTab()
        let samePixels = fixture.root.appendingPathComponent("Screenshot again.png")
        try FileManager.default.copyItem(at: history.originals[0], to: samePixels)
        #expect(!fixture.clipboard.ingestImageFile(at: samePixels))
        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [history.screenshot.id])
        #expect(Self.reload(fixture).clipboardTabEntries.map(\.id) == [history.screenshot.id], "and that's saved")
    }

    @Test("Delete in the Clipboard tab hides a screenshot there and deletes anything else")
    func deleteInTheClipboardTab() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)

        fixture.clipboard.removeFromClipboardTab(history.screenshot)
        fixture.clipboard.removeFromClipboardTab(history.text)

        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [history.copiedImage.id, history.copiedFile.id])
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [history.screenshot.id])
        #expect(Self.exists(history.screenshot.imageURL))
        #expect(Self.reload(fixture).entries.map(\.id) == [history.copiedImage.id, history.copiedFile.id, history.screenshot.id])
    }

    @Test("The Screenshots tab's Clear All removes screenshots from both tabs, hidden or not, and keeps everything else")
    func screenshotsClearRemovesThemEverywhere() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        let others = [history.text.id, history.copiedImage.id, history.copiedFile.id]
        fixture.clipboard.removeFromClipboardTab(history.screenshot)
        #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot("Screenshot 2.png")))
        let visibleShot = try #require(fixture.clipboard.entries.first)

        fixture.clipboard.clearScreenshots()

        #expect(fixture.clipboard.entries.map(\.id) == others)
        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == others)
        #expect(!Self.exists(history.screenshot.imageURL))
        #expect(!Self.exists(visibleShot.imageURL))
        #expect(Self.exists(history.copiedImage.imageURL))
        #expect(Self.exists(history.copiedFile.imageURL))
        #expect(Self.reload(fixture).entries.map(\.id) == others)
    }

    @Test("Neither Clear All touches the original files, only Keybumps' media copies")
    func originalFilesAreNeverTouched() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        let originalContents = try history.originals.map { try Data(contentsOf: $0) }

        fixture.clipboard.clearClipboardTab()
        #expect(try history.originals.map { try Data(contentsOf: $0) } == originalContents)
        fixture.clipboard.clearScreenshots()
        #expect(try history.originals.map { try Data(contentsOf: $0) } == originalContents)

        #expect(fixture.clipboard.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.clipboard.mediaDirectoryURL.path).isEmpty)
    }

    @Test("Hidden screenshots still count toward the 50 items and age out like any other")
    func hiddenScreenshotsCountTowardCapacity() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        for index in 1...ClipboardHistoryService.capacity { fixture.clipboard.ingestForTesting("item \(index)") }

        #expect(fixture.clipboard.entries.count == ClipboardHistoryService.capacity)
        #expect(Self.screenshotsTab(fixture.clipboard).isEmpty)
        #expect(!Self.exists(history.screenshot.imageURL))
    }

    /// Adds a screenshot, an image file copied in Finder, image data copied from an app, and text.
    private static func seed(_ fixture: Fixture) throws -> History {
        let screenshotFile = try fixture.screenshot()
        let copiedFile = try fixture.screenshot("Mockup.png")
        #expect(fixture.clipboard.ingestImageFile(at: screenshotFile))
        #expect(fixture.clipboard.ingestImageFile(at: copiedFile, isScreenCapture: false))
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setData(try Data(contentsOf: copiedFile) + Data("from an app".utf8), forType: .png)
        fixture.clipboard.pollForTesting()
        fixture.clipboard.ingestForTesting("copied text")

        let entries = fixture.clipboard.entries
        try #require(entries.count == 4)
        #expect(entries.map(\.isScreenshot) == [false, false, false, true])
        #expect(entries.dropFirst().allSatisfy { exists($0.imageURL) }, "each image has its own media copy")
        #expect(fixture.clipboard.clipboardTabEntries == entries)
        return History(
            text: entries[0],
            copiedImage: entries[1],
            copiedFile: entries[2],
            screenshot: entries[3],
            originals: [screenshotFile, copiedFile]
        )
    }

    private static func screenshotsTab(_ clipboard: ClipboardHistoryService) -> [ClipboardEntry] {
        ScreenshotPaletteContent.resolve(entries: clipboard.entries, query: "", isEnabled: true).entries
    }

    private static func reload(_ fixture: Fixture) -> ClipboardHistoryService {
        ClipboardHistoryService(
            storageURL: fixture.clipboard.storageURL,
            pasteboard: fixture.pasteboard,
            mediaDirectoryURL: fixture.clipboard.mediaDirectoryURL,
            sourceApps: .inert
        )
    }

    private static func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

@MainActor
@Suite("Copying a Clipboard History item")
struct ClipboardRestoreTests {
    private typealias Fixture = ScreenshotClipboardTests.Fixture

    @Test("An image whose stored copy can't be read copies nothing and leaves the clipboard as it was")
    func unreadableImageLeavesTheClipboardAlone() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot()))
        let image = try #require(fixture.clipboard.entries.first)
        try FileManager.default.removeItem(at: try #require(image.imageURL))
        let shot = try fixture.screenshot("Untyped.png")
        let untyped = ClipboardEntry(id: UUID(), text: "", capturedAt: Date(), kind: .image, mediaPath: shot.path)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("made-up clipboard text", forType: .string)
        let changeCount = fixture.pasteboard.changeCount
        let before = Date()

        #expect(!fixture.clipboard.restore(image), "its media file is gone")
        #expect(!fixture.clipboard.restore(untyped), "it has no pasteboard type")

        #expect(fixture.pasteboard.string(forType: .string) == "made-up clipboard text")
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(!fixture.clipboard.pasteboardChanged(since: before), "a failed copy isn't counted as one")
        // The copy made before the failed restores still reaches Clipboard History.
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.first?.text == "made-up clipboard text")
    }

    @Test("Text and a readable image still go on the clipboard")
    func textAndReadableImagesRestore() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        #expect(fixture.clipboard.ingestImageFile(at: shot))
        let image = try #require(fixture.clipboard.entries.first)
        fixture.clipboard.ingestForTesting("copied text")
        let text = try #require(fixture.clipboard.entries.first)

        #expect(fixture.clipboard.restore(image))
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: shot)))
        #expect(fixture.pasteboard.string(forType: .string) == nil)

        #expect(fixture.clipboard.restore(text))
        #expect(fixture.pasteboard.string(forType: .string) == "copied text")
        #expect(fixture.pasteboard.data(forType: .png) == nil)
    }
}
