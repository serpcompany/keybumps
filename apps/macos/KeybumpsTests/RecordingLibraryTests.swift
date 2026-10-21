import AppKit
import Foundation
import Testing
@testable import Keybumps

/// ScreenGrabs' recordings index (#492): what adds, reads again, marks missing, and removes an
/// entry; the one-time import and what it leaves alone; each launch's check of the recordings
/// folder and poster frames; file names that leave their folder; and an index that's missing,
/// corrupt, partly readable, unreadable, or a later build's. Everything is in a temporary folder,
/// with generated videos, made-up PNGs, a named pasteboard, and `InMemoryDefaults`.
@MainActor
@Suite("ScreenGrabs: the recordings index")
struct RecordingLibraryTests {
    let fixture = RecordingLibraryFixture()

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("The recorder's recordings are indexed newest first, and a save reads one again")
    func addAndSave() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let older = try await fixture.recording(at: 100)
        let newer = try await fixture.recording(at: 200, displays: 2)
        library.add(older)
        library.add(newer)

        let entry = try #require(library.recordings.first)
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)])
        #expect(entry.displayCount == 2)
        #expect(entry.videos.map(\.file) == ["video-1.mov", "video-2.mov"])
        #expect(fixture.savedRecordings() == library.recordings)

        // Save writes a trim's new duration into meta.json.
        try fixture.setDuration(3, of: newer)
        library.reviewEnded(.saved(.video(newer)))
        #expect(library.recordings.first?.duration == 3)
        #expect(library.recordings.first?.id == entry.id)
        #expect(fixture.savedRecordings()?.first?.duration == 3)
    }

    @Test("The recording window's Save keeps a recording listed, and Discard removes it")
    func reviewWindow() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let flow = fixture.reviewFlow(recordings: library)

        let saved = try await fixture.recording(at: 100)
        flow.captureStarting()
        flow.captureFinished(.video(saved))
        #expect(library.recordings.count == 1, "listed before Save")
        #expect(await eventually { flow.panel?.model != nil })
        await flow.panel?.model?.save()
        #expect(fixture.savedRecordings()?.map(\.folder.path) == [saved.folder.path])

        let discarded = try await fixture.recording(at: 200)
        flow.captureStarting()
        flow.captureFinished(.video(discarded))
        #expect(library.recordings.count == 2)
        #expect(await eventually { flow.panel?.model?.input.folder == discarded.folder })
        flow.panel?.model?.askToDiscard()
        flow.panel?.model?.confirmDiscard()
        #expect(library.recordings.map(\.folder.path) == [saved.folder.path])
        #expect(fixture.savedRecordings()?.count == 1)
    }

    @Test("ScreenGrabs loads the index, and runs the import, once it's on")
    func loadsWhenScreenGrabsIsOn() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        let library = fixture.library()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            review: fixture.reviewServices(recordings: library)
        )
        #expect(module.recordings === library)

        module.apply(fixture.context([], preferences: preferences))
        #expect(library.state == .notLoaded)
        module.apply(fixture.context([.screenshotTools], preferences: preferences))
        #expect(library.recordings.count == 1)
        #expect(fixture.importMemory.isDone)
    }

    @Test("A recording moved or deleted outside Keybumps is marked missing, and unmarked when it's back")
    func missingFolder() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let capture = try await fixture.recording(at: 100)
        library.add(capture)
        let elsewhere = fixture.root.url.appendingPathComponent("moved", isDirectory: true)

        try FileManager.default.moveItem(at: capture.folder, to: elsewhere)
        #expect(library.recordingsNewestFirst().map(\.isMissing) == [true])
        try FileManager.default.moveItem(at: elsewhere, to: capture.folder)
        #expect(library.recordingsNewestFirst().map(\.isMissing) == [false])

        try FileManager.default.removeItem(at: capture.folder)
        let reloaded = fixture.library()
        reloaded.load()
        #expect(reloaded.recordings.map(\.isMissing) == [true], "still listed, marked on load")
        #expect(try !fixture.indexText().contains("isMissing"), "worked out, never stored")
    }

    @Test("The import runs once, indexes recordings where they are, and moves or changes no file")
    func importRunsOnce() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        try await fixture.recording(at: 300, displays: 2)
        try await fixture.recording(at: 200, review: true)
        try fixture.legacyScreenshot(at: 150, edited: false)
        try fixture.legacyScreenshot(at: 250, edited: true)
        try fixture.junk()
        let before = fixture.snapshot()

        let library = fixture.library()
        library.load()
        #expect(library.recordings.map(\.startedAt) == [Self.date(300), Self.date(200), Self.date(100)])
        #expect(library.recordings.map(\.displayCount) == [2, 1, 1])
        #expect(fixture.clipboard.entries.count == 3, "two screenshots and one edited copy")
        #expect(fixture.importMemory.isDone)
        #expect(fixture.snapshot() == before)

        let index = try fixture.indexText()
        fixture.clipboard.clearScreenshots()
        let again = fixture.library()
        again.load()
        #expect(again.recordings == library.recordings)
        #expect(fixture.clipboard.entries.isEmpty, "cleared screenshots stay cleared")
        #expect(try fixture.indexText() == index)
        #expect(fixture.snapshot() == before)
    }

    @Test("With 50 clipboard items kept, imported screenshots keep all 50 and their own dates, out of the Clipboard tab")
    func importKeepsClipboardItems() throws {
        defer { fixture.tearDown() }
        for item in 0..<50 { fixture.clipboard.ingestForTesting("item \(item)") }
        try fixture.legacyScreenshot(at: 150, edited: true)

        fixture.library().load()
        let screenshots = fixture.clipboard.entries.filter(\.isScreenshot)
        #expect(fixture.clipboard.clipboardTabEntries.count == 50)
        #expect(screenshots.count == 2)
        #expect(screenshots.allSatisfy { $0.capturedAt == Self.date(150) })
        #expect(screenshots.allSatisfy { $0.isHiddenFromClipboardTab && $0.sourceApp == nil })
        #expect(fixture.clipboard.entries.last?.isScreenshot == true, "placed by date, after newer items")
    }

    @Test("Importing a screenshot skips content already kept and places the rest by date")
    func importScreenshotPlacement() throws {
        defer { fixture.tearDown() }
        let clipboard = fixture.clipboard
        let first = try fixture.png(seed: 1, named: "a.png")
        let second = try fixture.png(seed: 2, named: "b.png")
        clipboard.ingestForTesting("newest")

        #expect(clipboard.importScreenshot(at: first, capturedAt: Self.date(100)))
        #expect(!clipboard.importScreenshot(at: first, capturedAt: Self.date(300)))
        #expect(clipboard.importScreenshot(at: second, capturedAt: Self.date(200)))
        #expect(clipboard.entries.dropFirst().map(\.capturedAt) == [Self.date(200), Self.date(100)])
    }

    @Test("An upgrade with no index imports, then writes version 1, readable only by the person")
    func upgradeWithoutIndex() async throws {
        defer { fixture.tearDown() }
        let capture = try await fixture.recording(at: 100)
        #expect(!FileManager.default.fileExists(atPath: fixture.indexURL.path))

        let library = fixture.library()
        library.load()
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.indexURL.path)[.posixPermissions]
        #expect(library.recordings.map(\.folder.path) == [capture.folder.path])
        #expect(permissions as? Int == 0o600)
        #expect(try fixture.indexText().contains("\"version\" : 1"))
    }

    @Test("A corrupt index is kept aside and rebuilt from the recordings folder, without importing screenshots again")
    func corruptIndex() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        try fixture.legacyScreenshot(at: 150, edited: false)
        fixture.library().load()
        fixture.clipboard.clearScreenshots()
        try Data("{ not json".utf8).write(to: fixture.indexURL)
        try await fixture.recording(at: 200)
        let before = fixture.snapshot()

        let library = fixture.library()
        library.load()
        #expect(library.state == .ready)
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)])
        #expect(fixture.savedRecordings() == library.recordings)
        #expect(try String(contentsOf: library.unreadableCopyURL, encoding: .utf8) == "{ not json")
        #expect(fixture.clipboard.entries.isEmpty)
        #expect(fixture.snapshot() == before)
    }

    @Test("A deleted index after the import is rebuilt from the recordings folder")
    func deletedIndex() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        try FileManager.default.removeItem(at: fixture.indexURL)

        let library = fixture.library()
        library.load()
        #expect(library.recordings.count == 1)
        #expect(fixture.savedRecordings()?.count == 1)
    }

    @Test(
        "A later build's index, however it's laid out, is left byte for byte, and the index is read-only",
        arguments: ["version 1's layout", "recordings keyed by ID", "no recordings list"]
    )
    func laterBuildsIndex(layout: String) async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        let current = try #require(JSONSerialization.jsonObject(with: Data(fixture.indexText().utf8)) as? [String: Any])
        let entry = try #require((current["recordings"] as? [Any])?.first as? [String: Any])
        let id = try #require(entry["id"] as? String)
        let later: [String: Any] = switch layout {
        case "version 1's layout": ["version": 2, "recordings": [entry]]
        case "recordings keyed by ID": ["version": 2, "recordings": [id: entry]]
        default: ["version": 2, "entries": [entry], "folders": [["path": "elsewhere"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: later, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fixture.indexURL)

        let library = fixture.library()
        library.load()
        #expect(library.state == .readOnly)
        #expect(library.recordings.count == (layout == "version 1's layout" ? 1 : 0), "what reads as version 1's entries")
        await library.launchCheck?.value
        #expect(library.recordings.count == 1, "the recordings folder's recording, listed once")
        library.add(try await fixture.recording(at: 200))
        #expect(library.recordings.count == 2)
        #expect(try Data(contentsOf: fixture.indexURL) == data)
        #expect(!FileManager.default.fileExists(atPath: library.unreadableCopyURL.path))
    }

    @Test(
        "A partly readable index keeps what it read, adds the recordings folder's, and is set aside once it's replaced",
        arguments: [true, false]
    )
    func partialIndex(importDone: Bool) async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        let kept = try #require(fixture.savedRecordings()?.first)
        try await fixture.recording(at: 200)
        let partial = try fixture.addUnreadableEntry()
        if !importDone { fixture.defaults.removeObject(forKey: RecordingImportMemory.key) }

        let library = fixture.library()
        library.load()
        #expect(library.state == .ready)
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)])
        #expect(library.recordings.last?.id == kept.id)
        #expect(fixture.savedRecordings() == library.recordings)
        #expect(try Data(contentsOf: library.unreadableCopyURL) == partial)
        #expect(fixture.importMemory.isDone)
    }

    @Test("A partly readable index whose replacement can't be written stays as it was, and the index is read-only")
    func partialIndexWriteFails() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        try await fixture.recording(at: 200)
        let partial = try fixture.addUnreadableEntry()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.support.path) }

        let library = fixture.library()
        library.load()
        #expect(library.state == .readOnly)
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)], "listed all the same")
        library.add(try await fixture.recording(at: 300))
        await library.launchCheck?.value
        #expect(try Data(contentsOf: fixture.indexURL) == partial)
        #expect(!FileManager.default.fileExists(atPath: library.unreadableCopyURL.path))
    }

    @Test("A partly readable index is replaced in place: recordings.json is the new index, and recordings.unreadable.json the old bytes, over any older copy")
    func partialIndexReplacedInPlace() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        try await fixture.recording(at: 200)
        let partial = try fixture.addUnreadableEntry()
        let library = fixture.library()
        // An older copy aside, and a replacement a crash left staged.
        try Data("an older unreadable index".utf8).write(to: library.unreadableCopyURL)
        try Data("a staged replacement".utf8).write(to: library.stagedURL)

        library.load()
        #expect(library.state == .ready)
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)])
        #expect(fixture.savedRecordings() == library.recordings)
        #expect(try Data(contentsOf: library.unreadableCopyURL) == partial)
        #expect(!FileManager.default.fileExists(atPath: library.stagedURL.path))
    }

    @Test(
        "An index that's there but can't be read lists the recordings folder, keeps its poster frames, and is never written",
        arguments: ["no permission", "a folder in its place"]
    )
    func unreadableIndex(cause: String) async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        let original = try Data(contentsOf: fixture.indexURL)
        let frame = fixture.posters.appendingPathComponent(try #require(fixture.savedRecordings()?.first?.posterFrame))
        try FileManager.default.createDirectory(at: fixture.posters, withIntermediateDirectories: true)
        try Data("a cached frame".utf8).write(to: frame)
        if cause == "no permission" {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.indexURL.path)
        } else {
            try FileManager.default.removeItem(at: fixture.indexURL)
            try FileManager.default.createDirectory(at: fixture.indexURL, withIntermediateDirectories: false)
        }

        let library = fixture.library()
        library.load()
        #expect(library.state == .readOnly)
        #expect(library.recordings.map(\.startedAt) == [Self.date(100)])
        library.add(try await fixture.recording(at: 200))
        #expect(library.recordings.count == 2)
        await library.launchCheck?.value
        #expect(!FileManager.default.fileExists(atPath: library.unreadableCopyURL.path))
        #expect(FileManager.default.fileExists(atPath: frame.path), "the poster frame the file names")
        if cause == "no permission" {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.indexURL.path)
            #expect(try Data(contentsOf: fixture.indexURL) == original)
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.indexURL.path).isEmpty)
        }
    }

    @Test("Each launch adds a recording saved to the recordings folder behind the index's back, after the load")
    func launchCheckAddsRecordings() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        fixture.library().load()
        let indexed = try #require(fixture.savedRecordings()?.first)
        try await fixture.recording(at: 200)

        let library = fixture.library()
        library.load()
        #expect(library.recordings.map(\.id) == [indexed.id], "not read in the load itself")
        await library.launchCheck?.value
        #expect(library.recordings.map(\.startedAt) == [Self.date(200), Self.date(100)])
        #expect(library.recordings.last?.id == indexed.id)
        #expect(fixture.savedRecordings() == library.recordings)
    }

    @Test("The launch check never lists an indexed recording twice, however either folder is spelled")
    func launchCheckMatchesResolvedPaths() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        let library = fixture.library()
        library.load()
        // One indexed through a link to the recordings folder.
        let alias = fixture.root.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.captures)
        let capture = try await fixture.recording(at: 200)
        let linked = alias.appendingPathComponent(RecordingLibraryFixture.folderName(200), isDirectory: true)
        library.add(ScreencastCapture(folder: linked, videos: capture.videos, duration: capture.duration, endedEarly: nil))
        #expect(library.recordings.map(\.folder.path).contains(linked.path))
        let index = try fixture.indexText()

        for folder in [fixture.captures, alias] {
            let reloaded = fixture.library(capturesFolder: folder)
            reloaded.load()
            await reloaded.launchCheck?.value
            #expect(reloaded.recordings.count == 2)
            #expect(try fixture.indexText() == index)
        }
    }

    // MARK: Where recordings are (#504, #605)

    @Test("The index looks only in ScreenGrabs' history; a recording an older build listed elsewhere stays listed where it is, and nothing is remembered")
    func looksOnlyInTheHistory() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100)
        let library = fixture.library()
        library.load()
        let before = fixture.snapshot()
        let elsewhere = fixture.root.url.appendingPathComponent("Elsewhere", isDirectory: true)

        library.add(try await fixture.recording(at: 200, in: elsewhere))
        #expect(library.recordings.map(\.folder.path) == [
            elsewhere.appendingPathComponent(RecordingLibraryFixture.folderName(200)).path,
            fixture.captures.appendingPathComponent(RecordingLibraryFixture.folderName(100)).path,
        ])
        #expect(fixture.defaults.object(forKey: RecordingFolderMemory.key) == nil)
        #expect(library.recordingsFolders.map(\.standardizedFileURL) == [fixture.captures.standardizedFileURL])
        #expect(fixture.snapshot() == before, "the history's recordings stay where they are")
    }

    @Test("Each launch adds a recording in the history behind the index's back; a folder outside it, even one an older build recorded into, is never read")
    func launchCheckReadsOnlyTheHistory() async throws {
        defer { fixture.tearDown() }
        let remembered = fixture.root.url.appendingPathComponent("Remembered", isDirectory: true)
        let library = fixture.library()
        library.load()
        library.add(try await fixture.recording(at: 100, in: remembered))
        fixture.defaults.set([remembered.path], forKey: RecordingFolderMemory.key)
        try await fixture.recording(at: 200, in: remembered)
        try await fixture.recording(at: 300)

        let next = fixture.library()
        next.load()
        await next.launchCheck?.value
        #expect(next.recordings.map(\.startedAt) == [Self.date(300), Self.date(100)])
        try FileManager.default.removeItem(at: fixture.indexURL)
        let rebuilt = fixture.library()
        rebuilt.load()
        #expect(rebuilt.recordings.map(\.startedAt) == [Self.date(300)])
    }

    @Test("ScreenGrabs coming on cleans up after an export cut short in the history")
    func recoveryInTheHistory() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let old = try await fixture.recording(at: 100)
        let saved = try await fixture.recording(at: 200)
        library.add(saved)
        let partials = [old.folder, saved.folder].map { $0.appendingPathComponent(".video-1.editing.mov") }
        for partial in partials { try Data("partial".utf8).write(to: partial) }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            review: fixture.reviewServices(recordings: library)
        )

        module.apply(fixture.context([.screenshotTools], preferences: preferences))
        let recovery = try #require(module.review.recovery)
        #expect(await recovery.value.removed == 2)
        #expect(partials.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: saved.videos[0].file.path))
    }

    @available(macOS 15, *)
    @Test("A recording kept as ScreenGrabs turns off mid-recording is saved in the history, listed, and copied where macOS saves screenshots, and still listed at the next launch")
    func shutDownMidRecordingIsListedNextLaunch() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.choice("0"), of: .screencastCountdown, for: .screenshotTools)
        // The history under the unit-test host: this run's own folder, which other tests record into too.
        let history = preferences.screencast.capturesFolder
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: history.path))
        let desktop = fixture.root.url.appendingPathComponent("Desktop", isDirectory: true)
        var review = fixture.reviewServices(recordings: library)
        review.copies = ScreengrabCopies(folder: { desktop })
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            seams: ScreencastSeams(
                captureSystem: FakeCaptureSystem(content: ScreencastScreens.content()),
                writers: FakeWriterFactory(),
                pickerSystem: FakePickerSystem(content: ScreencastScreens.content()),
                presenter: FakeOverlays(),
                screens: { PickerScreens.both },
                sleep: { _ in },
                contextReader: .inert
            ),
            review: review
        )
        module.apply(fixture.context([.screenshotTools], preferences: preferences))

        module.start()
        let controller = try #require(module.controller)
        let picker = try #require(controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        controller.confirm()
        #expect(await eventually { controller.phase == .recording })

        // Locked, or ScreenGrabs turned off: the recording is kept, listed, and copied, and nothing opens.
        module.deactivate(fixture.context([], preferences: preferences))
        #expect(await eventually { controller.phase == .idle && controller.recorder.state == .idle })
        let made = Set(try FileManager.default.contentsOfDirectory(atPath: history.path)).subtracting(before)
        let kept = try #require(made.map { history.appendingPathComponent($0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(ScreencastMetadata.fileName).path) })
        defer { try? FileManager.default.removeItem(at: kept) }
        #expect(await eventually { !library.recordings.isEmpty })
        #expect(library.recordings.map { ProductPaths.canonicalPath($0.folder) } == [ProductPaths.canonicalPath(kept)])
        #expect(module.review.panel == nil)
        let copy = desktop.appendingPathComponent(kept.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.contentsEqual(atPath: kept.path, andPath: copy.path), "its whole folder")

        let next = fixture.library(capturesFolder: history)
        next.load()
        await next.launchCheck?.value
        #expect(next.recordings.map { ProductPaths.canonicalPath($0.folder) }.contains(ProductPaths.canonicalPath(kept)))
    }

    @Test("In the history, a folder of the person's own is never listed or changed, even with a meta.json and an export's file names")
    func ownFoldersAreLeftAlone() async throws {
        defer { fixture.tearDown() }
        let history = fixture.captures
        let library = fixture.library()
        library.load()
        let saved = try await fixture.recording(at: 100)
        library.add(saved)
        // What a recording and an export cut short leave, in a folder Keybumps never made: a year's.
        let own = history.appendingPathComponent("2024", isDirectory: true)
        try FileManager.default.moveItem(at: try await fixture.recording(at: 200).folder, to: own)
        try Data("theirs".utf8).write(to: own.appendingPathComponent(".video-1.editing.mov"))
        try Data("theirs too".utf8).write(to: own.appendingPathComponent(".video-2.original.mov"))
        try Data("partial".utf8).write(to: saved.folder.appendingPathComponent(".video-1.editing.mov"))
        let before = fixture.snapshot(of: own)

        let next = fixture.library()
        next.load()
        await next.launchCheck?.value
        #expect(next.recordings.map(\.startedAt) == [Self.date(100)])
        try FileManager.default.removeItem(at: fixture.indexURL)
        let rebuilt = fixture.library()
        rebuilt.load()
        #expect(rebuilt.recordings.map(\.startedAt) == [Self.date(100)])

        #expect(ScreencastEditExporter.recoverInterruptedExports(in: history) == .init(removed: 1, restored: 0))
        #expect(fixture.snapshot(of: own) == before, "never renamed or deleted")
    }

    @Test("Only the names the recorder gives a recording's folder count as one")
    func recordingFolderNames() {
        #expect(["1791000000", "1000000000", "1791000000-2", "1791000000-12", "0", "0-2"].allSatisfy(ScreencastCaptureFolder.isFolderName))
        // A year, or any number shorter than a real clock's 10 digits, is the person's own.
        #expect(!["2024", "2024-1", "999999999", "0123456789", "00", "Project", "Project-2"]
            .contains(where: ScreencastCaptureFolder.isFolderName))
        #expect(!["", "-", "1791000000-", "-2", "1791000000-2-3", "1791000000 copy", "12a", "\u{FF11}\u{FF12}"]
            .contains(where: ScreencastCaptureFolder.isFolderName))
    }

    @Test("A recording is read again and removed through any spelling of its folder, such as a link")
    func changesMatchResolvedPaths() async throws {
        defer { fixture.tearDown() }
        let capture = try await fixture.recording(at: 100)
        let library = fixture.library()
        library.load()
        await library.launchCheck?.value
        let entry = try #require(library.recordings.first)
        let frame = fixture.posters.appendingPathComponent(entry.posterFrame)
        try FileManager.default.createDirectory(at: fixture.posters, withIntermediateDirectories: true)
        try Data("a cached frame".utf8).write(to: frame)
        let alias = fixture.root.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.captures)
        let linked = alias.appendingPathComponent(RecordingLibraryFixture.folderName(100), isDirectory: true)

        try fixture.setDuration(5, of: capture)
        library.update(linked)
        #expect(library.recordings.map(\.id) == [entry.id], "never listed twice")
        #expect(library.recordings.first?.duration == 5)

        library.remove(folder: linked)
        #expect(library.recordings.isEmpty)
        #expect(fixture.savedRecordings() == [])
        #expect(!FileManager.default.fileExists(atPath: frame.path))
    }

    @Test("A name in recordings.json or meta.json that leaves its folder, such as `..`, is treated as missing")
    func fileNamesStayInTheirFolders() async throws {
        defer { fixture.tearDown() }
        let capture = try await fixture.recording(at: 100)
        let victim = fixture.root.url.appendingPathComponent("victim.jpg")
        try Data("not a poster frame".utf8).write(to: victim)
        let id = UUID()
        let entry: [String: Any] = [
            "id": id.uuidString, "folder": capture.folder.path, "startedAt": RecordingLibraryFixture.iso8601(100),
            "posterFrame": "../victim.jpg",
            "videos": [
                ["file": "../200/video-1.mov"], ["file": "video-1.mov", "mixdown": ".."],
                ["file": ""], ["file": "."], ["file": "nested/video-1.mov"],
            ],
        ]
        try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "recordings": [entry]]).write(to: fixture.indexURL)
        fixture.importMemory.markDone()
        // meta.json: one recording with only a video outside its folder, one with such a mixdown.
        let outsideOnly = try await fixture.recording(at: 300)
        let outsideMixdown = try await fixture.recording(at: 400)
        try fixture.editMetadata(of: outsideOnly.folder) { $0["videos"] = [["file": "../100/video-1.mov"]] }
        try fixture.editMetadata(of: outsideMixdown.folder) { $0["videos"] = [["file": "video-1.mov", "mixdown": "../../x.mp4"]] }

        let library = fixture.library()
        library.load()
        await library.launchCheck?.value
        #expect(library.recordings.map(\.startedAt) == [Self.date(400), Self.date(100)])
        let checked = try #require(library.recordings.last)
        #expect(checked.videos == [IndexedRecording.Video(file: "video-1.mov", mixdown: nil)])
        #expect(checked.posterFrame == "\(id.uuidString).jpg")
        #expect(checked.sharingURLs.map(\.path) == [capture.folder.appendingPathComponent("video-1.mov").path])
        #expect(library.recordings.first?.videos == [IndexedRecording.Video(file: "video-1.mov", mixdown: nil)])

        var escaping = checked
        escaping.posterFrame = "../victim.jpg"
        #expect(library.posterFrames.url(for: escaping) == nil)
        library.posterFrames.remove(for: escaping)
        library.remove(folder: capture.folder)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("Poster frames no entry names are deleted when the index loads, and named ones and ones being written kept")
    func orphanPosterFrames() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        library.add(try await fixture.recording(at: 100))
        let entry = try #require(library.recordings.first)
        let kept = try #require(await library.posterFrame(for: entry))
        let orphan = fixture.posters.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("an old frame".utf8).write(to: orphan)
        // `PrivateFile`'s temporary files: one being written, and one a crash left two days ago.
        let writing = fixture.posters.appendingPathComponent(".\(UUID().uuidString).jpg.\(UUID().uuidString).tmp")
        let leftover = fixture.posters.appendingPathComponent(".\(UUID().uuidString).jpg.\(UUID().uuidString).tmp")
        try Data("a frame being written".utf8).write(to: writing)
        try Data("a crash's leftover".utf8).write(to: leftover)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: leftover.path)

        let reloaded = fixture.library()
        reloaded.load()
        await reloaded.launchCheck?.value
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: writing.path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("The index holds structure only: never the review, its note, or the app in front")
    func structureOnly() async throws {
        defer { fixture.tearDown() }
        try await fixture.recording(at: 100, review: true)
        fixture.library().load()

        let index = try fixture.indexText()
        #expect(!index.contains("review"))
        #expect(!index.contains(RecordingLibraryFixture.note))
        #expect(!index.contains(RecordingLibraryFixture.appName))
    }

    @Test("A poster frame is made from the video, made again when its file is gone, and removed with its entry")
    func posterFrame() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let capture = try await fixture.recording(at: 100)
        library.add(capture)
        let entry = try #require(library.recordings.first)

        let url = try #require(await library.posterFrame(for: entry))
        #expect(NSImage(contentsOf: url) != nil)
        try FileManager.default.removeItem(at: url)
        #expect(await library.posterFrame(for: entry) == url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        library.reviewEnded(.discarded(.video(capture)))
        #expect(library.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Save and Copy, which may have written edits, drop the poster frame and name a new one; closing only keeps it")
    func posterFrameAfterAnEdit() async throws {
        defer { fixture.tearDown() }
        let library = fixture.library()
        library.load()
        let capture = try await fixture.recording(at: 100)
        library.add(capture)
        let first = try #require(library.recordings.first)
        let kept = try #require(await library.posterFrame(for: first))

        library.reviewEnded(.closed(.video(capture)))
        #expect(library.recordings.first?.posterFrame == first.posterFrame)
        #expect(FileManager.default.fileExists(atPath: kept.path))

        for outcome in [ScreencastReviewOutcome.saved(.video(capture)), .copied(.video(capture))] {
            let before = try #require(library.recordings.first)
            let cached = try #require(await library.posterFrame(for: before))
            library.reviewEnded(outcome)
            let after = try #require(library.recordings.first)
            #expect(after.id == first.id)
            #expect(after.posterFrame != before.posterFrame)
            #expect(fixture.savedRecordings()?.first?.posterFrame == after.posterFrame)
            #expect(!FileManager.default.fileExists(atPath: cached.path), "the old frame is gone")
            let made = try #require(await library.posterFrame(for: after))
            #expect(made != cached)
            #expect(NSImage(contentsOf: made) != nil, "and the new one is made from the videos as they are")
        }

        // A frame still being made under the old name is dropped when it's done.
        let stale = try #require(library.recordings.first)
        async let making = library.posterFrame(for: stale)
        library.reviewEnded(.saved(.video(capture)))
        #expect(await making == nil)
        let staleURL = try #require(library.posterFrames.url(for: stale))
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    }
}

