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
        let input = try fixture.video()
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

    // MARK: Trim, with stand-in files

    @Test("The player's trim is kept for Save, and a trim that keeps everything is none")
    func trimRangeFromThePlayer() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        let player = FakeTrimPresenter()
        model.trim(with: player)
        #expect(model.isTrimming && !model.acceptsActions)
        player.complete(1...3)
        #expect(!model.isTrimming && model.trimRange == ScreencastTrimRange(start: 1, end: 3, within: 4))
        #expect(model.durationText == "00:02")

        model.trim(with: player)
        player.complete(nil)
        #expect(model.trimRange == ScreencastTrimRange(start: 1, end: 3, within: 4), "Cancel keeps the earlier trim")
        model.trim(with: player)
        player.complete(0...4)
        #expect(model.trimRange == nil)
        #expect(ScreencastTrimRange(start: 2, end: 2.01, within: 4) == nil, "nothing kept isn't a trim")
        #expect(ScreencastTrimRange(start: -1, end: 9, within: 4) == nil)
    }

    @Test("Save swaps in every cut, recording and mixdown, and records the new durations")
    func trimReplacesTheFiles() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(displays: 2, mixdown: true)
        let trimmer = FakeTrimmer()
        let model = fixture.model(input, trimmer: trimmer)
        model.setTrim(ScreencastTrimRange(start: 1, end: 3, within: 4))
        await model.save()
        #expect(model.isFinished)

        #expect(trimmer.cutCount == 4)
        #expect(trimmer.cutRecordingsForMixdowns == [".video-1.trimmed.mov", ".video-2.trimmed.mov"],
                "each mixdown's cut can be made from its recording's")
        for name in ["video-1.mov", "video-1-mixdown.mp4", "video-2.mov", "video-2-mixdown.mp4"] {
            #expect(try String(contentsOf: input.folder.appendingPathComponent(name), encoding: .utf8) == "cut of \(name)")
        }
        #expect(try fixture.hiddenFiles(in: input.folder).isEmpty, "no cut or original left aside")
        let metadata = try ScreencastMetadata.read(from: input.metadataURL)
        #expect(metadata.duration == 2 && metadata.videos.map(\.duration) == [2, 2])
        guard case .saved(.video(let trimmed)) = fixture.outcomes.first else { Issue.record("not saved"); return }
        #expect(trimmed.duration == 2 && trimmed.videos.map(\.duration) == [2, 2])
    }

    @Test("A cut that fails leaves every file as it was, and the panel open; closing then keeps it untrimmed")
    func failedCutKeepsTheRecording() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(displays: 1, mixdown: true)
        let trimmer = FakeTrimmer(failingFrom: 1)
        let model = fixture.model(input, trimmer: trimmer)
        model.setTrim(ScreencastTrimRange(start: 1, end: 3, within: 4))
        await model.save()

        #expect(model.failure == .trimFailed && !model.isFinished)
        #expect(try fixture.originalContents(of: input) == ["original video-1.mov", "original video-1-mixdown.mp4"])
        #expect(try fixture.hiddenFiles(in: input.folder).isEmpty)

        await model.close()
        #expect(model.isFinished)
        #expect(try fixture.originalContents(of: input) == ["original video-1.mov", "original video-1-mixdown.mp4"])
        #expect(try ScreencastMetadata.read(from: input.metadataURL).duration == 4)
        #expect(ScreencastReview.read(from: input.metadataURL) != nil)
    }

    @Test("A swap that fails puts back the originals already swapped")
    func failedSwapPutsOriginalsBack() async throws {
        defer { fixture.tearDown() }
        guard case .video(let capture) = try fixture.video(displays: 2, mixdown: false) else { return }
        let fileManager = MoveRefusingFileManager(refusing: "video-2.mov")
        let range = try #require(ScreencastTrimRange(start: 1, end: 3, within: 4))
        await #expect(throws: ScreencastReviewFailure.trimFailed) {
            try await ScreencastReviewFiles.trim(
                capture,
                to: range,
                trimmer: FakeTrimmer(),
                fileManager: fileManager
            )
        }
        #expect(try fixture.originalContents(of: .video(capture)) == ["original video-1.mov", "original video-2.mov"])
        #expect(try fixture.hiddenFiles(in: capture.folder).isEmpty)
    }

    // MARK: Sending, keys, placement

    @Test("The destination shows None yet, and Save and Send and Send and Delete can't be used")
    func noDestinationYet() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        #expect(model.destinationTitle == "None yet")
        #expect(!model.canSend)
    }

    @Test("Return saves and Escape closes; the discard question, the trim controls, composing text, and a claimed key keep their keys")
    func keys() {
        func action(
            _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], trimming: Bool = false, composing: Bool = false,
            confirming: Bool = false, claimed: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: modifiers, isTrimming: trimming, isComposing: composing,
                isConfirmingDiscard: confirming, isClaimed: claimed
            )
        }
        #expect(action(36) == .save && action(76) == .save && action(36, .shift) == .save)
        #expect(action(53) == .close)
        #expect(action(53, confirming: true) == .keep && action(36, confirming: true) == .ignore)
        #expect(action(36, trimming: true) == .pass && action(53, trimming: true) == .pass)
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
            screen: { nil }
        )
        var outcomes: [ScreencastReviewOutcome] = []
        panel.onFinish = { outcomes.append($0) }
        let first = try fixture.video()
        await panel.show(first, context: .none)
        #expect(panel.isShown && !panel.panel.isVisible && !panel.panel.canBecomeKey)
        #expect(panel.panel.identifier?.rawValue == "screencast.review.panel")

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

