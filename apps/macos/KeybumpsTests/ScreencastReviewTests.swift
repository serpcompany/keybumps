import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Keybumps

/// The review panel's model and its file work, on captures made up in a temporary folder: no
/// screen, no real pasteboard (a named one per test), no window ordered in, and the owner's
/// folders untouched.
@MainActor
@Suite("Screencast: the review panel")
struct ScreencastReviewTests {
    let fixture = ReviewFixture()

    // MARK: Save and meta.json

    @Test("Save writes the note, type, repository, and capture-time context into meta.json, keeping the recorder's")
    func saveWritesTheReview() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        let context = ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "keybumps.app")
        let model = fixture.model(input, context: context)
        model.note = "The buy button\ndoes nothing\t"
        model.type = .feature
        model.repositoryText = " https://github.com/serpcompany/keybumps "

        await model.save()
        #expect(model.isFinished)

        #expect(fixture.outcomes == [.saved(input)])
        let review = try #require(ScreencastReview.read(from: input.metadataURL))
        #expect(review == ScreencastReview(
            note: "The buy button does nothing",
            type: .feature,
            repository: "serpcompany/keybumps",
            context: context,
            editedImages: nil,
            reviewedAt: ReviewFixture.reviewDate
        ))
        let metadata = try ScreencastMetadata.read(from: input.metadataURL)
        #expect(metadata.review == review, "the recorder's own type reads it back")
        #expect(metadata.videos.map(\.file) == ["video-1.mov"] && metadata.duration == 4, "the recorder's fields are kept")
        let permissions = try FileManager.default.attributesOfItem(atPath: input.metadataURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "user content: the person's alone")
        #expect(FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("A screenshot's own meta.json keys are kept, whatever they are")
    func keepsScreenshotMetadata() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let model = fixture.model(input)
        model.note = "Typo in the header"

        await model.save()
        #expect(model.isFinished)

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input.metadataURL)) as? [String: Any])
        #expect(object["kind"] as? String == "screenshot")
        #expect(object["madeUpKey"] as? String == "kept", "a key the panel doesn't know")
        let metadata = try ScreencastScreenshotMetadata.read(from: input.metadataURL)
        #expect(metadata.images.map(\.file) == ["screenshot-1.png"], "the screenshot's own type still reads it")
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "Typo in the header")
        #expect(ScreencastReview.read(from: input.metadataURL)?.type == .bug, "Bug unless chosen")
    }

    @Test("A corrected repository is remembered for the context; the guess fills the field next time")
    func saveRemembersTheCorrection() async throws {
        defer { fixture.tearDown() }
        let context = ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "keybumps.app")
        let first = fixture.model(try fixture.video(), context: context)
        #expect(first.repositoryText.isEmpty && first.guess == nil)
        first.repositoryText = "serpcompany/keybumps"
        await first.save()
        #expect(first.isFinished)

        let second = fixture.model(try fixture.video(name: "1791000100"), context: context)
        #expect(second.repositoryText == "serpcompany/keybumps")
        #expect(second.repositoryHint == "Remembered for keybumps.app")

        let byApp = fixture.model(try fixture.video(name: "1791000200"), context: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        byApp.repositoryText = "serpcompany/serp"
        await byApp.save()
        #expect(byApp.isFinished)
        let again = fixture.model(try fixture.video(name: "1791000300"), context: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        #expect(again.repositoryHint == "Remembered for Xcode")
    }

    @Test("Save stays open on a repository that isn't owner/name; closing saves without it")
    func invalidRepository() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let model = fixture.model(input)
        model.note = "kept"
        model.repositoryText = "not a repo"
        #expect(model.repositoryHint == "Type it as owner/name.")

        await model.save()
        #expect(model.failure == .invalidRepository && !model.isFinished)
        #expect(ScreencastReview.read(from: input.metadataURL) == nil)

        await model.close()
        #expect(model.isFinished)
        #expect(fixture.outcomes == [.saved(input)])
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "kept")
        #expect(ScreencastReview.read(from: input.metadataURL)?.repository == nil)
        #expect(fixture.repositories.stored == ScreencastRepositoryMemory.Stored())
    }

    @Test("Closing without a choice saves the capture with what's typed")
    func closeSaves() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        let model = fixture.model(input)
        model.note = "half a thought"
        await model.close()
        #expect(model.isFinished)
        #expect(fixture.outcomes == [.saved(input)])
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "half a thought")
        #expect(FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("A meta.json that can't be written keeps the panel open with Save; closing still finishes")
    func metadataFailure() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        try FileManager.default.removeItem(at: input.metadataURL)
        try FileManager.default.createDirectory(at: input.metadataURL, withIntermediateDirectories: true)
        let model = fixture.model(input)
        model.note = "secret note text"

        await model.save()
        #expect(model.failure == .metadataFailed && !model.isFinished)
        #expect(!(model.failure?.message.contains("secret") ?? true), "what the panel says names no user content")

        await model.close()
        #expect(model.isFinished)
        #expect(fixture.outcomes == [.saved(input)])
    }

    // MARK: Copy, and the clipboard skip

    @Test("Copy saves, then puts each display's mixdown (or file) on the pasteboard as files")
    func copiesARecording() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(displays: 2, mixdown: true)
        let model = fixture.model(input)
        await model.copy()
        #expect(model.isFinished)

        #expect(fixture.outcomes == [.copied(input)])
        let urls = fixture.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.lastPathComponent) == ["video-1-mixdown.mp4", "video-2-mixdown.mp4"])
        #expect(fixture.suppressions == [fixture.pasteboard.changeCount], "marked right after the write")
        #expect(ScreencastReview.read(from: input.metadataURL) != nil)
    }

    @Test("Copy puts each display's screenshot on the pasteboard as an item, the image and its file; a marked-up copy goes in its place")
    func copiesAScreenshot() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot(displays: 2)
        let editor = FakeScreenshotEditor()
        let model = fixture.model(input, editor: editor)
        let images = try #require(fixture.screenshotURLs)
        #expect(model.displayCount == 2)
        model.selectedDisplay = 1
        model.edit()
        #expect(model.isEditing && editor.opened == [images[1]], "Edit opens the display shown")
        let edited = input.folder.appendingPathComponent("screenshot-2 (edited).png")
        try ReviewFixture.png(seed: "edited").write(to: edited)
        editor.finishEditing(savedAt: edited)
        #expect(!model.isEditing && model.editedImages == [1: edited])
        #expect(model.screenshotFiles == [images[0], edited])

        await model.copy()
        #expect(model.isFinished)
        let items = try #require(fixture.pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].data(forType: .png) == (try Data(contentsOf: images[0])))
        #expect(items[0].string(forType: .fileURL) == images[0].absoluteString)
        #expect(items[1].data(forType: .png) == (try Data(contentsOf: edited)))
        #expect(items[1].string(forType: .fileURL) == edited.absoluteString)
        #expect(ScreencastReview.read(from: input.metadataURL)?.editedImages == ["screenshot-2.png": "screenshot-2 (edited).png"])
    }

    @Test("What the flow controller saved becomes the panel's input")
    func inputFromTheController() throws {
        defer { fixture.tearDown() }
        guard case .video(let capture) = try fixture.video(), case .screenshot(let screenshot) = try fixture.screenshot(name: "1791000100") else {
            Issue.record("no fixture")
            return
        }
        #expect(ScreencastReviewInput(.video(capture)) == .video(capture))
        #expect(ScreencastReviewInput(.screenshot(screenshot)) == .screenshot(screenshot))
        #expect(ScreencastReviewInput(.screenshot(screenshot)).folder == ScreencastCaptureResult.screenshot(screenshot).folder)
    }

    @Test("Copy is kept out of Clipboard History, though the same write is otherwise recorded")
    func copySkipsClipboardHistory() async throws {
        defer { fixture.tearDown() }
        let clipboard = fixture.clipboard
        let model = fixture.model(try fixture.screenshot(), keepOutOfClipboardHistory: { clipboard.suppressCurrentChange() })
        await model.copy()
        #expect(model.isFinished)
        clipboard.pollForTesting()
        #expect(clipboard.entries.isEmpty)

        // The same write without the mark is recorded, so the skip is what kept it out.
        let other = fixture.model(try fixture.screenshot(name: "1791000100", seed: "other"))
        await other.copy()
        #expect(other.isFinished)
        clipboard.pollForTesting()
        #expect(clipboard.entries.count == 1)
    }

    @Test("A screenshot that can't be read copies nothing and leaves the clipboard as it was")
    func copyFailure() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        try FileManager.default.removeItem(at: try #require(fixture.screenshotURL))
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("before", forType: .string)
        let model = fixture.model(input)
        await model.copy()
        #expect(model.failure == .copyFailed && !model.isFinished)
        #expect(fixture.pasteboard.string(forType: .string) == "before")
        #expect(fixture.suppressions.isEmpty)
    }

    // MARK: Also add to Screenshots (⌘3)

    @Test("Saving a screenshot with the switch on adds each display's to the Screenshots tab, from Screencast, without the pasteboard")
    func addsToScreenshots() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot(displays: 2)
        let images = try #require(fixture.screenshotURLs)
        let changeCount = fixture.pasteboard.changeCount
        let model = fixture.model(input, screenshots: fixture.clipboard)
        #expect(model.showsAddToScreenshots && model.addsToScreenshots, "on at first")
        await model.save()
        #expect(model.isFinished)

        let entries = fixture.clipboard.entries
        #expect(entries.count == 2 && entries.allSatisfy(\.isScreenshot))
        #expect(entries.allSatisfy { $0.sourceApp?.name == "Screencast" })
        #expect(Set(entries.compactMap(\.sourcePath)) == Set(images.map(\.path)))
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the originals stay in the capture's folder")
    }

    @Test("The switch is remembered; off, Save adds nothing, and Copy never adds")
    func switchOffAndCopy() async throws {
        defer { fixture.tearDown() }
        let first = fixture.model(try fixture.screenshot(), screenshots: fixture.clipboard)
        first.addsToScreenshots = false
        #expect(fixture.defaults.object(forKey: ScreencastReviewSettings.addsToScreenshotsKey) as? Bool == false)
        await first.save()
        #expect(first.isFinished)
        #expect(fixture.clipboard.entries.isEmpty)

        let second = fixture.model(try fixture.screenshot(name: "1791000100", seed: "b"), screenshots: fixture.clipboard)
        #expect(!second.addsToScreenshots, "remembered")
        second.addsToScreenshots = true
        await second.copy()
        #expect(second.isFinished)
        #expect(fixture.clipboard.entries.isEmpty)
    }

    @Test("The switch is hidden while Clipboard History is off, and for a recording")
    func switchHidden() async throws {
        defer { fixture.tearDown() }
        #expect(!fixture.model(try fixture.screenshot()).showsAddToScreenshots)
        let video = fixture.model(try fixture.video(), screenshots: fixture.clipboard)
        #expect(!video.showsAddToScreenshots)
        await video.save()
        #expect(video.isFinished)
        #expect(fixture.clipboard.entries.isEmpty)
    }

    // MARK: Discard

    @Test("Discard asks first; Keep deletes nothing, and Discard deletes the capture's folder")
    func discard() throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        let model = fixture.model(input)
        model.confirmDiscard()
        #expect(FileManager.default.fileExists(atPath: input.folder.path), "nothing without the question")

        model.askToDiscard()
        #expect(model.isConfirmingDiscard)
        model.keep()
        #expect(!model.isConfirmingDiscard && FileManager.default.fileExists(atPath: input.folder.path))

        model.askToDiscard()
        model.confirmDiscard()
        #expect(!FileManager.default.fileExists(atPath: input.folder.path))
        #expect(fixture.outcomes == [.discarded])
        #expect(fixture.folder.captureFolders().isEmpty)
    }

    @Test("A folder that can't be deleted stays, and the panel says so")
    func discardFailure() throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let model = fixture.model(input, fileManager: UnremovingFileManager())
        model.askToDiscard()
        model.confirmDiscard()
        #expect(model.failure == .deleteFailed && !model.isFinished)
        #expect(FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("Discard deletes only a folder that holds the capture's own files")
    func discardOnlyTheCapturesFolder() throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let image = try #require(fixture.screenshotURL)
        let wrongFolder = ScreencastReviewInput.screenshot(ScreencastScreenshot(
            folder: fixture.folder.url,
            images: [ScreencastScreenshot.Image(file: image, pixelWidth: 2, pixelHeight: 2)]
        ))
        #expect(throws: ScreencastReviewFailure.deleteFailed) { try ScreencastReviewFiles.delete(wrongFolder, fileManager: .default) }
        let empty = ScreencastReviewInput.video(ScreencastCapture(folder: input.folder, videos: [], duration: 0, endedEarly: nil))
        #expect(throws: ScreencastReviewFailure.deleteFailed) { try ScreencastReviewFiles.delete(empty, fileManager: .default) }
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    // MARK: Sending, editing, keys, placement

    @Test("The destination shows None yet, and Save and Send and Send and Delete can't be used")
    func noDestinationYet() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.screenshot())
        #expect(model.destinationTitle == "None yet")
        #expect(!model.canSend)
    }

    @Test("Edit is offered for a screenshot with an editor; an editor already busy says so")
    func editAvailability() throws {
        defer { fixture.tearDown() }
        #expect(!fixture.model(try fixture.screenshot()).canEdit)
        #expect(!fixture.model(try fixture.video(), editor: FakeScreenshotEditor()).canEdit)
        let busy = FakeScreenshotEditor()
        busy.opens = false
        let model = fixture.model(try fixture.screenshot(name: "1791000100", seed: "b"), editor: busy)
        #expect(model.canEdit)
        model.edit()
        #expect(model.failure == .editorUnavailable && !model.isEditing)
    }

    @Test("Closing while the editor is open saves the review and leaves the editor, whose later Save is recorded")
    func closeCancelsTheEditor() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let editor = FakeScreenshotEditor()
        let model = fixture.model(input, editor: editor, screenshots: fixture.clipboard)
        model.edit()
        await model.save()
        #expect(!model.isFinished, "Save does nothing while the editor is open")
        await model.close()
        #expect(model.isFinished && fixture.outcomes == [.saved(input)])
        #expect(editor.isOpen, "the editor stays open with its markup")
        #expect(ScreencastReview.read(from: input.metadataURL)?.editedImages == nil)
        #expect(fixture.clipboard.entries.isEmpty, "the image being edited waits for the editor")

        let edited = input.folder.appendingPathComponent("screenshot-1 (edited).png")
        try ReviewFixture.png(seed: "late").write(to: edited)
        editor.finishEditing(savedAt: edited)
        #expect(ScreencastReview.read(from: input.metadataURL)?.editedImages == ["screenshot-1.png": "screenshot-1 (edited).png"],
                "a Save in the editor after the panel closed is still recorded")
        #expect(fixture.clipboard.entries.map(\.sourcePath) == [edited.path], "and goes to ⌘3, marked up")
    }

    @Test("Return saves and Escape closes; the discard question, composing text, and a claimed key keep their keys")
    func keys() {
        func action(
            _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], composing: Bool = false,
            confirming: Bool = false, editing: Bool = false, claimed: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: modifiers, isComposing: composing,
                isConfirmingDiscard: confirming, isEditing: editing, isClaimed: claimed
            )
        }
        #expect(action(53, editing: true) == .ignore && action(36, editing: true) == .ignore, "the editor's markup is never thrown away")
        #expect(action(36) == .save && action(76) == .save && action(36, .shift) == .save)
        #expect(action(53) == .close)
        #expect(action(53, confirming: true) == .keep && action(36, confirming: true) == .ignore)
        #expect(action(36, composing: true) == .pass && action(53, composing: true) == .pass)
        #expect(action(36, .command) == .pass && action(53, .option) == .pass)
        #expect(action(53, claimed: true) == .pass && action(53, confirming: true, claimed: true) == .pass,
                "Escape is the next recording's drawing's while it draws, whichever monitor hears it first")
        #expect(action(0) == .pass)
    }

    @Test("The panel sits in the bottom-right corner, 20 points in, and stays on a short screen")
    func placement() {
        let frame = CGRect(x: 100, y: 50, width: 1_000, height: 800)
        #expect(ScreencastReviewPanel.origin(for: CGSize(width: 400, height: 500), in: frame) == CGPoint(x: 680, y: 70))
        #expect(ScreencastReviewPanel.origin(for: CGSize(width: 1_200, height: 900), in: frame) == CGPoint(x: 100, y: 50))
    }

    @Test("Under the unit-test host the panel shows no window and takes no keys")
    func panelStaysOffScreen() async throws {
        defer { fixture.tearDown() }
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screenshots: { nil },
            settings: ScreencastReviewSettings(defaults: fixture.defaults),
            screen: { nil }
        )
        var outcomes: [ScreencastReviewOutcome] = []
        panel.onFinish = { outcomes.append($0) }
        let first = try fixture.video()
        await panel.show(first, context: .none)
        #expect(panel.isShown && !panel.panel.isVisible && !panel.panel.canBecomeKey)
        #expect(panel.panel.identifier?.rawValue == "screencast.review.panel")

        let second = try fixture.screenshot()
        await panel.show(second, context: .none)
        #expect(outcomes == [.saved(first)], "a new capture closes the one under review, which saves it")
        await panel.close()
        #expect(outcomes == [.saved(first), .saved(second)] && !panel.isShown)
    }

    @Test("The review's sources log only failure categories, never the note, repository, context, or a file")
    func logsNoUserContent() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Keybumps/Screencast/Review", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        var logLines = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["print(", "NSLog(", "os_log(", "debugPrint(", "dump("] {
                #expect(!text.contains(call), "\(file.lastPathComponent) calls \(call)")
            }
            for line in text.components(separatedBy: "\n") where line.contains("logger.") && line.contains("(\"") {
                logLines += 1
                let interpolations = line.components(separatedBy: "\\(").dropFirst().map { $0.components(separatedBy: ")").first ?? "" }
                #expect(interpolations.allSatisfy { $0 == "failure.rawValue, privacy: .public" }, "\(file.lastPathComponent): \(line)")
            }
        }
        #expect(logLines >= 1, "the scan still finds the log call")
    }
}

/// A temporary captures folder, a named pasteboard, in-memory preferences, a repository memory and
/// a Clipboard History in the folder, and the review models' outcomes.
@MainActor
final class ReviewFixture {
    static let reviewDate = Date(timeIntervalSince1970: 1_791_000_000)

    let folder = TemporaryCapturesFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreencastReview-\(UUID().uuidString)"))
    let defaults = InMemoryDefaults()
    lazy var repositories = ScreencastRepositoryMemory(storageURL: folder.url.appendingPathComponent("repositories.json"))
    lazy var clipboard = ClipboardHistoryService(
        storageURL: folder.url.appendingPathComponent("clipboard/history.json"),
        pasteboard: pasteboard,
        mediaDirectoryURL: folder.url.appendingPathComponent("clipboard/media", isDirectory: true),
        sourceApps: .inert
    )
    private(set) var outcomes: [ScreencastReviewOutcome] = []
    /// The pasteboard's change count each time Copy asked to be kept out of Clipboard History.
    private(set) var suppressions: [Int] = []
    /// The last screenshot's images, by display.
    private(set) var screenshotURLs: [URL]?
    var screenshotURL: URL? { screenshotURLs?.first }

    func model(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext = .none,
        contextRead: Task<ScreencastCaptureContext, Never>? = nil,
        fileManager: FileManager = .default,
        editor: (any ScreencastScreenshotEditing)? = nil,
        screenshots: (any ScreencastScreenshotsLibrary)? = nil,
        keepOutOfClipboardHistory: (() -> Void)? = nil
    ) -> ScreencastReviewModel {
        let pasteboard = pasteboard
        let model = ScreencastReviewModel(
            input: input,
            context: context,
            contextRead: contextRead,
            repositories: repositories,
            fileManager: fileManager,
            pasteboard: pasteboard,
            keepOutOfClipboardHistory: keepOutOfClipboardHistory ?? { [weak self] in self?.suppressions.append(pasteboard.changeCount) },
            editor: editor,
            screenshots: screenshots,
            settings: ScreencastReviewSettings(defaults: defaults),
            now: { Self.reviewDate }
        )
        model.onFinish = { [weak self] in self?.outcomes.append($0) }
        return model
    }

    /// A recording's folder with stand-in files ("original <name>") and the recorder's meta.json,
    /// four seconds per display.
    func video(name: String = "1791000000", displays: Int = 1, mixdown: Bool = true) throws -> ScreencastReviewInput {
        let captureFolder = folder.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        let videos = try (0..<displays).map { index in
            let file = captureFolder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index))
            try Data("original \(file.lastPathComponent)".utf8).write(to: file)
            var mixdownURL: URL?
            if mixdown {
                let url = captureFolder.appendingPathComponent(ScreencastCaptureFolder.mixdownName(index: index))
                try Data("original \(url.lastPathComponent)".utf8).write(to: url)
                mixdownURL = url
            }
            return ScreencastVideo(file: file, mixdown: mixdownURL, pixelWidth: 64, pixelHeight: 36, audioTracks: mixdown ? [.microphone, .systemAudio] : [], duration: 4)
        }
        let capture = ScreencastCapture(folder: captureFolder, videos: videos, duration: 4, endedEarly: nil)
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: Self.reviewDate).write(to: capture.metadataURL)
        return .video(capture)
    }

    /// A screenshot's folder, as the flow controller saves one: a small PNG per display, and its
    /// `meta.json` with one key more that the review panel doesn't know.
    func screenshot(name: String = "1791000000", seed: String = "a", displays: Int = 1) throws -> ScreencastReviewInput {
        let captureFolder = folder.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        let images = try (0..<displays).map { index in
            let file = captureFolder.appendingPathComponent(ScreencastCaptureFolder.screenshotName(index: index))
            try Self.png(seed: "\(seed)\(index)").write(to: file)
            return ScreencastScreenshot.Image(file: file, pixelWidth: 2, pixelHeight: 2)
        }
        let screenshot = ScreencastScreenshot(folder: captureFolder, images: images)
        try ScreencastScreenshotMetadata(screenshot: screenshot, target: .display(1), startedAt: Self.reviewDate).write(to: screenshot.metadataURL)
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: screenshot.metadataURL)) as? [String: Any])
        metadata["madeUpKey"] = "kept"
        try JSONSerialization.data(withJSONObject: metadata).write(to: screenshot.metadataURL)
        screenshotURLs = images.map(\.file)
        return .screenshot(screenshot)
    }

    /// A 2×2 PNG whose pixels are `seed`'s bytes, so each seed is a different image.
    static func png(seed: String) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        )!
        let bytes = Array(seed.utf8)
        for index in 0..<16 {
            // Opaque, so no channel is dropped as premultiplied.
            rep.bitmapData![index] = index % 4 == 3 ? 255 : bytes[index % bytes.count]
        }
        return rep.representation(using: .png, properties: [:])!
    }

    /// A real movie from the recorder's writer: `seconds` of frames at 30 a second, no sound.
    nonisolated static func writeMovie(to url: URL, seconds: Double) async throws {
        let writer = try ScreencastMovieWriter(
            url: url, pixelWidth: 64, pixelHeight: 36, audio: [], options: ScreencastOptions(),
            fragmentInterval: ScreencastMovieWriter.fragmentInterval, onFailure: {}
        )
        for frame in 0..<Int(seconds * 30) {
            writer.appendVideo(ScreencastSamples.video(at: 100 + Double(frame) / 30, width: 64, height: 36, shade: UInt8(frame % 255)))
        }
        _ = await writer.finish(at: 100 + seconds)
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// The Screenshot Editor, opened and finished by the test. It never touches the pasteboard, as the
/// real one doesn't when `copiesToClipboard` is off (`editorSaveWithoutCopy` checks that one).
@MainActor
final class FakeScreenshotEditor: ScreencastScreenshotEditing {
    var opens = true
    private(set) var opened: [URL] = []
    private(set) var copyRequests: [Bool] = []
    private var onFinish: ((URL?) -> Void)?

    var isOpen: Bool { onFinish != nil }

    func editScreenshot(at image: URL, copiesToClipboard: Bool, onFinish: @escaping (URL?) -> Void) -> Bool {
        guard opens else { return false }
        opened.append(image)
        copyRequests.append(copiesToClipboard)
        self.onFinish = onFinish
        return true
    }

    func finishEditing(savedAt url: URL?) {
        onFinish?(url)
        onFinish = nil
    }
}

/// A file manager that can't delete anything.
private final class UnremovingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