/// A temporary recordings folder, Application Support, and poster cache for one test, with
/// recordings written as the recorder writes them (a generated movie per display) and screenshot
/// folders as a QA build's Screencast wrote them before #487.
@MainActor
final class RecordingLibraryFixture {
    static let note = "a note only the person wrote"
    static let appName = "SomeBrowserApp"

    let root = TemporaryCapturesFolder()
    let defaults = InMemoryDefaults()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsRecordingLibrary-\(UUID().uuidString)"))
    var captures: URL { root.url.appendingPathComponent("captures", isDirectory: true) }

    /// The name of the folder made for a recording or screenshot at `seconds`: a real timestamp,
    /// as the recorder names one, so the index opens it. Its `meta.json` still says `seconds`.
    static func folderName(_ seconds: TimeInterval) -> String {
        String(1_791_000_000 + Int(seconds))
    }
    var support: URL { root.url.appendingPathComponent("support", isDirectory: true) }
    var indexURL: URL { support.appendingPathComponent(RecordingIndexFile.fileName) }
    var posters: URL { root.url.appendingPathComponent("posters", isDirectory: true) }
    var importMemory: RecordingImportMemory { RecordingImportMemory(defaults: defaults) }
    lazy var clipboard = ClipboardHistoryService(
        storageURL: support.appendingPathComponent("clipboard-history.json"),
        pasteboard: pasteboard,
        mediaDirectoryURL: support.appendingPathComponent("clipboard-media", isDirectory: true),
        sourceApps: .inert
    )
    private var movie: URL?

