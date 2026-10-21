import AppKit
import Darwin
import Foundation
import Testing
@testable import Keybumps

/// ScreenGrabs' history in the Keybumps folder (#605): every screenshot is kept in
/// `screengrabs/screenshots/` and every recording in `screengrabs/recordings/`, and the ScreenGrabs
/// tab lists them from there, every one. Each new one also gets a copy where macOS saves
/// screenshots, which is the person's: removing it never touches the history. Screenshots and
/// recordings kept before #605 are brought into the history at launch (`ScreengrabsHistoryMove`).
/// Everything runs in temporary folders, with a stand-in for the Desktop, `InMemoryDefaults`, a
/// named pasteboard, and made-up content.
@MainActor
@Suite("ScreenGrabs' history in the Keybumps folder, with a copy on the Desktop (#605)")
struct ScreengrabsHistoryTests {
    typealias Fixture = ScreenshotClipboardTests.Fixture
    typealias HotkeyCapture = ScreenshotClipboardTests.HotkeyCapture

    // MARK: Where it's kept

    @Test("The history is the Keybumps folder's screengrabs/screenshots/ and screengrabs/recordings/, whatever folder was chosen before; an edited screenshot goes into the history too")
    func historyIsInTheKeybumpsFolder() throws {
        let paths = ProductPaths.keybumps()
        #expect(paths.screengrabsScreenshots == paths.keybumpsFolder.appendingPathComponent("screengrabs/screenshots", isDirectory: true))
        #expect(paths.screengrabsRecordings == paths.keybumpsFolder.appendingPathComponent("screengrabs/recordings", isDirectory: true))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreengrabsHistory-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(ClipboardHistoryService(pasteboard: pasteboard, sourceApps: .inert).screenshotsFolder == paths.screengrabsScreenshots, "where the hotkeys save, and macOS's are copied")

        // Folders chosen in Settings › ScreenGrabs before #605 are no longer used.
        let defaults = InMemoryDefaults()
        for key in ["screengrabs.screenshotsFolder", "screengrabs.recordingsFolder"] { defaults.set("/Users/someone/Chosen", forKey: key) }
        #expect(AppPreferences.chosenScreengrabFolderPaths(in: defaults).count == 2, "kept for the launch's moves")
        #expect(AppPreferences(defaults: defaults).screencast.capturesFolder == paths.screengrabsRecordings, "where recordings are saved")

        // A screenshot's edited copy is a screenshot of its own in the history, under a free name.
        let source = paths.screengrabsScreenshots.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00.png")
        let edited = ScreenshotEditorOutput.destination(
            sourceURL: source,
            fallbackFolder: paths.screengrabsScreenshots,
            besideSource: false,
            isWritableDirectory: { _ in true },
            exists: { $0.lastPathComponent == "Screenshot 2026-10-21 at 10.00.00 (edited).png" }
        )
        #expect(edited == paths.screengrabsScreenshots.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00 (edited 2).png"))
    }

    // MARK: New screenshots and recordings

    @Test("A hotkey screenshot lands in the history and as a copy on the Desktop; removing the copy keeps it listed and usable, also after a relaunch")
    func screenshotKeepsItsHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let desktop = Self.desktop(in: fixture.root)
        let capture = HotkeyCapture(fixture, copyingTo: desktop)
        defer { capture.watcher.stop() }
        var written: [URL] = []
        capture.delivery.capture(.area, with: capture.capturer, watcher: capture.watcher) { written = $0 }
        capture.runner.finish?()