/// Real end-to-end trimming: a recording written from made-up frames and sound, its mixdown, and
/// the passthrough cut that Save applies.
@Suite("Screencast: trimming real files", .serialized)
@MainActor
struct ScreencastReviewTrimFileTests {
    let fixture = ReviewFixture()

    /// A three-second recording from the recorder's own writer (a keyframe a second, frame N a gray
    /// of N), with the microphone and the Mac's sound, its mixdown, and its meta.json.
    private func recording() async throws -> ScreencastCapture {
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("video-1.mov")
        let mixdown = folder.appendingPathComponent("video-1-mixdown.mp4")
        let writer = try ScreencastMovieWriter(
            url: file, pixelWidth: 320, pixelHeight: 180, audio: [.microphone, .systemAudio],
            options: ScreencastOptions(), fragmentInterval: ScreencastMovieWriter.fragmentInterval, onFailure: {}
        )
        ReviewFixture.feed(writer, seconds: 3)
        let result = await writer.finish(at: 103)
        try #require(result.hasFootage)
        try await ScreencastAudioMixdown.write(from: file, to: mixdown)
        let capture = ScreencastCapture(
            folder: folder,
            videos: [ScreencastVideo(file: file, mixdown: mixdown, pixelWidth: 320, pixelHeight: 180, audioTracks: [.microphone, .systemAudio], duration: result.duration)],
            duration: result.duration,
            endedEarly: nil
        )
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: ReviewFixture.reviewDate).write(to: capture.metadataURL)
        return capture
    }

    /// Every sample's presentation time in a track, in decode order, and where its edit list starts
    /// in the media.
    private func samples(of track: AVAssetTrack) async throws -> (times: [Double], editStart: Double) {
        let editStart = try await track.load(.segments).first?.timeMapping.source.start.seconds ?? 0
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return ([], editStart) }
        var times = [cursor.presentationTimeStamp.seconds]
        while cursor.stepInDecodeOrder(byCount: 1) == 1 { times.append(cursor.presentationTimeStamp.seconds) }
        return (times, editStart)
    }

    /// The gray of the frame shown at `seconds`, as a player decodes it.
    private func gray(of url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[1])
    }

    @available(macOS 15, *)
    @Test("A trim that cuts the start leaves nothing from before it: no sample earlier, no hidden edit, in the file and its mixdown")
    func startCutKeepsNothingBeforeTheTrim() async throws {
        defer { fixture.tearDown() }
        let capture = try await recording()
        let file = capture.videos[0].file
        let mixdown = try #require(capture.videos[0].mixdown)
        // What a player showed at the trim point and at the keyframe before it, in the original.
        let atTrim = try await gray(of: file, at: 1.5)
        let atKeyframe = try await gray(of: file, at: 1.0)
        #expect(abs(atTrim - atKeyframe) > 8, "the frames differ enough to tell apart")

        let model = fixture.model(.video(capture), trimmer: ScreencastFileTrimmer())
        model.setTrim(ScreencastTrimRange(start: 1.5, end: 2.5, within: capture.duration))
        await model.save()
        #expect(model.isFinished && model.failure == nil)

        for url in [file, mixdown] {
            let asset = AVURLAsset(url: url)
            #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1, "\(url.lastPathComponent)")
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let (times, editStart) = try await samples(of: video)
            #expect(abs(editStart) < 0.001, "\(url.lastPathComponent): no edit list hides media before the trim")
            #expect((times.min() ?? -1) >= -0.001, "\(url.lastPathComponent): no frame before the trim point")
            #expect((29...32).contains(times.count), "\(url.lastPathComponent): about a second of frames, not the second before")
            #expect(abs(try await gray(of: url, at: 0) - atTrim) <= 4, "\(url.lastPathComponent) starts on the trim point's frame")
        }
        let audio = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        #expect(audio.count == 2, "a track per sound")
        for track in audio {
            let (times, _) = try await samples(of: track)
            #expect((times.min() ?? -1) >= -0.001)
            #expect(abs(try await track.load(.timeRange).duration.seconds - 1) < 0.1)
        }
        #expect(try await AVURLAsset(url: mixdown).loadTracks(withMediaType: .audio).count == 1)
        #expect(try fixture.hiddenFiles(in: capture.folder).isEmpty)
        #expect(abs(try ScreencastMetadata.read(from: capture.metadataURL).duration - 1) < 0.01)
    }

    @Test("A start trim re-encodes at the recorder's rate, however still the screen was, so it keeps the recorder's bitrate")
    func startTrimKeepsTheRecordersRate() {
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: CMTime(value: 1, timescale: 30)) == 30)
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: CMTime(value: 1, timescale: 5)) == 30, "a still screen's sparse frames")
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: CMTime(value: 1, timescale: 60)) == 60)
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: CMTime(value: 1, timescale: 10_000)) == 120)
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: .invalid) == 30)
        func bitRate(_ settings: [String: Any]) -> Int? {
            (settings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int
        }
        let recorder = ScreencastMovieWriter.videoSettings(pixelWidth: 3024, pixelHeight: 1964, framesPerSecond: ScreencastOptions().framesPerSecond)
        let cut = ScreencastMovieWriter.videoSettings(
            pixelWidth: 3024, pixelHeight: 1964,
            framesPerSecond: ScreencastTrimEncoder.framesPerSecond(shortestFrame: CMTime(value: 1, timescale: 30))
        )
        #expect(bitRate(cut) == bitRate(recorder))
    }

    @available(macOS 15, *)
    @Test("A start trim of a still screen: the file's fastest frames set the rate, and the picture lasts to the cut's end")
    func startTrimOfAStillScreen() async throws {
        defer { fixture.tearDown() }
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("video-1.mov")
        let writer = try ScreencastMovieWriter(
            url: file, pixelWidth: 320, pixelHeight: 180, audio: [.microphone],
            options: ScreencastOptions(), fragmentInterval: ScreencastMovieWriter.fragmentInterval, onFailure: {}
        )
        ReviewFixture.feedStillScreen(writer, seconds: 3)
        let result = await writer.finish(at: 103)
        try #require(result.hasFootage)
        let source = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        #expect(try await source.load(.nominalFrameRate) < 20, "on average, a still screen has few frames")
        #expect(ScreencastTrimEncoder.framesPerSecond(shortestFrame: try await source.load(.minFrameDuration)) == 30)

        let capture = ScreencastCapture(
            folder: folder,
            videos: [ScreencastVideo(file: file, mixdown: nil, pixelWidth: 320, pixelHeight: 180, audioTracks: [.microphone], duration: result.duration)],
            duration: result.duration,
            endedEarly: nil
        )
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: ReviewFixture.reviewDate).write(to: capture.metadataURL)
        let model = fixture.model(.video(capture), trimmer: ScreencastFileTrimmer())
        model.setTrim(ScreencastTrimRange(start: 1.5, end: 2.5, within: result.duration))
        await model.save()
        #expect(model.isFinished && model.failure == nil)

        let cut = AVURLAsset(url: file)
        let video = try #require(try await cut.loadTracks(withMediaType: .video).first)
        let (times, editStart) = try await samples(of: video)
        #expect(abs(editStart) < 0.001 && (times.min() ?? -1) >= -0.001, "nothing from before the trim")
        #expect(times.count == 2, "the frame on screen at the trim point, and again at the end")
        #expect(try await video.load(.timeRange).end.seconds >= 0.99, "the picture lasts as long as the sound")
        let audio = try #require(try await cut.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await audio.load(.timeRange).duration.seconds - 1) < 0.05)
    }

    @available(macOS 15, *)
    @Test("A trim of the end alone stays passthrough: the same frames from the start, cut cleanly at the end")
    func endCutStaysPassthrough() async throws {
        defer { fixture.tearDown() }
        let capture = try await recording()
        let file = capture.videos[0].file
        let original = try await samples(of: try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first))

        let model = fixture.model(.video(capture), trimmer: ScreencastFileTrimmer())
        model.setTrim(ScreencastTrimRange(start: 0, end: 2, within: capture.duration))
        await model.save()
        #expect(model.isFinished && model.failure == nil)

        for url in [file, try #require(capture.videos[0].mixdown)] {
            let asset = AVURLAsset(url: url)
            #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1, "\(url.lastPathComponent)")
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let (times, editStart) = try await samples(of: video)
            #expect(abs(editStart) < 0.001 && (times.min() ?? -1) >= -0.001)
            #expect(Array(times.prefix(5)) == Array(original.times.prefix(5)), "\(url.lastPathComponent): copied as it was")
            #expect((times.max() ?? 99) < 2.0, "\(url.lastPathComponent): nothing after the end")
        }
        #expect(try await AVURLAsset(url: file).loadTracks(withMediaType: .audio).count == 2)
        #expect(abs(try ScreencastMetadata.read(from: capture.metadataURL).duration - 2) < 0.01)
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
        trimmer: any ScreencastTrimming = FakeTrimmer(),
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
            trimmer: trimmer,
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

    func originalContents(of input: ScreencastReviewInput) throws -> [String] {
        try input.mediaFiles.map { try String(contentsOf: $0, encoding: .utf8) }
    }

    func hiddenFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
    }

    /// Frames at 30 a second from host 100, the microphone in mono and the Mac's sound in stereo.
    nonisolated static func feed(_ writer: ScreencastMovieWriter, seconds: Double) {
        var nextAudio: [ScreencastAudioSource: Double] = [.microphone: 100, .systemAudio: 100]
        for frame in 0..<Int(seconds * 30) {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180, shade: UInt8(frame % 255)))
            for source in ScreencastAudioSource.allCases {
                while let next = nextAudio[source], next < host + 1.0 / 30 {
                    writer.appendAudio(ScreencastSamples.audio(at: next, channels: source == .systemAudio ? 2 : 1), from: source)
                    nextAudio[source] = next + ScreencastSamples.audioBufferSeconds
                }
            }
            usleep(2_000)
        }
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

    /// A still screen, as the recorder writes one: a second of frames, then nothing until the
    /// recording stops at `seconds`, with the microphone all along. The writer puts the last frame
    /// again at the end.
    nonisolated static func feedStillScreen(_ writer: ScreencastMovieWriter, seconds: Double) {
        var nextAudio = 100.0
        for frame in 0..<30 {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180, shade: UInt8(frame)))
            while nextAudio < host + 1.0 / 30 {
                writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 1, value: 0.4), from: .microphone)
                nextAudio += ScreencastSamples.audioBufferSeconds
            }
            usleep(2_000)
        }
        while nextAudio < 100 + seconds {
            writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 1, value: 0.4), from: .microphone)
            nextAudio += ScreencastSamples.audioBufferSeconds
        }
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// Writes "cut of <name>" for each cut, fails every cut from `failingFrom` (counting from 0) on,
/// and holds each cut until `release()` while `holds` is set.
final class FakeTrimmer: ScreencastTrimming, @unchecked Sendable {
    private let lock = NSLock()
    private var cuts = 0
    private var mixdownSources: [String] = []
    private let failingFrom: Int?
    private let holds: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(failingFrom: Int? = nil, holds: Bool = false) {
        self.failingFrom = failingFrom
        self.holds = holds
    }