    func library(capturesFolder: URL? = nil) -> RecordingLibrary {
        RecordingLibrary(
            storageURL: indexURL,
            capturesFolder: capturesFolder ?? captures,
            posterFrames: RecordingPosterFrames(folder: posters),
            importMemory: importMemory,
            screenshots: clipboard,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    /// What the recording window takes from the app, indexing into `recordings`.
    func reviewServices(recordings: RecordingLibrary) -> ScreencastReviewServices {
        let repositories = ScreencastRepositoryMemory(storageURL: root.url.appendingPathComponent("repositories.json"))
        return ScreencastReviewServices(
            clipboard: clipboard,
            pasteboard: pasteboard,
            notices: nil,
            repositories: { repositories },
            recordings: recordings
        )
    }

    /// The flow the app hangs the recording window on, indexing into `recordings`.
    func reviewFlow(recordings: RecordingLibrary) -> ScreencastReviewFlow {
        ScreencastReviewFlow(services: reviewServices(recordings: recordings), contextReader: .inert)
    }

    /// What `ScreencastModule.apply` is given with `enabled` on.
    func context(_ enabled: Set<Capability>, preferences: AppPreferences) -> CapabilityContext {
        CapabilityContext(
            enabledCapabilities: enabled,
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: DrawingHotKeyBackend()),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        )
    }

    /// A recording's folder as the recorder leaves it, in the old recordings folder or `parent`: a
    /// generated one-second movie per display and its `meta.json`, with the recording window's
    /// review when asked.
    @discardableResult
    func recording(at seconds: TimeInterval, displays: Int = 1, review: Bool = false, in parent: URL? = nil) async throws -> ScreencastCapture {
        let source = try await generatedMovie()
        let folder = (parent ?? captures).appendingPathComponent(Self.folderName(seconds), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videos = try (0..<displays).map { index in
            let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index))
            try FileManager.default.copyItem(at: source, to: file)
            return ScreencastVideo(file: file, mixdown: nil, pixelWidth: 64, pixelHeight: 36, audioTracks: [], duration: 1)
        }
        let capture = ScreencastCapture(folder: folder, videos: videos, duration: 1, endedEarly: nil)
        let target: ScreencastTarget = displays > 1 ? .everyDisplay : .display(1)
        try ScreencastMetadata(capture: capture, target: target, startedAt: Date(timeIntervalSince1970: seconds))
            .write(to: capture.metadataURL)
        if review {
            try editMetadata(of: folder) {
                $0["review"] = ["note": Self.note, "context": ["appName": Self.appName], "type": "bug"]
            }
        }
        return capture
    }

