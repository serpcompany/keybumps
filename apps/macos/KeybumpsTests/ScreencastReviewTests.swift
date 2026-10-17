import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Keybumps

/// The review's model and its file work, on captures made up in a temporary folder: no screen, no
/// real pasteboard (a named one per test), no window ordered in, and the owner's folders untouched.
@MainActor
@Suite("Screencast: the review")
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
            reviewedAt: ReviewFixture.reviewDate
        ))
        let metadata = try ScreencastMetadata.read(from: input.metadataURL)
        #expect(metadata.review == review, "the recorder's own type reads it back")
        #expect(metadata.videos.map(\.file) == ["video-1.mov"] && metadata.duration == 4, "the recorder's fields are kept")
        let permissions = try FileManager.default.attributesOfItem(atPath: input.metadataURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "user content: the person's alone")
        #expect(FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("A meta.json key the panel doesn't know is kept")
    func keepsUnknownMetadata() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input.metadataURL)) as? [String: Any])
        object["madeUpKey"] = "kept"
        try JSONSerialization.data(withJSONObject: object).write(to: input.metadataURL)
        let model = fixture.model(input)
        model.note = "Typo in the header"

        await model.save()
        #expect(model.isFinished)

        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input.metadataURL)) as? [String: Any])
        #expect(saved["madeUpKey"] as? String == "kept", "a key the panel doesn't know")
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "Typo in the header")
        #expect(ScreencastReview.read(from: input.metadataURL)?.type == .bug, "Bug unless chosen")
    }

    @Test("A corrected repository is remembered for the context; the guess fills it next time")
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
        #expect(second.guess?.source == .website("keybumps.app"))

        let byApp = fixture.model(try fixture.video(name: "1791000200"), context: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        byApp.repositoryText = "serpcompany/serp"
        await byApp.save()
        #expect(byApp.isFinished)
        let again = fixture.model(try fixture.video(name: "1791000300"), context: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        #expect(again.repositoryText == "serpcompany/serp" && again.guess?.source == .app("com.apple.dt.Xcode"))
    }

    @Test("Save stays open on a repository that isn't owner/name; closing saves without it")
    func invalidRepository() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        let model = fixture.model(input)
        model.note = "kept"
        model.repositoryText = "not a repo"

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

    @Test("A meta.json that can't be written keeps the window open with Save; closing still finishes, as a failed save")
    func metadataFailure() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video()
        try FileManager.default.removeItem(at: input.metadataURL)
        try FileManager.default.createDirectory(at: input.metadataURL, withIntermediateDirectories: true)
        let model = fixture.model(input)
        model.note = "secret note text"

        await model.save()
        #expect(model.failure == .metadataFailed && !model.isFinished)
        #expect(!(model.failure?.message.contains("secret") ?? true), "what the panel says names no user content")

        await model.close()
        #expect(model.isFinished)
        #expect(fixture.outcomes == [.saveFailed(input, .metadataFailed)], "never .saved")
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

    @Test("What the flow controller saved becomes the panel's input")
    func inputFromTheController() throws {
        defer { fixture.tearDown() }
        guard case .video(let capture) = try fixture.video() else {
            Issue.record("no fixture")
            return
        }
        #expect(ScreencastReviewInput(.video(capture)) == .video(capture))
        #expect(ScreencastReviewInput(.video(capture)).folder == ScreencastCaptureResult.video(capture).folder)
    }

    @Test("A recording with no file to copy copies nothing and leaves the clipboard as it was")
    func copyFailure() async throws {
        defer { fixture.tearDown() }
        guard case .video(let recorded) = try fixture.video() else { return }
        let input = ScreencastReviewInput.video(ScreencastCapture(folder: recorded.folder, videos: [], duration: 0, endedEarly: nil))
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("before", forType: .string)
        let model = fixture.model(input)
        await model.copy()
        #expect(model.failure == .copyFailed && !model.isFinished)
        #expect(fixture.pasteboard.string(forType: .string) == "before")
        #expect(fixture.suppressions.isEmpty)
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
        let input = try fixture.video()
        let model = fixture.model(input, fileManager: UnremovingFileManager())
        model.askToDiscard()
        model.confirmDiscard()
        #expect(model.failure == .deleteFailed && !model.isFinished)
        #expect(FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("Discard deletes only a folder that holds the capture's own files")
    func discardOnlyTheCapturesFolder() throws {
        defer { fixture.tearDown() }
        guard case .video(let capture) = try fixture.video() else { return }
        let wrongFolder = ScreencastReviewInput.video(ScreencastCapture(
            folder: fixture.folder.url, videos: capture.videos, duration: capture.duration, endedEarly: nil
        ))
        #expect(throws: ScreencastReviewFailure.deleteFailed) { try ScreencastReviewFiles.delete(wrongFolder, fileManager: .default) }
        let empty = ScreencastReviewInput.video(ScreencastCapture(folder: capture.folder, videos: [], duration: 0, endedEarly: nil))
        #expect(throws: ScreencastReviewFailure.deleteFailed) { try ScreencastReviewFiles.delete(empty, fileManager: .default) }
        #expect(capture.videos.allSatisfy { FileManager.default.fileExists(atPath: $0.file.path) })
    }

    // MARK: Keys, the window

    @Test("Return saves and Escape closes; the discard question, composing text, and a claimed key keep their keys")
    func keys() {
        func action(
            _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], composing: Bool = false,
            confirming: Bool = false, claimed: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: modifiers, isComposing: composing,
                isConfirmingDiscard: confirming, isClaimed: claimed
            )
        }
        #expect(action(36) == .save && action(76) == .save && action(36, .shift) == .save)
        #expect(action(53) == .close)
        #expect(action(53, confirming: true) == .keep && action(36, confirming: true) == .ignore)
        #expect(action(36, composing: true) == .pass && action(53, composing: true) == .pass)
        #expect(action(36, .command) == .pass && action(53, .option) == .pass)
        #expect(action(53, claimed: true) == .pass && action(53, confirming: true, claimed: true) == .pass,
                "Escape is the next recording's drawing's while it draws, whichever monitor hears it first")
        #expect(action(0) == .pass)
    }

    @Test("Under the unit-test host the window never shows and takes no keys")
    func windowStaysOffScreen() async throws {
        defer { fixture.tearDown() }
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { nil }
        )
        var outcomes: [ScreencastReviewOutcome] = []
        panel.onFinish = { outcomes.append($0) }
        let first = try fixture.video()
        await panel.show(first, context: .none)
        #expect(panel.isShown && !panel.window.isVisible && !panel.window.canBecomeKey)
        #expect(panel.window.identifier?.rawValue == "screencast.review.window")

        let second = try fixture.video(name: "1791000100")
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

// MARK: - Harness

/// A temporary captures folder, a named pasteboard, a repository memory and a Clipboard History in
/// the folder, and the review models' outcomes.
@MainActor
final class ReviewFixture {
    static let reviewDate = Date(timeIntervalSince1970: 1_791_000_000)

    let folder = TemporaryCapturesFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreencastReview-\(UUID().uuidString)"))
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

    func model(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext = .none,
        contextRead: Task<ScreencastCaptureContext, Never>? = nil,
        fileManager: FileManager = .default,
        keepOutOfClipboardHistory: (() -> Void)? = nil,
        export: ScreencastEditExport = .movies
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
            now: { Self.reviewDate },
            export: export
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

/// A file manager that can't delete anything.
private final class UnremovingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