        let file = try #require(written.first)
        #expect(written.count == 1)
        #expect(ScreengrabFiles.isDirectly(file, in: fixture.clipboard.screenshotsFolder), "in the history")
        let copy = desktop.appendingPathComponent(file.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path), "and a copy on the Desktop")
        let entry = try #require(fixture.clipboard.entries.first)
        #expect(entry.sourceURL == file && entry.imageURL == file, "the item names the history's file")

        try FileManager.default.removeItem(at: copy)
        capture.scan()
        #expect(fixture.clipboard.entries.count == 1)
        try await Self.expectUsable(entry, file: file, in: fixture.clipboard, pasteboard: fixture.pasteboard)

        let relaunched = Self.relaunch(fixture)
        #expect(relaunched.adoptScreenshots() == 0, "listed already")
        try await Self.expectUsable(relaunched.entries.first, file: file, in: relaunched, pasteboard: fixture.pasteboard)
    }

    @Test("Two hotkey screenshots in the same second keep both, every display's, in the history and on the Desktop, under Finder's next name")
    func sameSecondKeepsBoth() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let desktop = Self.desktop(in: fixture.root)
        let second = Date(timeIntervalSince1970: 1_790_000_000)
        let capture = HotkeyCapture(fixture, copyingTo: desktop, now: { second })
        defer { capture.watcher.stop() }
        var first: [URL] = []
        var next: [URL] = []
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher) { first = $0 }
        capture.runner.finish?()
        capture.delivery.capture(.screens, with: capture.capturer, watcher: capture.watcher) { next = $0 }
        capture.runner.finish?()

        #expect(first.count == 3 && next.count == 3)
        let base = try #require(first.first).deletingPathExtension().lastPathComponent
        #expect(next.map(\.lastPathComponent) == ["\(base) 2.png", "\(base) 2 (2).png", "\(base) 2 (3).png"])
        let history = fixture.clipboard.screenshotsFolder
        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: history.path))
        #expect(kept == Set((first + next).map(\.lastPathComponent)), "six files, none written over")
        for file in first + next {
            #expect(try Data(contentsOf: file) == ScreenshotClipboardTests.png + Data(file.path.utf8), "each its own screenshot")
            let copy = desktop.appendingPathComponent(file.lastPathComponent)
            #expect(FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path), "and its own copy on the Desktop")
        }
        #expect(fixture.clipboard.entries.count == 6)
        capture.scan()
        #expect(fixture.clipboard.entries.count == 6, "the copies aren't added again")
    }

    @Test("A screenshot started while another is still being taken never takes its names")
    func overlappingCapturesTakeTheirOwnNames() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let runner = DeferredRunner()
        let history = fixture.clipboard.screenshotsFolder
        let second = Date(timeIntervalSince1970: 1_790_000_000)
        let capturer = ScreenshotCapturer(runner: runner, folder: { history }, now: { second }, displayCount: { 1 })
        var planned: [[URL]] = []
        capturer.capture(.area, willWrite: { planned.append($0) }) { _ in }
        capturer.capture(.area, willWrite: { planned.append($0) }) { _ in }
        #expect(planned.count == 2)
        #expect(Set(planned.joined()).count == 2, "the second waits for no file, and still takes a name of its own")
        runner.finishAll()
        // Once both are done, a third takes the next free name.
        capturer.capture(.area, willWrite: { planned.append($0) }) { _ in }
        #expect(planned.last?.first?.lastPathComponent.hasSuffix(" 3.png") == true)
        runner.finishAll()
    }

    @Test("An edited screenshot is saved into the history as a screenshot of its own, with its copy on the Desktop, added once")
    func editedScreenshotJoinsTheHistory() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let desktop = Self.desktop(in: fixture.root)
        let capture = HotkeyCapture(fixture, copyingTo: desktop)
        defer { capture.watcher.stop() }
        let history = fixture.clipboard.screenshotsFolder
        let original = history.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00.png")
        try Self.realPNG().write(to: original)
        let screenshot = try #require(fixture.clipboard.addScreenshot(at: original))
        let presenter = ScreenshotEditorPresenter(
            fallbackFolder: { desktop },
            screenshotsFolder: { history },
            keepsEditedScreenshot: { capture.delivery.addEdited($0, watcher: capture.watcher) },
            pasteboard: fixture.pasteboard,
            editingChanged: { _ in }
        )

        // Never presented, so no window appears.
        let editor = try #require(presenter.makeController(for: screenshot))
        editor.save()

        let edited = history.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00 (edited).png")
        #expect(FileManager.default.fileExists(atPath: edited.path), "in the history")
        let item = try #require(fixture.clipboard.entries.first)
        #expect(item.id != screenshot.id && item.isScreenshot, "a screenshot of its own, newest")
        #expect(item.sourceURL == edited && item.imageURL == edited)
        #expect(fixture.clipboard.entries.count == 2)
        let copy = desktop.appendingPathComponent(edited.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: edited.path, andPath: copy.path), "with its copy on the Desktop")
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path) == [edited.lastPathComponent])

        capture.scan()
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.count == 2, "neither its copy nor its pasteboard write is added again")
        #expect(fixture.clipboard.entries.first?.id == item.id)
        #expect(Self.tab(fixture.clipboard).count == 2, "listed in the ScreenGrabs tab")
    }

    @Test("The editor's Save on a screenshot works before ScreenGrabs' history exists: the folder is made, and the edited copy kept there (#611)")
    func editedScreenshotSavesWithoutTheHistoryFolder() throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        let desktop = fixture.desktop
        // A screenshot item from before #605 that the launch's move hasn't brought into the history.
        let source = desktop.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00.png")
        let media = fixture.media.appendingPathComponent("made-up.png")
        for file in [source, media] { try fixture.write(Self.realPNG(), to: file) }
        try fixture.save([Self.screenshot(media: media, source: source, at: 0)])
        let clipboard = fixture.clipboard()
        let screenshot = try #require(clipboard.entries.first)
        let screengrabs = fixture.paths.keybumpsFolder.appendingPathComponent("screengrabs", isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: screengrabs.path), "neither screengrabs/ nor screengrabs/screenshots/ exists")
        let delivery = ScreenshotClipboardDelivery(clipboard: clipboard, copiesToClipboard: { true }, copies: ScreengrabCopies(folder: { desktop }))
        let watcher = ScreenshotToolsService(
            resolver: ScreenshotLocationResolver(preferredLocation: { desktop.path }, homeDirectory: fixture.url, isDirectory: { _ in true }),
            reader: FakeScreenshotDirectoryReader(granted: true),
            ingest: { _ in false }
        )
        let presenter = ScreenshotEditorPresenter(
            fallbackFolder: { desktop },
            screenshotsFolder: { clipboard.screenshotsFolder },
            keepsEditedScreenshot: { delivery.addEdited($0, watcher: watcher) },
            pasteboard: fixture.pasteboard,
            editingChanged: { _ in }
        )

        // Never presented, so no window appears.
        let editor = try #require(presenter.makeController(for: screenshot))
        editor.save()

        let edited = fixture.history.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00 (edited).png")
        #expect(FileManager.default.fileExists(atPath: edited.path), "in the history, made for it")
        let item = try #require(clipboard.entries.first)
        #expect(item.id != screenshot.id && item.isScreenshot && item.imageURL == edited, "a screenshot of its own, newest")
        let copy = desktop.appendingPathComponent(edited.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: edited.path, andPath: copy.path), "with its copy on the Desktop")
    }

    @Test("Turning Clipboard History or ScreenGrabs on lists the screenshots taken into the history while either was off, kept out of the Clipboard tab")
    func turningOnListsScreenshotsTakenWhileOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreengrabsTurningOn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screenshotTools], missing: nil, root: root)
        harness.model.start()
        let clipboard = harness.model.clipboard
        func take(_ name: String) throws -> URL {
            let file = clipboard.screenshotsFolder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: clipboard.screenshotsFolder, withIntermediateDirectories: true)
            try (ScreenshotClipboardTests.png + Data(name.utf8)).write(to: file)
            return file
        }

        let whileClipboardOff = try take("Screenshot 2026-10-21 at 10.00.00.png")
        #expect(clipboard.entries.isEmpty)
        harness.model.setCapability(.clipboardHistory, enabled: true)
        #expect(clipboard.entries.map(\.imageURL) == [whileClipboardOff])

        harness.model.setCapability(.screenshotTools, enabled: false)
        let whileScreenGrabsOff = try take("Screenshot 2026-10-21 at 10.00.01.png")
        harness.model.setCapability(.screenshotTools, enabled: true)
        #expect(Set(clipboard.entries.compactMap(\.imageURL)) == [whileClipboardOff, whileScreenGrabsOff])
        #expect(clipboard.entries.filter(\.isScreenshot).count == 2)
        #expect(clipboard.clipboardTabEntries.isEmpty, "never copied, so not in the Clipboard tab")
    }

    @Test("A screenshot macOS saves on the Desktop is copied into the history, with no second copy; removing it from the Desktop keeps it listed and usable")
    func macOSScreenshotIsCopiedIn() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let desktop = Self.desktop(in: fixture.root)
        let capture = HotkeyCapture(fixture, copyingTo: desktop)
        defer { capture.watcher.stop() }

        let saved = desktop.appendingPathComponent("Screenshot 2026-10-21 at 10.00.00.png")
        try (ScreenshotClipboardTests.png + Data("made-up screenshot".utf8)).write(to: saved)
        ScreenshotClipboardTests.HeldRunner.mark(saved.path)
        capture.scan()

        let kept = fixture.clipboard.screenshotsFolder.appendingPathComponent(saved.lastPathComponent)
        let entry = try #require(fixture.clipboard.entries.first)
        #expect(fixture.clipboard.entries.count == 1)
        #expect(entry.sourceURL == kept && entry.imageURL == kept, "the item names the history's file")
        #expect(FileManager.default.contentsEqual(atPath: saved.path, andPath: kept.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path) == [saved.lastPathComponent], "no second copy on the Desktop")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.clipboard.mediaDirectoryURL.path).isEmpty, "and none in media/")

        try FileManager.default.removeItem(at: saved)
        capture.scan()
        #expect(fixture.clipboard.entries.count == 1)
        try await Self.expectUsable(entry, file: kept, in: fixture.clipboard, pasteboard: fixture.pasteboard)
        let relaunched = Self.relaunch(fixture)
        #expect(relaunched.adoptScreenshots() == 0, "listed already")
        try await Self.expectUsable(relaunched.entries.first, file: kept, in: relaunched, pasteboard: fixture.pasteboard)
    }

    @Test("A recording lands in the history and, once the window keeps it, as a copy on the Desktop; removing the copy keeps it listed and usable, also after a relaunch")
    func recordingKeepsItsHistory() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let desktop = Self.desktop(in: fixture.root.url)
        let library = Self.library(fixture, paths)
        library.load()
        await library.launchCheck?.value
        var services = fixture.reviewServices(recordings: library)
        services.copies = ScreengrabCopies(folder: { desktop })
        let flow = ScreencastReviewFlow(services: services, contextReader: .inert)

        // The recorder saves in the history (`ScreencastPreferences.capturesFolder`).
        let capture = try await fixture.recording(at: 100, in: paths.screengrabsRecordings)
        flow.captureStarting()
        flow.captureFinished(.video(capture))
        #expect(await Self.eventually { flow.panel?.model?.input.folder == capture.folder })
        await flow.panel?.model?.save()

        let copy = desktop.appendingPathComponent(capture.folder.lastPathComponent, isDirectory: true)
        #expect(await Self.eventually { FileManager.default.fileExists(atPath: copy.path) })
        #expect(FileManager.default.contentsEqual(atPath: capture.folder.path, andPath: copy.path), "its whole folder on the Desktop")
        #expect(library.recordings.map(\.folder) == [capture.folder], "the index names the history's")

        try FileManager.default.removeItem(at: copy)
        try Self.expectUsable(capture.folder, in: library)

        let relaunched = Self.library(fixture, paths)
        relaunched.load()
        await relaunched.launchCheck?.value
        #expect(relaunched.recordings.count == 1)
        try Self.expectUsable(capture.folder, in: relaunched)
    }

    @Test("A recording kept because ScreenGrabs turned off or the Mac locked mid-recording is listed and gets its copy on the Desktop")
    func keptRecordingGetsItsCopy() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let desktop = Self.desktop(in: fixture.root.url)
        let library = Self.library(fixture, paths)
        library.load()
        await library.launchCheck?.value
        var services = fixture.reviewServices(recordings: library)
        services.copies = ScreengrabCopies(folder: { desktop })
        let flow = ScreencastReviewFlow(services: services, contextReader: .inert)

        let capture = try await fixture.recording(at: 100, in: paths.screengrabsRecordings)
        let copy = try #require(flow.captureKept(.video(capture)))
        #expect(copy.path == desktop.appendingPathComponent(capture.folder.lastPathComponent).path)
        #expect(FileManager.default.contentsEqual(atPath: capture.folder.path, andPath: copy.path), "its whole folder on the Desktop")
        #expect(flow.panel == nil, "nothing opens")
        #expect(library.recordings.map(\.folder) == [capture.folder], "listed now, from the history")
    }

    @Test("The ScreenGrabs tab lists every screenshot, not only the newest 50, also after a relaunch, and after an older build dropped some")
    func listsMoreThanFifty() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        for index in 0..<55 { fixture.clipboard.ingestForTesting("copy \(index)") }
        for index in 0..<60 {
            #expect(fixture.clipboard.addScreenshot(at: try fixture.screenshot("Screenshot \(index).png")) != nil)
        }
        #expect(Self.tab(fixture.clipboard).count == 60)

        let relaunched = Self.relaunch(fixture)
        #expect(Self.tab(relaunched).count == 60)
        #expect(relaunched.entries.filter { !$0.isScreenshot }.count == ClipboardHistoryService.capacity, "copies keep their limit")

        // A build before #605 keeps only the newest 50 screenshots and drops the rest on its next
        // save, removing nothing outside `media/`. Their files stay in the history, and this build
        // lists them again.
        let newestShots = Set(relaunched.entries.filter(\.isScreenshot).prefix(50).map(\.id))
        let olderBuildKeeps = relaunched.entries.filter { !$0.isScreenshot || newestShots.contains($0.id) }
        try JSONEncoder().encode(olderBuildKeeps).write(to: fixture.clipboard.storageURL)
        let afterRollback = Self.relaunch(fixture)
        #expect(Self.tab(afterRollback).count == 50)
        let inClipboardTab = afterRollback.clipboardTabEntries.map(\.id)
        #expect(afterRollback.adoptScreenshots() == 10)
        #expect(Self.tab(afterRollback).count == 60)
        #expect(Self.tab(Self.relaunch(fixture)).count == 60, "and that's saved")
        #expect(afterRollback.clipboardTabEntries.map(\.id) == inClipboardTab, "the ones listed again stay out of the Clipboard tab")
    }

    // MARK: Screenshots from before

    @Test("Screenshots from before #605 still appear after it: each is copied into the history from its copy in media/, else its own file, keeping its name, and the item names it; the person's files stay; a second launch changes nothing")
    func screenshotsFromBefore() async throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        // A hotkey screenshot since #605, already in the history under a name a screenshot from
        // before also has.
        let hotkeyFile = try fixture.png("hotkey", at: fixture.history.appendingPathComponent("Screenshot A.png"))
        let hotkey = Self.screenshot(media: hotkeyFile, source: hotkeyFile, at: 6)
        // Its copy in media/ and its own file on the Desktop.
        let bothCopy = try fixture.png("A", at: fixture.media.appendingPathComponent("a.png"))
        let bothOwn = try fixture.png("A", at: fixture.desktop.appendingPathComponent("Screenshot A.png"))
        let both = Self.screenshot(media: bothCopy, source: bothOwn, at: 5)
        // Its copy only, and a copy in the history from a launch cut short before the item named it.
        let copyOnly = Self.screenshot(media: try fixture.png("B", at: fixture.media.appendingPathComponent("b.png")), source: fixture.desktop.appendingPathComponent("Screenshot B.png"), at: 4)
        _ = try fixture.png("B", at: fixture.history.appendingPathComponent("Screenshot B.png"))
        // Its own file only.
        let ownOnly = Self.screenshot(media: fixture.media.appendingPathComponent("c.png"), source: try fixture.png("C", at: fixture.desktop.appendingPathComponent("Screenshot C.png")), at: 3)
        // Neither: moved or deleted before #605.
        let neither = Self.screenshot(media: fixture.media.appendingPathComponent("d.png"), source: fixture.desktop.appendingPathComponent("Screenshot D.png"), at: 2)
        let text = ClipboardEntry(id: UUID(), text: "made-up copied text", capturedAt: Date(timeIntervalSince1970: 1_790_000_001), fingerprint: "text:made-up")
        try fixture.save([hotkey, both, copyOnly, ownOnly, neither, text])

        let report = fixture.move().run()
        #expect(report == ScreengrabsHistoryMove.Report(screenshots: 3))

        let clipboard = fixture.clipboard()
        let entries = Dictionary(uniqueKeysWithValues: clipboard.entries.map { ($0.id, $0) })
        let kept = [
            both.id: fixture.history.appendingPathComponent("Screenshot A 2.png"),
            copyOnly.id: fixture.history.appendingPathComponent("Screenshot B.png"),
            ownOnly.id: fixture.history.appendingPathComponent("Screenshot C.png"),
        ]
        for (id, file) in kept {
            #expect(entries[id]?.imageURL == file && entries[id]?.sourceURL == file, "the item names its file in the history")
        }
        #expect(try Data(contentsOf: try #require(kept[both.id])) == Data(contentsOf: bothOwn))
        #expect(entries[hotkey.id] == hotkey && entries[neither.id] == neither && entries[text.id] == text, "the rest unchanged")
        #expect(clipboard.entries.map(\.id) == [hotkey.id, both.id, copyOnly.id, ownOnly.id, neither.id, text.id], "in their order")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.history.path)) == ["Screenshot A.png", "Screenshot A 2.png", "Screenshot B.png", "Screenshot C.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.media.path).isEmpty, "their copies in media/ are gone")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.desktop.path)) == ["Screenshot A.png", "Screenshot C.png"], "the person's files stay")

        // Each still appears in the ScreenGrabs tab, and opens its file.
        let listed = Self.tab(clipboard)
        #expect(listed.count == 5)
        for (id, file) in kept {
            let item = try #require(listed.first { $0.screenshotID == id })
            #expect(item.finderFiles == [file] && item.previewFiles == [file])
            #expect(await ScreengrabFileFacts.read(item).savedFileExists == true)
        }
        #expect(clipboard.adoptScreenshots() == 0, "every file in the history is listed")

        // The next launch changes nothing.
        let saved = try Data(contentsOf: fixture.paths.inUse(.clipboardHistory))
        #expect(fixture.move().run() == ScreengrabsHistoryMove.Report())
        #expect(try Data(contentsOf: fixture.paths.inUse(.clipboardHistory)) == saved)
    }

    @Test("Where a clone can't be made, a screenshot from before is copied, checked, and put in place, leaving no partial copy")
    func checkedCopyFallback() throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        let original = try fixture.png("E", at: fixture.media.appendingPathComponent("e.png"))
        let item = Self.screenshot(media: original, source: fixture.desktop.appendingPathComponent("Screenshot E.png"), at: 1)
        let contents = try Data(contentsOf: original)
        try fixture.save([item])
        var move = fixture.move()
        move.clone = { _, _ in ENOTSUP }

        #expect(move.run() == ScreengrabsHistoryMove.Report(screenshots: 1))
        let kept = fixture.history.appendingPathComponent("Screenshot E.png")
        #expect(try Data(contentsOf: kept) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.history.path) == ["Screenshot E.png"], "no hidden partial copy")
        #expect(fixture.clipboard().entries.first?.imageURL == kept)
    }

    @Test("A screenshot from before that can't be copied stays as it was, named where it was, and is tried again at the next launch")
    func failureLeavesItAsItWas() throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        let original = try fixture.png("F", at: fixture.media.appendingPathComponent("f.png"))
        let item = Self.screenshot(media: original, source: fixture.desktop.appendingPathComponent("Screenshot F.png"), at: 1)
        try fixture.save([item])
        let saved = try Data(contentsOf: fixture.paths.inUse(.clipboardHistory))
        // A file where the history's folder goes.
        try FileManager.default.createDirectory(at: fixture.paths.screengrabs, withIntermediateDirectories: true)
        try Data("made-up blocker".utf8).write(to: fixture.history)

        #expect(fixture.move().run() == ScreengrabsHistoryMove.Report(failures: 1))
        #expect(try Data(contentsOf: fixture.paths.inUse(.clipboardHistory)) == saved, "the item is unchanged")
        #expect(FileManager.default.fileExists(atPath: original.path), "and keeps its copy")
        #expect(fixture.clipboard().entries == [item])

        try FileManager.default.removeItem(at: fixture.history)
        #expect(fixture.move().run() == ScreengrabsHistoryMove.Report(screenshots: 1))
        #expect(fixture.clipboard().entries.first?.imageURL == fixture.history.appendingPathComponent("Screenshot F.png"))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("A screenshot in the history that no item names is listed, unless it's the copy a screenshot from before is waiting for; partial copies and other files are left alone")
    func adoptLeavesWaitingCopiesToTheMove() async throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        // The fingerprint Clipboard History gives these bytes.
        let bytes = ScreenshotClipboardTests.png + Data("W".utf8)
        let probe = try fixture.png("W", at: fixture.url.appendingPathComponent("probe/Probe.png"))
        let probeFixture = HistoryFixture(at: fixture.url.appendingPathComponent("probe-history", isDirectory: true))
        defer { probeFixture.tearDown() }
        let fingerprint = try #require(probeFixture.clipboard().addScreenshot(at: probe)?.fingerprint)
        // A screenshot from before, and the copy a launch cut short made of it before the item named it.
        let waitingCopy = fixture.media.appendingPathComponent("w.png")
        try fixture.write(bytes, to: waitingCopy)
        let waiting = ClipboardEntry(
            id: UUID(), text: "", capturedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: .image,
            mediaPath: waitingCopy.path, mediaPasteboardType: "public.png", fingerprint: fingerprint,
            sourcePath: fixture.desktop.appendingPathComponent("Screenshot W.png").path, isScreenCapture: true
        )
        try fixture.save([waiting])
        try fixture.write(bytes, to: fixture.history.appendingPathComponent("Screenshot W.png"))
        // A partial copy, a file that isn't an image, and one taken while Clipboard History was off.
        try fixture.write(bytes + Data("partial".utf8), to: KeybumpsFolderMove.partialCopy(of: fixture.history.appendingPathComponent("Screenshot P.png")))
        try fixture.write(Data("made-up".utf8), to: fixture.history.appendingPathComponent("notes.txt"))
        let taken = try fixture.png("N", at: fixture.history.appendingPathComponent("Screenshot N.png"))

        let clipboard = fixture.clipboard()
        #expect(clipboard.adoptScreenshots() == 1)
        let adopted = try #require(clipboard.entries.first { $0.id != waiting.id })
        #expect(adopted.imageURL == taken && adopted.sourceURL == taken && adopted.isScreenshot)
        #expect(clipboard.clipboardTabEntries.map(\.id) == [waiting.id], "never copied, so not in the Clipboard tab")

        // The move then gives the waiting item that copy, and removes Keybumps' partial copy.
        #expect(fixture.move().run() == ScreengrabsHistoryMove.Report(screenshots: 1, partials: 1))
        let relaunched = fixture.clipboard()
        #expect(relaunched.adoptScreenshots() == 0)
        #expect(relaunched.entries.first { $0.id == waiting.id }?.imageURL == fixture.history.appendingPathComponent("Screenshot W.png"))
        #expect(Self.tab(relaunched).count == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.history.path)) == [
            "Screenshot W.png", "Screenshot N.png", "notes.txt",
        ], "one file for the waiting screenshot")
    }

    // MARK: Recordings from before

    @Test("A recording from before #605 that the index lists on the Desktop is copied into the history, and the index names the copy; the Desktop folder stays, and removing it keeps the recording usable")
    func indexedRecordingFromBefore() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let desktop = Self.desktop(in: fixture.root.url)
        let old = try await fixture.recording(at: 100, review: true, in: desktop)
        // Indexed where a build from #504 until #605 saved it.
        let before = Self.library(fixture, paths)
        before.load()
        await before.launchCheck?.value
        before.add(old)
        #expect(before.recordings.map(\.folder) == [old.folder])

        let move = ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults)
        #expect(move.run() == ScreengrabsHistoryMove.Report(recordings: 1))
        let kept = paths.screengrabsRecordings.appendingPathComponent(old.folder.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.contentsEqual(atPath: old.folder.path, andPath: kept.path), "its whole folder, review and all")
        #expect(FileManager.default.fileExists(atPath: old.folder.path), "the Desktop folder stays, as the person's copy")

        let after = Self.library(fixture, paths)
        after.load()
        await after.launchCheck?.value
        #expect(after.recordings.map { ProductPaths.canonicalPath($0.folder) } == [ProductPaths.canonicalPath(kept)], "listed once, from the history")
        try FileManager.default.removeItem(at: old.folder)
        try Self.expectUsable(kept, in: after)

        #expect(move.run() == ScreengrabsHistoryMove.Report(), "the next launch changes nothing")
    }

    @Test("Where a clone can't be made, a recording from before is copied, checked, and put in place")
    func recordingCheckedCopyFallback() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let old = try await fixture.recording(at: 100, displays: 2, in: Self.desktop(in: fixture.root.url))
        let before = Self.library(fixture, paths)
        before.load()
        await before.launchCheck?.value
        before.add(old)
        var move = ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults)
        move.clone = { _, _ in ENOTSUP }

        #expect(move.run() == ScreengrabsHistoryMove.Report(recordings: 1))
        let kept = paths.screengrabsRecordings.appendingPathComponent(old.folder.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.contentsEqual(atPath: old.folder.path, andPath: kept.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.screengrabsRecordings.path) == [old.folder.lastPathComponent], "no hidden partial copy")
    }

    @Test("An index entry for a recording's Desktop folder whose copy the index also lists in the history, as after a launch cut short, is dropped")
    func duplicateEntryDropped() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let old = try await fixture.recording(at: 100, in: Self.desktop(in: fixture.root.url))
        let kept = paths.screengrabsRecordings.appendingPathComponent(old.folder.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: paths.screengrabsRecordings, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old.folder, to: kept)
        let before = Self.library(fixture, paths)
        before.load()
        await before.launchCheck?.value
        before.add(old)
        #expect(before.recordings.count == 2)

        #expect(ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults).run() == ScreengrabsHistoryMove.Report(duplicates: 1))
        let after = Self.library(fixture, paths)
        after.load()
        await after.launchCheck?.value
        #expect(after.recordings.map(\.folder.path) == [kept.path])
        #expect(FileManager.default.fileExists(atPath: old.folder.path))
    }

    @Test("A recording from before #605 that the index lacks, in a folder ScreenGrabs recorded into, is copied into the history once; one the history has, and the person's own folders, are left alone")
    func unindexedRecordingFromBefore() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = Self.paths(in: fixture.root.url)
        let desktop = Self.desktop(in: fixture.root.url)
        fixture.defaults.set([desktop.path], forKey: RecordingFolderMemory.key)
        // Kept while Keybumps locked, so never indexed.
        let lost = try await fixture.recording(at: 300, in: desktop)
        // In the history already, under its name.
        try await fixture.recording(at: 400, in: desktop)
        let inHistory = try await fixture.recording(at: 400, review: true, in: paths.screengrabsRecordings)
        let reviewed = try Data(contentsOf: inHistory.metadataURL)
        // The person's own.
        let own = desktop.appendingPathComponent("Holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)

        let move = ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults)
        #expect(move.run() == ScreengrabsHistoryMove.Report(recordings: 1))
        let kept = paths.screengrabsRecordings.appendingPathComponent(lost.folder.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.contentsEqual(atPath: lost.folder.path, andPath: kept.path))
        #expect(try Data(contentsOf: inHistory.metadataURL) == reviewed, "the history's own is unchanged")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: paths.screengrabsRecordings.path)) == [lost.folder.lastPathComponent, inHistory.folder.lastPathComponent])
        #expect(fixture.defaults.object(forKey: ScreengrabsHistoryMove.doneKey) != nil)

        // Once: a recording an older build saves there later isn't copied.
        let later = try await fixture.recording(at: 500, in: desktop)
        #expect(move.run() == ScreengrabsHistoryMove.Report())
        #expect(!FileManager.default.fileExists(atPath: paths.screengrabsRecordings.appendingPathComponent(later.folder.lastPathComponent).path))

        let library = Self.library(fixture, paths)
        library.load()
        await library.launchCheck?.value
        #expect(Set(library.recordings.map(\.folder.lastPathComponent)) == [lost.folder.lastPathComponent, inHistory.folder.lastPathComponent])
        try Self.expectUsable(kept, in: library)
    }

    @Test("While the Keybumps folder move left the recordings in their old place, recordings wait for the launch that finds them in the Keybumps folder")
    func recordingsWaitForTheFolderMove() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        var paths = Self.paths(in: fixture.root.url)
        paths.leftInOldPlace = [.recordings]
        let desktop = Self.desktop(in: fixture.root.url)
        fixture.defaults.set([desktop.path], forKey: RecordingFolderMemory.key)
        try await fixture.recording(at: 300, in: desktop)

        #expect(ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults).run() == ScreengrabsHistoryMove.Report())
        #expect(!FileManager.default.fileExists(atPath: paths.screengrabsRecordings.path))
        #expect(fixture.defaults.object(forKey: ScreengrabsHistoryMove.doneKey) == nil)

        paths.leftInOldPlace = []
        #expect(ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults).run() == ScreengrabsHistoryMove.Report(recordings: 1))
    }

    @Test("Recordings held in a folder chosen before #605 don't wait: indexed ones are copied into the history, the folder stays as it is, and new recordings go to the history")
    func chosenFolderRecordingsAreCopiedIn() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        var paths = Self.paths(in: fixture.root.url)
        let chosen = paths.oldPlace(of: .recordings)
        fixture.defaults.set(chosen.standardizedFileURL.path, forKey: "screengrabs.recordingsFolder")
        paths.leftInOldPlace = [.recordings]
        let old = try await fixture.recording(at: 100, in: chosen)
        let before = Self.library(fixture, paths)
        before.load()
        await before.launchCheck?.value
        before.add(old)

        #expect(ScreengrabsHistoryMove(paths: paths, defaults: fixture.defaults).run() == ScreengrabsHistoryMove.Report(recordings: 1))
        let kept = paths.screengrabsRecordings.appendingPathComponent(old.folder.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.contentsEqual(atPath: old.folder.path, andPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: old.folder.path), "the chosen folder's copy stays")
        #expect(AppPreferences(defaults: fixture.defaults).screencast.capturesFolder == ProductPaths.keybumps().screengrabsRecordings, "new recordings go to the history")
    }

    @Test("A copy that's an APFS clone isn't read back to check it; a plain copy is")
    func onlyPlainCopiesAreChecked() throws {
        let root = TemporaryCapturesFolder()
        defer { root.remove() }
        let source = root.url.appendingPathComponent("Screenshot.png")
        try Data("made-up".utf8).write(to: source)
        let fileManager = ComparingFileManager()

        let cloned = ScreengrabFiles.copy(source, to: root.url.appendingPathComponent("Cloned.png"), fileManager: fileManager) { from, to in
            (try? FileManager.default.copyItem(at: from, to: to)) == nil ? EIO : 0
        }
        #expect(cloned == .copied(root.url.appendingPathComponent("Cloned.png")))
        #expect(fileManager.comparisons == 0)

        let copied = ScreengrabFiles.copy(source, to: root.url.appendingPathComponent("Copied.png"), fileManager: fileManager) { _, _ in ENOTSUP }
        #expect(copied == .copied(root.url.appendingPathComponent("Copied.png")))
        #expect(fileManager.comparisons == 1)
    }

    @Test("At launch, partial copies Keybumps left in the history are removed, and nothing else")
    func partialCopiesAreRemoved() throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        let recordings = fixture.paths.screengrabsRecordings
        let partials = [
            KeybumpsFolderMove.partialCopy(of: fixture.history.appendingPathComponent("Screenshot A.png")),
            KeybumpsFolderMove.partialCopy(of: recordings.appendingPathComponent("1790000000", isDirectory: true)).appendingPathComponent("video-1.mov"),
        ]
        for partial in partials { try fixture.write(Data("partial".utf8), to: partial) }
        let others = [
            fixture.history.appendingPathComponent("Screenshot C.png"),
            fixture.history.appendingPathComponent(".keybumps-moving"),
            fixture.history.appendingPathComponent("Screenshot D.png.keybumps-moving"),
            recordings.appendingPathComponent("1790000100/video-1.mov"),
        ]
        for other in others { try fixture.write(Data("the person's".utf8), to: other) }

        let report = fixture.move().run()
        #expect(report.partials == 2 && report.failures == 0)
        #expect(!FileManager.default.fileExists(atPath: partials[0].path))
        #expect(!FileManager.default.fileExists(atPath: partials[1].deletingLastPathComponent().path), "a partial folder, with what's in it")
        for other in others { #expect(FileManager.default.fileExists(atPath: other.path), "\(other.lastPathComponent) stays") }
    }

    @Test("With ScreenGrabs off, launch never lists where copies go, or asks where that is, and a partial copy there stays (#611)")
    func launchLeavesWhereCopiesGoAlone() throws {
        let fixture = HistoryFixture()
        defer { fixture.tearDown() }
        let desktop = fixture.desktop
        let partial = KeybumpsFolderMove.partialCopy(of: desktop.appendingPathComponent("Screenshot A.png"))
        try fixture.write(Data("partial".utf8), to: partial)

        // The history move, which runs at every launch, ScreenGrabs on or off, lists only the history.
        let fileManager = ListingFileManager()
        let report = ScreengrabsHistoryMove(paths: fixture.paths, fileManager: fileManager, defaults: fixture.defaults).run()
        #expect(report == ScreengrabsHistoryMove.Report())
        #expect(Set(fileManager.listed) == [fixture.history.path, fixture.paths.screengrabsRecordings.path])

        // The app starting with Clipboard History on and ScreenGrabs off neither asks where copies go
        // nor lists where macOS saves screenshots.
        var asked = 0
        let reader = ListingScreenshotReader()
        let harness = WiringHarness(
            enabled: [.clipboardHistory], missing: nil, root: fixture.url, screenshotReader: reader,
            screengrabCopies: ScreengrabCopies(folder: { asked += 1; return desktop })
        )
        harness.model.start()
        #expect(asked == 0)
        #expect(reader.listed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: partial.path), "left for the next copy, which only ScreenGrabs makes")
    }

    @Test("With ScreenGrabs on, a partial copy Keybumps left where copies go is removed just before the next copy there, and nothing else (#611)")
    func partialCopyGoesBeforeTheNextCopy() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let desktop = Self.desktop(in: fixture.root)
        let partials = [
            KeybumpsFolderMove.partialCopy(of: desktop.appendingPathComponent("Screenshot A.png")),
            KeybumpsFolderMove.partialCopy(of: desktop.appendingPathComponent("1790000000", isDirectory: true)).appendingPathComponent("video-1.mov"),
        ]
        let others = [
            desktop.appendingPathComponent("Notes.txt"),
            desktop.appendingPathComponent(".keybumps-moving"),
            desktop.appendingPathComponent("Screenshot D.png.keybumps-moving"),
            desktop.appendingPathComponent(".Screenshot E.png"),
            desktop.appendingPathComponent(".Screenshot F.png.keybumps-moving.txt"),
            desktop.appendingPathComponent("Folder/.Screenshot G.png.keybumps-moving"),
        ]
        for (file, contents) in partials.map({ ($0, "partial") }) + others.map({ ($0, "the person's") }) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let capture = HotkeyCapture(fixture, copyingTo: desktop)
        defer { capture.watcher.stop() }
        #expect(partials.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "watching the folder leaves them")

        var written: [URL] = []
        capture.delivery.capture(.area, with: capture.capturer, watcher: capture.watcher) { written = $0 }
        capture.runner.finish?()

        let file = try #require(written.first)
        let copy = desktop.appendingPathComponent(file.lastPathComponent)
        #expect(FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path), "the copy is made")
        #expect(!FileManager.default.fileExists(atPath: partials[0].path))
        #expect(!FileManager.default.fileExists(atPath: partials[1].deletingLastPathComponent().path), "a partial folder, with what's in it")
        for other in others { #expect(FileManager.default.fileExists(atPath: other.path), "\(other.lastPathComponent) stays") }
    }

    // MARK: Helpers

    /// A stand-in for the Desktop, where macOS saves screenshots, in `root`.
    static func desktop(in root: URL) -> URL {
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        return desktop
    }

    /// The Keybumps folder and the rest of Keybumps's places, in `root`.
    static func paths(in root: URL) -> ProductPaths {
        ProductPaths(
            keybumpsFolder: root.appendingPathComponent("Application Support/Keybumps", isDirectory: true),
            oldDocumentsFolder: root.appendingPathComponent("Documents/Keybumps", isDirectory: true),
            translatedSpeechTemporary: root.appendingPathComponent("tmp", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    /// The fixture's Clipboard History as the next launch loads it.
    static func relaunch(_ fixture: Fixture) -> ClipboardHistoryService {
        ClipboardHistoryService(
            storageURL: fixture.clipboard.storageURL,
            pasteboard: fixture.pasteboard,
            mediaDirectoryURL: fixture.clipboard.mediaDirectoryURL,
            sourceApps: .inert
        )
    }

    /// The recordings index in `paths`, as the app makes it.
    static func library(_ fixture: RecordingLibraryFixture, _ paths: ProductPaths) -> RecordingLibrary {
        RecordingLibrary(
            storageURL: paths.inUse(.recordingsIndex),
            capturesFolder: paths.screengrabsRecordings,
            posterFrames: RecordingPosterFrames(folder: fixture.posters),
            importMemory: fixture.importMemory,
            screenshots: fixture.clipboard,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    /// What the ScreenGrabs tab lists.
    static func tab(_ clipboard: ClipboardHistoryService, recordings: [IndexedRecording] = []) -> [Screengrab] {
        ScreengrabsTabContent.resolve(
            screenshots: clipboard.entries, recordings: recordings, query: "", filter: nil, isEnabled: true,
            listsScreenshots: true, listsRecordings: true
        ).items
    }

    /// A screenshot item as a build before #605 saved it: a copy in `media/` and its own file.
    static func screenshot(media: URL, source: URL, at seconds: TimeInterval) -> ClipboardEntry {
        ClipboardEntry(
            id: UUID(), text: "", capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), kind: .image,
            mediaPath: media.path, mediaPasteboardType: "public.png", fingerprint: "image:made-up \(seconds)",
            sourcePath: source.path, isScreenCapture: true
        )
    }

    /// The screenshot is listed in the ScreenGrabs tab, never "Moved or deleted", and Show in
    /// Finder, Quick Look, and Copy each use its file in the history.
    static func expectUsable(
        _ entry: ClipboardEntry?, file: URL, in clipboard: ClipboardHistoryService, pasteboard: NSPasteboard,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let entry = try #require(entry, sourceLocation: sourceLocation)
        let item = try #require(tab(clipboard).first { $0.screenshotID == entry.id }, "listed in the ScreenGrabs tab", sourceLocation: sourceLocation)
        #expect(!item.isMissing, sourceLocation: sourceLocation)
        #expect(await ScreengrabFileFacts.read(item).savedFileExists == true, "not Moved or deleted", sourceLocation: sourceLocation)
        #expect(item.finderFiles == [file], "Show in Finder", sourceLocation: sourceLocation)
        #expect(item.previewFiles == [file], "Quick Look", sourceLocation: sourceLocation)
        #expect(clipboard.restore(entry), "Copy", sourceLocation: sourceLocation)
        #expect(pasteboard.data(forType: .png) == (try Data(contentsOf: file)), sourceLocation: sourceLocation)
    }

    /// The recording in `folder` is listed in the ScreenGrabs tab, not "Moved or deleted", opens in
    /// the recording window again, and Show in Finder and Copy use its videos in that folder.
    static func expectUsable(_ folder: URL, in library: RecordingLibrary, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let listed = ScreengrabsTabContent.resolve(
            screenshots: [], recordings: library.recordingsNewestFirst(), query: "", filter: nil, isEnabled: true,
            listsScreenshots: true, listsRecordings: true
        ).items
        let path = ProductPaths.canonicalPath(folder)
        let item = try #require(listed.first { $0.recording.map { ProductPaths.canonicalPath($0.folder) == path } ?? false }, "listed in the ScreenGrabs tab", sourceLocation: sourceLocation)
        let recording = try #require(item.recording, sourceLocation: sourceLocation)
        #expect(!item.isMissing, "not Moved or deleted", sourceLocation: sourceLocation)
        #expect(recording.savedCapture() != nil, "opens in the recording window", sourceLocation: sourceLocation)
        #expect(!item.finderFiles.isEmpty, sourceLocation: sourceLocation)
        #expect(item.finderFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) && ScreengrabFiles.isDirectly($0, in: folder) }, "Show in Finder and Copy", sourceLocation: sourceLocation)
    }

    /// An 8×8 PNG the Screenshot Editor can open.
    static func realPNG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// Lets the main actor run until `condition` holds, for three seconds at most.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// The Keybumps folder's ScreenGrabs and Clipboard History in a temporary folder, with a stand-in
/// for the Desktop, a named pasteboard, and `InMemoryDefaults`.
@MainActor
private final class HistoryFixture {
    let root: TemporaryCapturesFolder?
    let url: URL
    let defaults = InMemoryDefaults()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreengrabsHistory-\(UUID().uuidString)"))

    init() {
        let root = TemporaryCapturesFolder()
        self.root = root
        url = root.url
    }

    /// One inside another fixture's folder, removed with it.
    init(at url: URL) {
        root = nil
        self.url = url
    }

    var paths: ProductPaths { ScreengrabsHistoryTests.paths(in: url) }
    var desktop: URL { ScreengrabsHistoryTests.desktop(in: url) }
    var history: URL { paths.screengrabsScreenshots }
    var media: URL { paths.inUse(.clipboardMedia) }

    /// Clipboard History as the app makes it, reading what's saved now.
    func clipboard() -> ClipboardHistoryService {
        ClipboardHistoryService(
            storageURL: paths.inUse(.clipboardHistory),
            pasteboard: pasteboard,
            mediaDirectoryURL: media,
            screenshotsFolder: history,
            sourceApps: .inert
        )
    }

    func move() -> ScreengrabsHistoryMove {
        ScreengrabsHistoryMove(paths: paths, defaults: defaults)
    }

    /// Saves Clipboard History's items as it saves them.
    func save(_ entries: [ClipboardEntry]) throws {
        try write(JSONEncoder().encode(entries), to: paths.inUse(.clipboardHistory))
    }

    /// A PNG with pixels of its own (`seed`) at `url`.
    @discardableResult
    func png(_ seed: String, at url: URL) throws -> URL {
        try write(ScreenshotClipboardTests.png + Data(seed.utf8), to: url)
        return url
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        root?.remove()
    }
}

extension Screengrab {
    /// The screenshot's item ID, or nil for a recording.
    var screenshotID: UUID? {
        guard case .screenshot(let entry) = self else { return nil }
        return entry.id
    }
}

/// Holds each capture's `screencapture` until `finishAll()`, writing nothing before then, as a
/// slow area selection does.
private final class DeferredRunner: ScreenshotCaptureRunning {
    private var pending: [(files: [String], finish: @MainActor () -> Void)] = []

    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        pending.append((arguments.filter { $0.hasSuffix(".png") }, completion))
    }

    @MainActor
    func finishAll() {
        let held = pending
        pending = []
        for (files, finish) in held {
            for file in files { FileManager.default.createFile(atPath: file, contents: ScreenshotClipboardTests.png + Data(file.utf8)) }
            finish()
        }
    }
}

/// Counts the reads that check a copy against its original.
private final class ComparingFileManager: FileManager, @unchecked Sendable {
    private(set) var comparisons = 0

    override func contentsEqual(atPath path1: String, andPath path2: String) -> Bool {
        comparisons += 1
        return super.contentsEqual(atPath: path1, andPath: path2)
    }
}

/// Records each folder it's asked to list.
private final class ListingFileManager: FileManager {
    private(set) var listed: [String] = []

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        listed.append(path)
        return try super.contentsOfDirectory(atPath: path)
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        listed.append(url.path)
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

/// Where macOS saves screenshots, as the watcher lists it, recording each folder it's asked for.
private final class ListingScreenshotReader: ScreenshotDirectoryReading {
    private(set) var listed: [URL] = []

    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
        listed.append(folder)
        return []
    }
}