    /// Writes a new duration into a recording's `meta.json`, as Save does after a trim.
    func setDuration(_ seconds: Double, of capture: ScreencastCapture) throws {
        try editMetadata(of: capture.folder) { $0["duration"] = seconds }
    }

    /// A screenshot folder a QA build's Screencast saved before #487: `screenshot-1.png`, and with
    /// `edited`, its marked-up copy and the review naming it.
    @discardableResult
    func legacyScreenshot(at seconds: TimeInterval, edited: Bool) throws -> URL {
        let folder = captures.appendingPathComponent(Self.folderName(seconds), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writePNG(seed: Int(seconds), to: folder.appendingPathComponent("screenshot-1.png"))
        var meta: [String: Any] = [
            "version": 1, "kind": "screenshot", "startedAt": Self.iso8601(seconds), "target": "display",
            "images": [["file": "screenshot-1.png", "width": 4, "height": 4]],
        ]
        if edited {
            try writePNG(seed: Int(seconds) + 1, to: folder.appendingPathComponent("screenshot-1 (edited).png"))
            meta["review"] = ["note": Self.note, "editedImages": ["screenshot-1.png": "screenshot-1 (edited).png"]]
        }
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent(ScreencastMetadata.fileName))
        return folder
    }

    /// A folder with no `meta.json`, one whose `meta.json` isn't JSON, and a stray file.
    func junk() throws {
        let bare = captures.appendingPathComponent("no-meta", isDirectory: true)
        let broken = captures.appendingPathComponent("broken-meta", isDirectory: true)
        for folder in [bare, broken] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("movie".utf8).write(to: bare.appendingPathComponent("video-1.mov"))
        try Data("not json".utf8).write(to: broken.appendingPathComponent(ScreencastMetadata.fileName))
        try Data("stray".utf8).write(to: captures.appendingPathComponent("notes.txt"))
    }

