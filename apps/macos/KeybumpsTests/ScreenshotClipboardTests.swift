import AppKit
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("New screenshots on the clipboard")
struct ScreenshotClipboardTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!

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
        // macOS's file is copied into ScreenGrabs' history, which the item names; macOS's stays (#605).
        let kept = fixture.clipboard.screenshotsFolder.appendingPathComponent(shot.lastPathComponent)
        #expect(fixture.clipboard.entries.last?.sourceURL == kept)
        #expect(fixture.clipboard.entries.last?.imageURL == kept)
        #expect(FileManager.default.contentsEqual(atPath: kept.path, andPath: shot.path))
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
        // Saved in ScreenGrabs' history, as the hotkeys save them.
        let main = try fixture.screenshot("Screenshot 1.png", inHistory: true)
        let second = try fixture.screenshot("Screenshot 1 (2).png", inHistory: true)
        let changeCount = fixture.pasteboard.changeCount

        #expect(delivery.addForEditing([main, second]) == main)
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.clipboard.entries.map(\.sourceURL) == [main, second])
    }

    @Test("A Screen capture adds every display's shot, the main display's newest, and copies only it")
    func addsScreenCaptureCopyingTheMainDisplay() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        let start = fixture.pasteboard.changeCount
        #expect(delivery.add(try fixture.screenshot("Earlier.png")))
        let oneCopy = fixture.pasteboard.changeCount - start
        let files = try ["1", "1 (2)", "1 (3)"].map { try fixture.screenshot("Screenshot \($0).png", inHistory: true) }
        let before = fixture.pasteboard.changeCount

        delivery.addCapture(files)
        let sources = fixture.clipboard.entries.prefix(3).compactMap(\.sourceURL)
        #expect(sources == files)
        #expect(fixture.pasteboard.changeCount - before == oneCopy, "copied once")
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: files[0])))
    }

    @Test("The Screen hotkey's files are saved in ScreenGrabs' history, copied where macOS saves screenshots, and added when screencapture exits, never by the watcher, which never adds the copies (#605)")
    func screenHotkeyAddsItsOwnFiles() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let capture = HotkeyCapture(fixture)
        defer { capture.watcher.stop() }
        var written: [URL] = []
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher) { written = $0 }

        // screencapture marks display 1 before it exits.
        capture.scan()
        #expect(fixture.clipboard.entries.isEmpty)
        capture.runner.finish?()
        #expect(written.count == 3)
        #expect(written.allSatisfy { ScreengrabFiles.isDirectly($0, in: fixture.clipboard.screenshotsFolder) }, "in the history")
        for file in written {
            let copy = fixture.root.appendingPathComponent(file.lastPathComponent)
            #expect(FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path), "and a copy where macOS saves screenshots")
        }
        let listed = ScreenshotPaletteContent.resolve(entries: fixture.clipboard.entries, query: "", isEnabled: true)
        #expect(listed.entries.compactMap(\.sourceURL) == written, "⌘3, the main display's on top, naming the history's files")
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: written[0])), "⌘V")

        capture.scan()
        #expect(fixture.clipboard.entries.count == 3, "the watcher doesn't add the copies")
    }

    @Test("Screen and Edit adds its files the same way, copying none to the clipboard; Screen adds none while Clipboard History is off, but keeps them in the history and copies them, and the next launch lists them (#605)")
    func editAndOffCaptures() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let capture = HotkeyCapture(fixture)
        defer { capture.watcher.stop() }
        let changeCount = fixture.pasteboard.changeCount
        var written: [URL] = []
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher, forEditing: true) { written = $0 }
        capture.scan()
        capture.runner.finish?()
        #expect(fixture.clipboard.entries.compactMap(\.sourceURL) == written && written.count == 3)
        #expect(fixture.pasteboard.changeCount == changeCount)

        let off = try Fixture()
        defer { off.tearDown() }
        let offCapture = HotkeyCapture(off)
        defer { offCapture.watcher.stop() }
        offCapture.watcher.apply(enabled: true, clipboardHistoryEnabled: false)
        offCapture.delivery.capture(.screens, with: offCapture.capturer, watcher: offCapture.watcher) { written = $0 }
        offCapture.runner.finish?()
        #expect(written.count == 3 && off.clipboard.entries.isEmpty)
        #expect(written.allSatisfy { FileManager.default.fileExists(atPath: off.root.appendingPathComponent($0.lastPathComponent).path) }, "copied")
        #expect(off.clipboard.adoptScreenshots() == 3, "listed at the next launch")
        let listed = ScreenshotPaletteContent.resolve(entries: off.clipboard.entries, query: "", isEnabled: true)
        #expect(Set(listed.entries.compactMap(\.sourceURL)) == Set(written))
        #expect(off.clipboard.clipboardTabEntries.isEmpty, "never copied, so not in the Clipboard tab")
    }

    @Test("Area and Edit (⇧⌘4, #545) adds its one file without copying it; a selection cancelled with Escape writes and adds nothing")
    func areaAndEditCapture() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let capture = HotkeyCapture(fixture)
        defer { capture.watcher.stop() }
        let changeCount = fixture.pasteboard.changeCount
        var written: [URL] = []
        capture.delivery.capture(.area, with: capture.capturer, watcher: capture.watcher, forEditing: true) { written = $0 }
        capture.scan()
        #expect(fixture.clipboard.entries.isEmpty, "the watcher leaves the hotkey's file alone")
        capture.runner.finish?()
        #expect(written.count == 1)
        #expect(fixture.clipboard.entries.compactMap(\.sourceURL) == written, "the file the editor opens")
        #expect(fixture.pasteboard.changeCount == changeCount, "copied only when the editor saves")
        capture.scan()
        #expect(fixture.clipboard.entries.count == 1, "the watcher doesn't add it again")

        let cancelled = try Fixture()
        defer { cancelled.tearDown() }
        let cancel = HotkeyCapture(cancelled)
        defer { cancel.watcher.stop() }
        cancel.runner.writes = false
        written = [URL(fileURLWithPath: "/not-called")]
        cancel.delivery.capture(.area, with: cancel.capturer, watcher: cancel.watcher, forEditing: true) { written = $0 }
        cancel.runner.finish?()
        #expect(written.isEmpty && cancelled.clipboard.entries.isEmpty)
    }

    @Test("A hotkey screenshot reaches Clipboard History and ⌘3, and is copied, while Keybumps can't read macOS's folder")
    func hotkeyWithoutTheWatcher() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let capture = HotkeyCapture(fixture, reader: DeniedScreenshotReader())
        defer { capture.watcher.stop() }
        guard case .folderAccessDenied = capture.watcher.status else {
            Issue.record("the watcher can't read macOS's folder")
            return
        }
        var written: [URL] = []
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher) { written = $0 }
        capture.runner.finish?()

        #expect(written.count == 3)
        #expect(written.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == fixture.clipboard.screenshotsFolder.standardizedFileURL })
        #expect(written.allSatisfy { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent($0.lastPathComponent).path) }, "copied")
        let listed = ScreenshotPaletteContent.resolve(entries: fixture.clipboard.entries, query: "", isEnabled: true)
        #expect(listed.entries.compactMap(\.sourceURL) == written, "⌘3, the main display's on top")
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: written[0])), "⌘V")
    }

    @Test("A hotkey screenshot's copy the watcher sees, where macOS saves them however that's spelled, isn't added or copied again")
    func hotkeyScreenshotTheWatcherSeesIsAddedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // Where macOS saves screenshots, through a link.
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreenshotLink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: link) }
        let capture = HotkeyCapture(fixture, copyingTo: link)
        defer { capture.watcher.stop() }
        var written: [URL] = []
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher) { written = $0 }
        capture.runner.finish?()
        let changeCount = fixture.pasteboard.changeCount

        // The watcher's first look comes after the hotkey added them, as when it's slow to scan.
        capture.scan()
        #expect(written.count == 3)
        #expect(written.allSatisfy { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent($0.lastPathComponent).path) }, "copied")
        #expect(fixture.clipboard.entries.compactMap(\.sourceURL) == written)
        #expect(fixture.pasteboard.changeCount == changeCount, "on the clipboard once")
    }

    @Test("A cancelled Area capture leaves its path to the watcher, so a macOS screenshot there still reaches ⌘3, when macOS saves screenshots in ScreenGrabs' history")
    func cancelledAreaFreesItsPath() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let capture = HotkeyCapture(fixture, copyingTo: fixture.clipboard.screenshotsFolder)
        defer { capture.watcher.stop() }
        capture.runner.writes = false
        capture.delivery.capture(.area, with: capture.capturer, watcher: capture.watcher)
        capture.runner.finish?()

        let path = try #require(capture.runner.files.first)
        FileManager.default.createFile(atPath: path, contents: ScreenshotClipboardTests.png)
        HeldRunner.mark(path)
        capture.scan()
        let listed = ScreenshotPaletteContent.resolve(entries: fixture.clipboard.entries, query: "", isEnabled: true)
        #expect(listed.entries.compactMap(\.sourceURL?.standardizedFileURL.path) == [path], "⌘3")
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

    /// A Screen capture through the hotkey's path: the real capturer, with a stand-in for
    /// `screencapture` that writes three displays' PNGs, marks display 1 as it does, and exits only
    /// when the test says (`finish`); and a watcher on where macOS saves screenshots.
    @MainActor
    struct HotkeyCapture {
        let runner = HeldRunner(png: ScreenshotClipboardTests.png)
        let capturer: ScreenshotCapturer
        let watcher: ScreenshotToolsService
        let delivery: ScreenshotClipboardDelivery

        /// The hotkeys save in the fixture's ScreenGrabs history, as the app's do (#605), and copy
        /// each screenshot where macOS saves them, which the watcher watches: `folder`, else the
        /// fixture's folder, a stand-in for the Desktop.
        init(_ fixture: Fixture, copyingTo folder: URL? = nil, reader: (any ScreenshotDirectoryReading)? = nil) {
            let macOSFolder = folder ?? fixture.root
            let history = fixture.clipboard.screenshotsFolder
            try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            let delivery = ScreenshotClipboardDelivery(
                clipboard: fixture.clipboard,
                copiesToClipboard: { true },
                copies: ScreengrabCopies(folder: { macOSFolder })
            )
            self.delivery = delivery
            capturer = ScreenshotCapturer(runner: runner, folder: { history }, displayCount: { 3 })
            watcher = ScreenshotToolsService(
                resolver: ScreenshotLocationResolver(preferredLocation: { macOSFolder.path }, homeDirectory: fixture.root, isDirectory: { _ in true }),
                reader: reader ?? FileSystemScreenshotDirectoryReader(),
                now: { .distantPast },
                ingest: { delivery.add($0) }
            )
            watcher.apply(enabled: true, clipboardHistoryEnabled: true)
        }

        /// Scans as often as the watcher needs to add a settled file.
        func scan() {
            for _ in 1...3 { watcher.scanForTesting() }
        }
    }

    /// macOS's screenshot folder as Keybumps reads it without Files & Folders access.
    fileprivate struct DeniedScreenshotReader: ScreenshotDirectoryReading {
        func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
            throw ScreenshotFolderReadError.accessDenied
        }
    }

    /// `writes: false` stands in for an Area capture cancelled with Escape: no file.
    final class HeldRunner: ScreenshotCaptureRunning {
        let png: Data
        var writes = true
        private(set) var files: [String] = []
        private(set) var finish: (@MainActor () -> Void)?

        init(png: Data) { self.png = png }

        func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
            files = arguments.filter { $0.hasSuffix(".png") }
            if writes {
                for file in files {
                    FileManager.default.createFile(atPath: file, contents: png + Data(file.utf8))
                }
                files.first.map(Self.mark)
            }
            finish = completion
        }

        /// Gives a file macOS's screen-capture metadata.
        static func mark(_ path: String) {
            guard let mark = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
            _ = mark.withUnsafeBytes {
                setxattr(path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, $0.baseAddress, mark.count, 0, 0)
            }
        }
    }

    @MainActor
    struct Fixture {
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

        /// Each file gets its own pixels, so Clipboard History never treats two as the same item. In
        /// the fixture's folder, as macOS saves one on the Desktop, or `inHistory`, in ScreenGrabs'
        /// history, as the hotkeys save them.
        func screenshot(_ name: String = "Screenshot 2026-09-30 at 10.00.00.png", createdAt: Date? = nil, inHistory: Bool = false) throws -> URL {
            let folder = inHistory ? clipboard.screenshotsFolder : root
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
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
    fileprivate typealias Fixture = ScreenshotClipboardTests.Fixture

    /// One item of each kind, newest first, and the original files two of them came from.
    private struct History {
        let text: ClipboardEntry
        let copiedImage: ClipboardEntry
        let copiedFile: ClipboardEntry
        let screenshot: ClipboardEntry
        let originals: [URL]
    }

    @Test("Clear All empties the Clipboard tab, deletes other items and their media, and keeps screenshots and their files")
    func clearingTheClipboardTabKeepsScreenshots() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)

        fixture.clipboard.clearClipboardTab()

        #expect(fixture.clipboard.clipboardTabEntries.isEmpty)
        #expect(fixture.clipboard.entries.map(\.id) == [history.screenshot.id])
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [history.screenshot.id])
        #expect(Self.exists(history.screenshot.imageURL), "the screenshot's file in ScreenGrabs' history stays")
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

    @Test("Copying a cleared screenshot again puts it back in the Clipboard tab; a new screenshot with the same pixels is a screenshot of its own (#605)")
    func copyingAgainShowsItInTheClipboardTab() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        // Copied from the Screenshots tab.
        #expect(fixture.clipboard.restore(history.screenshot))
        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [history.screenshot.id])

        fixture.clipboard.clearClipboardTab()
        #expect(Self.reload(fixture).clipboardTabEntries.isEmpty, "and that's saved")

        // A new file with the same pixels is its own file in the history, so its own item.
        let samePixels = fixture.root.appendingPathComponent("Screenshot again.png")
        try FileManager.default.copyItem(at: history.originals[0], to: samePixels)
        let again = try #require(fixture.clipboard.addScreenshot(at: samePixels))
        #expect(fixture.clipboard.clipboardTabEntries.map(\.id) == [again.id])
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [again.id, history.screenshot.id])
        #expect(again.imageURL != history.screenshot.imageURL)
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

    @Test("Neither Clear All touches the files macOS saved or that were copied, only Keybumps' media copies and, for the Screenshots tab's, the files in ScreenGrabs' history, which go to the Trash (#605)")
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.clipboard.screenshotsFolder.path).isEmpty)
    }

    @Test("A hidden screenshot is never pushed out: not by copies, nor by more than 50 newer screenshots (#605)")
    func hiddenScreenshotsAreNeverPushedOut() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let history = try Self.seed(fixture)
        fixture.clipboard.clearClipboardTab()

        for index in 1...ClipboardHistoryService.capacity { fixture.clipboard.ingestForTesting("item \(index)") }
        #expect(Self.screenshotsTab(fixture.clipboard).map(\.id) == [history.screenshot.id])
        #expect(Self.exists(history.screenshot.imageURL))

        for index in 1...60 {
            #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot("Screenshot \(index).png")))
        }
        #expect(Self.screenshotsTab(fixture.clipboard).count == 61)
        #expect(Self.screenshotsTab(fixture.clipboard).last?.id == history.screenshot.id)
        #expect(Self.exists(history.screenshot.imageURL))
        #expect(Self.reload(fixture).entries.filter(\.isScreenshot).count == 61, "and after a reload")
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
        #expect(entries.dropFirst().allSatisfy { exists($0.imageURL) }, "each image has its file: a copy in media/, or the screenshot's in ScreenGrabs' history")
        #expect(entries[3].imageURL?.deletingLastPathComponent().standardizedFileURL == fixture.clipboard.screenshotsFolder.standardizedFileURL)
        #expect(fixture.clipboard.clipboardTabEntries == entries)
        return History(
            text: entries[0],
            copiedImage: entries[1],
            copiedFile: entries[2],
            screenshot: entries[3],
            originals: [screenshotFile, copiedFile]
        )
    }

    fileprivate static func screenshotsTab(_ clipboard: ClipboardHistoryService) -> [ClipboardEntry] {
        ScreenshotPaletteContent.resolve(entries: clipboard.entries, query: "", isEnabled: true).entries
    }

    fileprivate static func reload(_ fixture: Fixture) -> ClipboardHistoryService {
        ClipboardHistoryService(
            storageURL: fixture.clipboard.storageURL,
            pasteboard: fixture.pasteboard,
            mediaDirectoryURL: fixture.clipboard.mediaDirectoryURL,
            sourceApps: .inert
        )
    }

    fileprivate static func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