    var cutCount: Int { lock.withLock { cuts } }
    /// The recording cut each mixdown cut was given.
    var cutRecordingsForMixdowns: [String] { lock.withLock { mixdownSources } }
    var isHolding: Bool { lock.withLock { !held.isEmpty } }

    func release() {
        let waiting = lock.withLock {
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func cut(_ recording: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        try await write(recording, to: destination)
    }

    func cutMixdown(_ mixdown: URL, cutRecording: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        lock.withLock { mixdownSources.append(cutRecording.lastPathComponent) }
        try await write(mixdown, to: destination)
    }

    private func write(_ source: URL, to destination: URL) async throws {
        if holds { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        let index = lock.withLock {
            defer { cuts += 1 }
            return cuts
        }
        if let failingFrom, index >= failingFrom { throw CocoaError(.fileWriteUnknown) }
        try Data("cut of \(source.lastPathComponent)".utf8).write(to: destination)
    }
}

@MainActor
final class FakeTrimPresenter: ScreencastTrimPresenting {
    private var completion: ((ClosedRange<TimeInterval>?) -> Void)?

    func beginTrimming(_ completion: @escaping (ClosedRange<TimeInterval>?) -> Void) -> Bool {
        self.completion = completion
        return true
    }

    func complete(_ kept: ClosedRange<TimeInterval>?) {
        completion?(kept)
        completion = nil
    }
}

/// A file manager that can't delete anything.
private final class UnremovingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// A file manager that refuses to move a cut onto the file named `refusing`.
private final class MoveRefusingFileManager: FileManager {
    private let refused: String

    init(refusing name: String) {
        refused = name
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == refused, srcURL.lastPathComponent.contains(".trimmed.") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