    func png(seed: Int, named name: String) throws -> URL {
        let url = root.url.appendingPathComponent(name)
        try writePNG(seed: seed, to: url)
        return url
    }

    /// Every file under `folder`, the old recordings folder unless given, by path, with its bytes.
    func snapshot(of folder: URL? = nil) -> [String: Data] {
        let files = FileManager.default.enumerator(at: folder ?? captures, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return Dictionary(uniqueKeysWithValues: files.compactMap { url in
            (try? Data(contentsOf: url)).map { (url.path, $0) }
        })
    }

    /// Adds an entry no build can decode to the index, returning the file's bytes.
    func addUnreadableEntry() throws -> Data {
        var index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any] ?? [:]
        index["recordings"] = (index["recordings"] as? [Any] ?? []) + [["id": "not an ID"]]
        let data = try JSONSerialization.data(withJSONObject: index)
        try data.write(to: indexURL)
        return data
    }

    func indexText() throws -> String {
        try String(contentsOf: indexURL, encoding: .utf8)
    }

    /// The recordings in the index file, or nil when it isn't a current index.
    func savedRecordings() -> [IndexedRecording]? {
        guard let data = try? Data(contentsOf: indexURL),
              case .current(let recordings, _) = RecordingIndexFile.read(data) else { return nil }
        return recordings
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        root.remove()
    }

    private func generatedMovie() async throws -> URL {
        if let movie { return movie }
        let url = root.url.appendingPathComponent("generated.mov")
        try await ReviewFixture.writeMovie(to: url, seconds: 1)
        movie = url
        return url
    }

    func editMetadata(of folder: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent(ScreencastMetadata.fileName)
        var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        edit(&meta)
        try JSONSerialization.data(withJSONObject: meta).write(to: url)
    }

    /// A 4×4 PNG of one gray, so each seed is different content.
    private func writePNG(seed: Int, to url: URL) throws {
        let gray = CGFloat(seed % 255) / 255
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor(white: gray, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    static func iso8601(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }
}