@MainActor
@Suite("Clipboard History keeps its newest 50 copies, and every screenshot (#605)")
struct ClipboardHistoryLimitTests {
    private typealias Fixture = ScreenshotClipboardTests.Fixture
    private typealias Tabs = ClipboardTabClearTests

    @Test("120 screenshots and 60 copies keep every screenshot and the newest 50 copies; pruned copies' media files go, screenshots keep none there, and the files macOS saved stay")
    func keepsEveryScreenshot() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        for index in 0..<120 {
            #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot("Screenshot \(index).png")))
            if index.isMultiple(of: 2) { fixture.clipboard.ingestForTesting("copy \(index / 2)") }
        }

        let entries = fixture.clipboard.entries
        let screenshots = entries.filter(\.isScreenshot).map(\.displayText)
        let copies = entries.filter { !$0.isScreenshot }.map(\.text)
        #expect(screenshots == (0..<120).reversed().map { "Screenshot \($0)" })
        #expect(copies == (10..<60).reversed().map { "copy \($0)" })
        #expect(try Self.mediaFiles(fixture).isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: fixture.clipboard.screenshotsFolder.path)
        #expect(Set(kept) == Set(entries.filter(\.isScreenshot).compactMap(\.imageURL?.lastPathComponent)) && kept.count == 120)
        #expect(Tabs.screenshotsTab(fixture.clipboard).count == 120, "the ScreenGrabs tab lists every one")
        #expect(Tabs.exists(fixture.root.appendingPathComponent("Screenshot 0.png")), "originals stay")
        #expect(Tabs.reload(fixture).entries.map(\.id) == entries.map(\.id))
    }

    @Test("History saved at the old shared limit loads unchanged, and new items push none of it out")
    func historyAtTheOldLimitLoadsUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let saved = (0..<50).map { Self.savedItem($0, isScreenshot: $0.isMultiple(of: 5), fixture) }
        try JSONEncoder().encode(saved).write(to: fixture.clipboard.storageURL)

        let upgraded = Tabs.reload(fixture)
        #expect(upgraded.entries == saved)
        #expect(upgraded.clipboardTabEntries == saved)

        #expect(upgraded.ingestImageFile(at: try fixture.screenshot()))
        upgraded.ingestForTesting("new copy")
        #expect(Array(upgraded.entries.dropFirst(2)) == saved)
        #expect(upgraded.clipboardTabEntries == Array(upgraded.entries.prefix(50)))
    }

    @Test("History past the limits loads every screenshot and the newest 50 copies")
    func historyPastTheLimitsLoadsTheNewest() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let screenshots = (0..<60).map { Self.savedItem($0, isScreenshot: true, fixture) }
        let copies = (60..<120).map { Self.savedItem($0, isScreenshot: false, fixture) }
        try JSONEncoder().encode(screenshots + copies).write(to: fixture.clipboard.storageURL)

        let loaded = Tabs.reload(fixture).entries
        #expect(loaded == screenshots + Array(copies.prefix(50)))
    }

    @Test("The Clipboard tab lists the newest 50, and its Delete only hides a screenshot")
    func clipboardTabListsTheNewestFifty() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        for index in 0..<50 { fixture.clipboard.ingestForTesting("copy \(index)") }
        for index in 0..<50 {
            #expect(fixture.clipboard.ingestImageFile(at: try fixture.screenshot("Screenshot \(index).png")))
        }
        let newest = try #require(fixture.clipboard.entries.first)
        #expect(fixture.clipboard.clipboardTabEntries.allSatisfy { $0.isScreenshot })

        fixture.clipboard.removeFromClipboardTab(newest)

        let tab = fixture.clipboard.clipboardTabEntries
        #expect(tab.count == 50)
        #expect(!tab.contains { $0.id == newest.id })
        #expect(tab.last?.text == "copy 49")
        #expect(fixture.clipboard.entries.count == 100)
        #expect(Tabs.screenshotsTab(fixture.clipboard).first?.id == newest.id)
        #expect(Tabs.exists(newest.imageURL))

        // Its Clear All also deletes the copies it no longer lists.
        fixture.clipboard.clearClipboardTab()
        #expect(fixture.clipboard.entries.allSatisfy { $0.isScreenshot })
        #expect(fixture.clipboard.entries.count == 50)
        #expect(fixture.clipboard.clipboardTabEntries.isEmpty)
    }

    @Test("Copying a screenshot's file in Finder moves the screenshot up and keeps it in the ScreenGrabs tab")
    func copyingAScreenshotsFileKeepsTheScreenshot() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let file = try fixture.screenshot()
        #expect(fixture.clipboard.ingestImageFile(at: file))
        let shot = try #require(fixture.clipboard.entries.first)
        fixture.clipboard.ingestForTesting("copied text")
        fixture.clipboard.removeFromClipboardTab(shot)

        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([file as NSURL])
        fixture.clipboard.pollForTesting()

        #expect(fixture.clipboard.entries.first == shot, "unchanged, and in the Clipboard tab again")
        #expect(fixture.clipboard.entries.count == 2)
        #expect(Tabs.screenshotsTab(fixture.clipboard).map(\.id) == [shot.id])
        #expect(Tabs.exists(shot.imageURL))
        #expect(try Self.mediaFiles(fixture).isEmpty, "no media copy")
    }

    /// An item as a build with one shared limit saved it, newest first by `index`.
    private static func savedItem(_ index: Int, isScreenshot: Bool, _ fixture: Fixture) -> ClipboardEntry {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
        guard isScreenshot else {
            return ClipboardEntry(id: UUID(), text: "saved \(index)", capturedAt: capturedAt, fingerprint: "text:saved \(index)")
        }
        return ClipboardEntry(
            id: UUID(),
            text: "",
            capturedAt: capturedAt,
            kind: .image,
            mediaPath: fixture.clipboard.mediaDirectoryURL.appendingPathComponent("\(index).png").path,
            mediaPasteboardType: "public.png",
            fingerprint: "image:\(index)",
            sourcePath: fixture.root.appendingPathComponent("Screenshot \(index).png").path,
            isScreenCapture: true
        )
    }

    private static func mediaFiles(_ fixture: Fixture) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: fixture.clipboard.mediaDirectoryURL.path))
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
        let emptyFile = fixture.root.appendingPathComponent("Empty.png")
        try Data().write(to: emptyFile)
        let empty = ClipboardEntry(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            kind: .image,
            mediaPath: emptyFile.path,
            mediaPasteboardType: NSPasteboard.PasteboardType.png.rawValue
        )
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("made-up clipboard text", forType: .string)
        let changeCount = fixture.pasteboard.changeCount

        #expect(!fixture.clipboard.restore(image), "its media file is gone")
        #expect(!fixture.clipboard.restore(untyped), "it has no pasteboard type")
        #expect(!fixture.clipboard.restore(empty), "its media file is empty")

        #expect(fixture.pasteboard.string(forType: .string) == "made-up clipboard text")
        #expect(fixture.pasteboard.changeCount == changeCount)
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
