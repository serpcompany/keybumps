import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// Screencast's recording engine, driven through fakes: no test here starts a capture, opens the
/// microphone, or asks for a permission. The engine needs macOS 15, so each test says so.
@MainActor
@Suite("Screencast: the recorder")
struct ScreencastRecorderTests {
    typealias Screens = ScreencastScreens

    let system = FakeCaptureSystem(content: Screens.content())
    let writers = FakeWriterFactory()
    let clock = FakeHostClock()
    let captures = TemporaryCapturesFolder()
    let startDate = Date(timeIntervalSince1970: 1_791_000_000)

    @available(macOS 15, *)
    func makeRecorder(microphoneGranted: Bool = true, retryDelays: [TimeInterval] = [0.005, 0.005, 0.005]) -> ScreencastRecorder {
        let clock = clock
        let startDate = startDate
        return ScreencastRecorder(
            system: system,
            writers: writers,
            hostClock: { clock.now },
            now: { startDate },
            ownProcessID: Screens.ownProcess,
            microphoneGranted: { microphoneGranted },
            tickInterval: nil,
            retryDelays: retryDelays
        )
    }

    @available(macOS 15, *)
    private func start(
        _ recorder: ScreencastRecorder,
        _ target: ScreencastTarget = .display(1),
        audio: ScreencastAudio = ScreencastAudio(microphone: true, systemAudio: true)
    ) async throws {
        try await recorder.start(target: target, audio: audio, capturesFolder: captures.url)
    }

    /// Lets the main actor run what was handed to it until `condition` holds, sleeping a little now
    /// and then so retries waiting out a backoff get their turn too.
    private func eventually(within seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var attempt = 0
        while Date() < deadline {
            if condition() { return true }
            attempt += 1
            if attempt % 10 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            } else {
                await Task.yield()
            }
        }
        return condition()
    }

    private func videoKind(_ stream: FakeStream?) -> (ScreencastFilterPlan, ScreencastStreamConfiguration)? {
        guard case .video(let plan, let configuration) = stream?.kind else { return nil }
        return (plan, configuration)
    }

    // MARK: Starting and stopping

    @available(macOS 15, *)
    @Test("Recording a display: one stream and one file for it, one sound stream, both sounds on")
    func display() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)

        #expect(recorder.state == .recording)
        #expect(recorder.target == .display(1))
        #expect(recorder.microphone == .on && recorder.systemAudio == .on)
        #expect(system.videoStreams.count == 1 && system.audioStreams.count == 1)
        let (plan, configuration) = try #require(videoKind(system.videoStreams.first))
        #expect(plan == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: []))
        #expect(configuration.pixelWidth == 3024 && configuration.pixelHeight == 1964)
        #expect(configuration.sourceRect == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(!configuration.scalesToFit)
        #expect(configuration.includesChildWindows, "left at ScreenCaptureKit's default")
        #expect(system.audioStreams.first?.kind == .audio(ScreencastAudio(microphone: true, systemAudio: true)))
        #expect(system.audioStreams.first?.isRunning == true && system.videoStreams.first?.isRunning == true)

        let writer = try #require(writers.writers.first)
        #expect(writers.writers.count == 1)
        #expect(writer.fileURL == captures.url.appendingPathComponent("1791000000").appendingPathComponent("video-1.mov"))
        #expect(writer.audioSources == [.microphone, .systemAudio])

        system.videoStreams[0].deliverFrame(at: 1_000.1)
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.1)
        system.audioStreams[0].deliverAudio(.systemAudio, at: 1_000.1)
        #expect(writer.calls == [.video(host: 1_000.1), .audio(.microphone, host: 1_000.1), .audio(.systemAudio, host: 1_000.1)])
    }

    @available(macOS 15, *)
    @Test("Stopping closes the files, writes a mixdown for two sounds and meta.json, and goes idle")
    func stop() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        clock.advance(5)
        let capture = try await recorder.stop()

        #expect(recorder.state == .idle)
        #expect(recorder.target == nil && recorder.microphone == .notRecorded)
        #expect(system.videoStreams[0].stopCount == 1 && system.audioStreams[0].stopCount == 1)
        #expect(writers.writers[0].calls.last == .finish(1_005))
        let folder = captures.url.appendingPathComponent("1791000000", isDirectory: true)
        #expect(capture.folder == folder)
        #expect(capture.duration == 5 && capture.endedEarly == nil)
        let video = try #require(capture.videos.first)
        #expect(video.file.lastPathComponent == "video-1.mov")
        #expect(video.mixdown?.lastPathComponent == "video-1-mixdown.mp4")
        #expect(video.forSharing == video.mixdown)
        #expect(writers.mixdowns.map(\.destination) == [video.mixdown])

        let metadata = try ScreencastMetadata.read(from: capture.metadataURL)
        #expect(metadata.target == "display" && metadata.displayCount == 1 && metadata.duration == 5)
        #expect(metadata.videos.first?.tracks == ["video", "microphone", "systemAudio"])
        #expect(metadata.startedAt == startDate && metadata.endedEarly == nil)
    }

    @available(macOS 15, *)
    @Test("With one sound or none, there's no mixdown: the file is the one to share")
    func noMixdown() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, audio: ScreencastAudio(microphone: true, systemAudio: false))
        let capture = try await recorder.stop()
        #expect(capture.videos.first?.mixdown == nil)
        #expect(capture.videos.first?.forSharing == capture.videos.first?.file)
        #expect(writers.mixdowns.isEmpty)

        try await start(recorder, audio: .none)
        #expect(system.audioStreams.count == 1, "no sound stream without sound")
        #expect(writers.writers.last?.audioSources == [])
        _ = try await recorder.stop()
    }

    @available(macOS 15, *)
    @Test("A mixdown that fails still leaves the full file")
    func mixdownFails() async throws {
        defer { captures.remove() }
        writers.mixdownFails = true
        let recorder = makeRecorder()
        try await start(recorder)
        let capture = try await recorder.stop()
        #expect(capture.videos.count == 1 && capture.videos.first?.mixdown == nil)
    }

    @available(macOS 15, *)
    @Test("Every display: a stream and a file each, left to right, and the sound in every file")
    func everyDisplay() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .everyDisplay)

        #expect(system.videoStreams.map { videoKind($0)?.0.displayID } == [1, 2])
        #expect(videoKind(system.videoStreams[1])?.1.pixelWidth == 1920)
        #expect(system.audioStreams.count == 1)
        #expect(writers.writers.map(\.fileURL.lastPathComponent) == ["video-1.mov", "video-2.mov"])

        system.videoStreams[1].deliverFrame(at: 1_000.2)
        system.audioStreams[0].deliverAudio(.systemAudio, at: 1_000.2)
        #expect(writers.writers[0].calls == [.audio(.systemAudio, host: 1_000.2)])
        #expect(writers.writers[1].calls == [.video(host: 1_000.2), .audio(.systemAudio, host: 1_000.2)])

        let capture = try await recorder.stop()
        #expect(capture.videos.count == 2)
        #expect(try ScreencastMetadata.read(from: capture.metadataURL).displayCount == 2)
    }

    @available(macOS 15, *)
    @Test("A window: its app without its other windows, cropped to it and scaled, the sound from its own stream")
    func window() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))

        let (plan, configuration) = try #require(videoKind(system.videoStreams.first))
        #expect(plan == .windows(1, includingWindows: [10, 11, 13]),
                "the window, its sheet and menu; no overlay is registered, so nothing of Keybumps")
        #expect(configuration.sourceRect == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(configuration.pixelWidth == 1600 && configuration.pixelHeight == 1200)
        #expect(configuration.scalesToFit)
        #expect(!configuration.includesChildWindows, "the list names every window, the sheet (11) and menu (13) included")
        #expect(system.audioStreams.first?.kind == .audio(ScreencastAudio(microphone: true, systemAudio: true)),
                "a window's stream would hear only its app, so the Mac's sound has its own")
    }

    @available(macOS 15, *)
    @Test("An area: part of one display, at its pixels")
    func area() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .area(display: 2, rect: CGRect(x: 100, y: 100, width: 400, height: 300)))
        let (plan, configuration) = try #require(videoKind(system.videoStreams.first))
        #expect(plan.displayID == 2)
        #expect(configuration.sourceRect == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(configuration.pixelWidth == 400 && configuration.pixelHeight == 300)
    }

    // MARK: Failing to start

    @available(macOS 15, *)
    @Test("Without Screen Recording it fails to start, creates nothing, and can start again later")
    func screenRecordingDenied() async throws {
        defer { captures.remove() }
        system.contentError = .screenRecordingDenied
        let recorder = makeRecorder()
        await #expect(throws: ScreencastFailure.screenRecordingDenied) { try await start(recorder) }
        #expect(recorder.state == .failed(.screenRecordingDenied))
        #expect(recorder.target == nil)
        #expect(captures.captureFolders().isEmpty)

        system.contentError = nil
        try await start(recorder)
        #expect(recorder.state == .recording)
    }

    @available(macOS 15, *)
    @Test("A window or display that's gone can't be recorded")
    func targetGone() async {
        defer { captures.remove() }
        let recorder = makeRecorder()
        await #expect(throws: ScreencastFailure.targetUnavailable) { try await start(recorder, .window(77)) }
        await #expect(throws: ScreencastFailure.targetUnavailable) { try await start(recorder, .display(9)) }
        #expect(captures.captureFolders().isEmpty)
    }

    @available(macOS 15, *)
    @Test("A stream that won't start removes the folder and its files")
    func streamWontStart() async {
        defer { captures.remove() }
        system.videoStartError = .captureFailed
        let recorder = makeRecorder()
        await #expect(throws: ScreencastFailure.captureFailed) { try await start(recorder) }
        #expect(recorder.state == .failed(.captureFailed))
        #expect(writers.writers.first?.calls == [.cancel])
        #expect(system.audioStreams.first?.stopCount == 1)
        #expect(captures.captureFolders().isEmpty)
    }

    @available(macOS 15, *)
    @Test("Without the sound stream it records the picture, and says both sounds failed")
    func soundStreamWontStart() async throws {
        defer { captures.remove() }
        system.audioStartError = .captureFailed
        let recorder = makeRecorder()
        try await start(recorder)
        #expect(recorder.state == .recording)
        #expect(recorder.microphone == .failed && recorder.systemAudio == .failed)
        #expect(system.audioStreams.count == 2, "tried with both sounds, then with the Mac's alone")
        #expect(writers.writers.first?.audioSources == [], "no track for a sound that never started")
        recorder.setAudio(.microphone, on: false)
        #expect(recorder.microphone == .failed)
    }

    @available(macOS 15, *)
    @Test("A microphone that can't start costs only the microphone: the Mac's sound still records")
    func microphoneWontStart() async throws {
        defer { captures.remove() }
        system.microphoneStartError = .captureFailed
        let recorder = makeRecorder()
        try await start(recorder)
        #expect(recorder.state == .recording)
        #expect(recorder.microphone == .failed && recorder.systemAudio == .on)
        #expect(system.audioStreams.map { $0.kind } == [
            .audio(ScreencastAudio(microphone: true, systemAudio: true)),
            .audio(ScreencastAudio(microphone: false, systemAudio: true))
        ])
        #expect(system.audioStreams.last?.isRunning == true)
        #expect(writers.writers.first?.audioSources == [.systemAudio], "no track for the microphone that didn't start")
    }

    @available(macOS 15, *)
    @Test("Without Microphone access it asks only for the Mac's sound, and says the microphone failed")
    func noMicrophoneAccess() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder(microphoneGranted: false)
        try await start(recorder)
        #expect(recorder.state == .recording)
        #expect(recorder.microphone == .failed && recorder.systemAudio == .on)
        #expect(system.audioStreams.map { $0.kind } == [.audio(ScreencastAudio(microphone: false, systemAudio: true))])
        #expect(writers.writers.first?.audioSources == [.systemAudio])
        let capture = try await recorder.stop()
        #expect(capture.videos.first?.mixdown == nil, "one sound needs no mixdown")

        try await start(recorder, audio: ScreencastAudio(microphone: true, systemAudio: false))
        #expect(system.audioStreams.count == 1, "nothing to ask for")
        #expect(recorder.microphone == .failed && recorder.systemAudio == .notRecorded)
    }

    @available(macOS 15, *)
    @Test("By default captures go to Keybumps's captures folder, in this run's own folder under the unit-test host")
    func defaultCapturesFolder() async throws {
        let recorder = makeRecorder()
        try await recorder.start(target: .display(1), audio: .none)
        let captures = ProductPaths.keybumps().captures.standardizedFileURL.path
        let file = try #require(writers.writers.first?.fileURL.standardizedFileURL.path)
        #expect(captures.hasSuffix("/Documents/Keybumps/captures"))
        #expect(captures.hasPrefix(UnitTestHost.dataDirectory.standardizedFileURL.path))
        #expect(file.hasPrefix(captures + "/"))
        await recorder.discard()
    }

    @Test("The microphone prompt names Dictation and Screencast, and says a screencast stays on this Mac")
    func microphoneUsageDescription() throws {
        let text = try #require(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        #expect(text.contains("dictate") && text.contains("screencast"))
        #expect(text.contains("stays on this Mac unless you choose to send it"))
    }

    @available(macOS 15, *)
    @Test("Calls in the wrong state are refused or do nothing")
    func wrongState() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        await #expect(throws: ScreencastRecorderError.notRecording) { _ = try await recorder.stop() }
        await #expect(throws: ScreencastRecorderError.notRecording) { try await recorder.restart() }
        recorder.pause()
        recorder.resume()
        #expect(recorder.state == .idle)
        try await start(recorder)
        await #expect(throws: ScreencastRecorderError.alreadyRecording) { try await start(recorder) }
        recorder.resume()
        #expect(recorder.state == .recording)
    }

    @available(macOS 15, *)
    @Test("In the unit-test host the default capture system captures nothing")
    func inertByDefault() async {
        defer { captures.remove() }
        #expect(ScreenCaptureKitCaptureSystem.current is InertScreencastCaptureSystem)
        let recorder = ScreencastRecorder(writers: writers, tickInterval: nil)
        await #expect(throws: ScreencastFailure.captureFailed) {
            try await recorder.start(target: .everyDisplay, audio: ScreencastAudio(microphone: true, systemAudio: true), capturesFolder: captures.url)
        }
        #expect(writers.writers.isEmpty)
    }

    // MARK: Pausing and sound

    @available(macOS 15, *)
    @Test("Pausing tells every file when, and the elapsed time leaves the pause out")
    func pauseAndResume() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .everyDisplay)
        clock.advance(5)
        recorder.pause()
        #expect(recorder.state == .paused && recorder.elapsed == 5)
        clock.advance(10)
        recorder.refreshElapsed()
        #expect(recorder.elapsed == 5)
        recorder.resume()
        clock.advance(3)
        recorder.refreshElapsed()
        #expect(recorder.state == .recording && recorder.elapsed == 8)
        for writer in writers.writers {
            #expect(writer.calls == [.pause(1_005), .resume(1_015)])
        }
    }

    @available(macOS 15, *)
    @Test("Switching a sound off and on reaches every file with the moment it changed")
    func audioSwitches() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        clock.advance(2)
        recorder.setAudio(.microphone, on: false)
        #expect(recorder.microphone == .off && recorder.systemAudio == .on)
        clock.advance(1)
        recorder.setAudio(.microphone, on: true)
        recorder.setAudio(.systemAudio, on: false)
        #expect(recorder.microphone == .on && recorder.systemAudio == .off)
        #expect(writers.writers[0].calls == [
            .setAudio(.microphone, on: false, host: 1_002),
            .setAudio(.microphone, on: true, host: 1_003),
            .setAudio(.systemAudio, on: false, host: 1_003)
        ])
    }

    @available(macOS 15, *)
    @Test("A sound the recording started without can't be switched on")
    func notRecordedSound() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, audio: ScreencastAudio(microphone: false, systemAudio: true))
        #expect(recorder.microphone == .notRecorded)
        recorder.setAudio(.microphone, on: true)
        #expect(recorder.microphone == .notRecorded)
        #expect(writers.writers[0].calls.isEmpty)
        #expect(system.audioStreams.first?.kind == .audio(ScreencastAudio(microphone: false, systemAudio: true)))
    }

    @available(macOS 15, *)
    @Test("The microphone meter follows the microphone, and reads 0 while it's off or paused")
    func microphoneLevel() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.1, value: 0.5)
        #expect(await eventually { recorder.microphoneLevel > 0.9 })
        recorder.setAudio(.microphone, on: false)
        #expect(recorder.microphoneLevel == 0)
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.3, value: 0.5)
        recorder.setAudio(.microphone, on: true)
        recorder.pause()
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.5, value: 0.5)
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.microphoneLevel == 0)
    }

    // MARK: Restarting and discarding

    @available(macOS 15, *)
    @Test("Restarting deletes the take and starts new files at once, without restarting the streams")
    func restart() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.videoStreams[0].deliverFrame(at: 1_000.5)
        recorder.setAudio(.microphone, on: false)
        clock.advance(4)
        try await recorder.restart()

        #expect(recorder.state == .recording && recorder.elapsed == 0)
        #expect(writers.writers.count == 2)
        #expect(writers.writers[0].calls.last == .cancel)
        let fresh = writers.writers[1]
        #expect(fresh.calls == [.setAudio(.microphone, on: false, host: 1_004), .video(host: 1_004)],
                "the sound stays switched off, and the last frame starts the new file now")
        #expect(system.videoStreams.count == 1 && system.videoStreams[0].startCount == 1)
        #expect(captures.captureFolders().count == 1)

        clock.advance(2)
        let capture = try await recorder.stop()
        #expect(capture.videos.count == 1)
        #expect(fresh.calls.last == .finish(1_006))
    }

    @available(macOS 15, *)
    @Test("Restarts are queued: a second one while the first deletes its take starts afresh, and nothing is left behind")
    func restartTwice() async throws {
        defer { captures.remove() }
        writers.configure = { [writers] writer in writer.holdsCancel = writers.writers.isEmpty }
        let recorder = makeRecorder()
        try await start(recorder)
        let first = Task { try await recorder.restart() }
        #expect(await eventually { writers.writers[0].isHoldingCancel })
        #expect(writers.writers.count == 2, "the first restart's new files are already recording")
        try await recorder.restart()
        #expect(writers.writers.count == 3)
        #expect(writers.writers[1].calls.last == .cancel && !writers.writers[1].fileExists)
        writers.writers[0].releaseCancel()
        try await first.value

        #expect(writers.writers[0].calls.last == .cancel && !writers.writers[0].fileExists)
        #expect(captures.captureFolders().count == 1, "only the newest take's folder")
        #expect(recorder.state == .recording)
        let capture = try await recorder.stop()
        #expect(capture.videos.map { $0.file } == [writers.writers[2].fileURL])
    }

    @available(macOS 15, *)
    @Test("Stopping while a restart deletes the old take stops the new one, and keeps it")
    func stopDuringRestart() async throws {
        defer { captures.remove() }
        writers.configure = { [writers] writer in writer.holdsCancel = writers.writers.isEmpty }
        let recorder = makeRecorder()
        try await start(recorder)
        let restarting = Task { try await recorder.restart() }
        #expect(await eventually { writers.writers[0].isHoldingCancel })
        let capture = try await recorder.stop()
        #expect(capture.videos.map { $0.file } == [writers.writers[1].fileURL])
        writers.writers[0].releaseCancel()
        try await restarting.value

        #expect(recorder.state == .idle, "the restart's end changes nothing")
        #expect(captures.captureFolders().map { $0.lastPathComponent } == [capture.folder.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: capture.metadataURL.path))
        #expect(writers.writers.count == 2)
    }

    @available(macOS 15, *)
    @Test("Discarding stops the streams and deletes the folder")
    func discard() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        await recorder.discard()
        #expect(recorder.state == .idle && recorder.target == nil)
        #expect(writers.writers[0].calls == [.cancel])
        #expect(system.videoStreams[0].stopCount == 1 && system.audioStreams[0].stopCount == 1)
        #expect(captures.captureFolders().isEmpty)
        await #expect(throws: ScreencastRecorderError.notRecording) { _ = try await recorder.stop() }
    }

    @available(macOS 15, *)
    @Test("Discarding while it's starting cancels the start and leaves nothing behind")
    func discardWhileStarting() async throws {
        defer { captures.remove() }
        system.holdsVideoStart = true
        let recorder = makeRecorder()
        let starting = Task { try await start(recorder) }
        #expect(await eventually { system.videoStreams.first?.isHoldingStart == true })
        #expect(recorder.state == .starting)
        var discarded = false
        let discarding = Task {
            await recorder.discard()
            discarded = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!discarded, "it waits for the start to stop its streams")
        #expect(recorder.state == .stopping)
        system.videoStreams[0].releaseStart()
        await discarding.value
        #expect(discarded && recorder.state == .idle)
        #expect(system.videoStreams[0].stopCount == 1 && system.audioStreams[0].stopCount == 1, "stopped before discard returned")
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(recorder.state == .idle)
        #expect(captures.captureFolders().isEmpty)
    }

    // MARK: Ending early

    @available(macOS 15, *)
    @Test("macOS stopping the stream keeps what was recorded and says why")
    func streamStopsOnItsOwn() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        var ended: (ScreencastCapture?, ScreencastFailure)?
        recorder.onEndedEarly = { ended = ($0, $1) }
        try await start(recorder)
        clock.advance(3)
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)

        #expect(await eventually { ended != nil })
        #expect(recorder.state == .failed(.stoppedByMacOS))
        #expect(ended?.1 == .stoppedByMacOS)
        let capture = try #require(ended?.0)
        #expect(capture.endedEarly == .stoppedByMacOS && capture.videos.count == 1)
        #expect(try ScreencastMetadata.read(from: capture.metadataURL).endedEarly == "stoppedByMacOS")
        #expect(system.audioStreams[0].stopCount == 1)
    }

    @available(macOS 15, *)
    @Test("Stop Sharing on every display at once ends the recording once, and keeps it")
    func everyStreamStopsAtOnce() async throws {
        defer { captures.remove() }
        system.screen = ScreencastContent(
            displays: Screens.content().displays + [ScreencastContent.Display(id: 3, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), scale: 2)],
            windows: Screens.content().windows,
            applicationProcessIDs: Screens.content().applicationProcessIDs
        )
        let recorder = makeRecorder()
        var ends: [(ScreencastCapture?, ScreencastFailure)] = []
        recorder.onEndedEarly = { ends.append(($0, $1)) }
        try await start(recorder, .everyDisplay)
        #expect(system.videoStreams.count == 3)
        for stream in system.videoStreams { stream.handler.stopped(.stoppedByMacOS) }

        #expect(await eventually { !ends.isEmpty })
        for _ in 0..<50 { await Task.yield() }
        #expect(ends.count == 1, "onEndedEarly fires once")
        let capture = try #require(ends.first?.0)
        #expect(capture.videos.count == 3 && capture.endedEarly == .stoppedByMacOS)
        #expect(capture.displaysEndedEarly.count == 2, "the first two to stop ended as displays, the last ended the recording")
        #expect(FileManager.default.fileExists(atPath: capture.folder.path), "the footage is kept")
        #expect(writers.writers.allSatisfy { $0.fileExists })
        #expect(try ScreencastMetadata.read(from: capture.metadataURL).displayCount == 3)
        #expect(writers.writers.allSatisfy { $0.calls.filter { if case .finish = $0 { true } else { false } }.count == 1 })
        #expect(recorder.state == .failed(.stoppedByMacOS))
    }

    @available(macOS 15, *)
    @Test("A full disk failing every file and a stream at once ends it once, and keeps it")
    func everyFileFailsAtOnce() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        var ends: [ScreencastFailure] = []
        recorder.onEndedEarly = { _, failure in ends.append(failure) }
        try await start(recorder, .everyDisplay)
        writers.writers.forEach { $0.onFailure() }
        system.videoStreams[1].handler.stopped(.captureFailed)

        #expect(await eventually { !ends.isEmpty })
        for _ in 0..<50 { await Task.yield() }
        #expect(ends == [.writerFailed])
        #expect(captures.captureFolders().count == 1)
        #expect(writers.writers.allSatisfy { $0.fileExists })
        #expect(recorder.state == .failed(.writerFailed))
    }

    @available(macOS 15, *)
    @Test("A failure reported after stop() began is ignored: the stop keeps the recording and goes idle")
    func failureAfterStop() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        var ended = false
        recorder.onEndedEarly = { _, _ in ended = true }
        try await start(recorder)
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        writers.writers[0].onFailure()
        let capture = try await recorder.stop()
        for _ in 0..<50 { await Task.yield() }
        #expect(!ended && recorder.state == .idle)
        #expect(capture.endedEarly == nil && FileManager.default.fileExists(atPath: capture.metadataURL.path))
    }

    @available(macOS 15, *)
    @Test("A failure reported after discard() began is ignored: nothing is reported and it stays idle")
    func failureAfterDiscard() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        var ended = false
        recorder.onEndedEarly = { _, _ in ended = true }
        try await start(recorder)
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        await recorder.discard()
        for _ in 0..<50 { await Task.yield() }
        #expect(!ended && recorder.state == .idle)
        #expect(writers.writers[0].calls == [.cancel])
    }

    @available(macOS 15, *)
    @Test("A file of a take a restart threw away can't end the new one")
    func failureFromAnOldTake() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        var ended = false
        recorder.onEndedEarly = { _, _ in ended = true }
        try await start(recorder)
        try await recorder.restart()
        writers.writers[0].onFailure()
        for _ in 0..<50 { await Task.yield() }
        #expect(!ended && recorder.state == .recording)
    }

    // MARK: Streams that stop during the start

    @available(macOS 15, *)
    @Test("The sound stream stopping while the picture starts costs the microphone: the Mac's sound gets its own stream once it's live")
    func soundStreamStopsDuringStart() async throws {
        defer { captures.remove() }
        system.holdsVideoStart = true
        let recorder = makeRecorder()
        let starting = Task { try await start(recorder) }
        #expect(await eventually { system.videoStreams.first?.isHoldingStart == true })
        system.audioStreams[0].handler.stopped(.captureFailed)
        for _ in 0..<20 { await Task.yield() }
        system.videoStreams[0].releaseStart()
        try await starting.value

        #expect(recorder.state == .recording)
        #expect(await eventually { system.audioStreams.count == 2 && system.audioStreams[1].isRunning })
        #expect(system.audioStreams[1].kind == .audio(ScreencastAudio(microphone: false, systemAudio: true)))
        #expect(recorder.microphone == .failed && recorder.systemAudio == .on)
    }

    @available(macOS 15, *)
    @Test("A single target whose stream stops while starting fails to start, and leaves nothing")
    func singleTargetStopsDuringStart() async throws {
        defer { captures.remove() }
        system.holdsVideoStart = true
        let recorder = makeRecorder()
        let starting = Task { try await start(recorder) }
        #expect(await eventually { system.videoStreams.first?.isHoldingStart == true })
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        for _ in 0..<20 { await Task.yield() }
        system.videoStreams[0].releaseStart()
        await #expect(throws: ScreencastFailure.stoppedByMacOS) { try await starting.value }
        #expect(recorder.state == .failed(.stoppedByMacOS))
        #expect(captures.captureFolders().isEmpty)
        #expect(system.videoStreams[0].stopCount == 1 && system.audioStreams[0].stopCount == 1)
    }

    @available(macOS 15, *)
    @Test("Every display stopping while the recording starts fails the start, and leaves nothing")
    func everyDisplayStopsDuringStart() async throws {
        defer { captures.remove() }
        system.holdsVideoStart = true
        let recorder = makeRecorder()
        let starting = Task { try await start(recorder, .everyDisplay) }
        #expect(await eventually { system.videoStreams.first?.isHoldingStart == true })
        system.videoStreams[0].releaseStart()
        #expect(await eventually { system.videoStreams.count == 2 && system.videoStreams[1].isHoldingStart })
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        system.videoStreams[1].handler.stopped(.stoppedByMacOS)
        for _ in 0..<20 { await Task.yield() }
        system.videoStreams[1].releaseStart()
        await #expect(throws: ScreencastFailure.stoppedByMacOS) { try await starting.value }
        #expect(captures.captureFolders().isEmpty)
    }

    @available(macOS 15, *)
    @Test("A display stopping while the others start: the rest record on, and meta.json names it")
    func displayStopsDuringStart() async throws {
        defer { captures.remove() }
        system.holdsVideoStart = true
        let recorder = makeRecorder()
        var ended = false
        recorder.onEndedEarly = { _, _ in ended = true }
        let starting = Task { try await start(recorder, .everyDisplay) }
        #expect(await eventually { system.videoStreams.first?.isHoldingStart == true })
        system.videoStreams[0].releaseStart()
        #expect(await eventually { system.videoStreams.count == 2 && system.videoStreams[1].isHoldingStart })
        system.videoStreams[0].handler.stopped(.targetUnavailable)
        for _ in 0..<20 { await Task.yield() }
        system.videoStreams[1].releaseStart()
        try await starting.value

        #expect(recorder.state == .recording && !ended)
        #expect(await eventually { writers.writers[0].calls.contains { if case .finish = $0 { true } else { false } } })
        #expect(await eventually { system.videoStreams[0].stopCount == 1 })
        #expect(system.videoStreams[1].isRunning)
        system.videoStreams[1].deliverFrame(at: 1_000.2)
        system.audioStreams[0].deliverAudio(.systemAudio, at: 1_000.2)
        #expect(writers.writers[1].calls.suffix(2) == [.video(host: 1_000.2), .audio(.systemAudio, host: 1_000.2)])
        #expect(!writers.writers[0].calls.contains(.audio(.systemAudio, host: 1_000.2)), "its file no longer takes sound")

        let capture = try await recorder.stop()
        #expect(capture.endedEarly == nil && capture.videos.count == 2)
        #expect(capture.displaysEndedEarly == [ScreencastDisplayEnd(index: 0, reason: .targetUnavailable, file: writers.writers[0].fileURL)])
        let metadata = try ScreencastMetadata.read(from: capture.metadataURL)
        #expect(metadata.displaysEndedEarly == [.init(display: 1, reason: "targetUnavailable", file: "video-1.mov")])
        #expect(metadata.displayCount == 2 && metadata.endedEarly == nil)
        #expect(writers.writers.allSatisfy { $0.calls.filter { if case .finish = $0 { true } else { false } }.count == 1 })
    }

    @available(macOS 15, *)
    @Test("A display that stops mid-recording ends its own file; a restart gives it none, and it's still named")
    func displayStopsMidRecording() async throws {
        defer { captures.remove() }
        writers.configure = { [writers] writer in
            // The second display's file recorded nothing before it stopped.
            if writers.writers.count == 1 { writer.finishDuration = 0 }
        }
        let recorder = makeRecorder()
        try await start(recorder, .everyDisplay)
        system.videoStreams[1].handler.stopped(.stoppedByMacOS)
        #expect(await eventually { writers.writers[1].calls.contains { if case .finish = $0 { true } else { false } } })
        #expect(recorder.state == .recording)

        try await recorder.restart()
        #expect(writers.writers.count == 3, "a new file for the display still recording, none for the one that stopped")
        #expect(writers.writers[2].fileURL.lastPathComponent == "video-1.mov")
        let capture = try await recorder.stop()
        #expect(capture.videos.map { $0.file } == [writers.writers[2].fileURL])
        #expect(capture.displaysEndedEarly == [ScreencastDisplayEnd(index: 1, reason: .stoppedByMacOS, file: nil)])
        let metadata = try ScreencastMetadata.read(from: capture.metadataURL)
        #expect(metadata.displayCount == 2, "the display that stopped still counts")
        #expect(metadata.displaysEndedEarly == [.init(display: 2, reason: "stoppedByMacOS", file: nil)])
    }

    // MARK: Keeping up, and trying again

    @available(macOS 15, *)
    @Test("The tick keeps every file's sound up with the clock while recording, not while paused")
    func tickKeepsTheSoundUp() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .everyDisplay)
        clock.advance(1)
        recorder.tick()
        #expect(writers.writers.allSatisfy { $0.keptUpAt == [1_001] })
        recorder.pause()
        clock.advance(1)
        recorder.tick()
        #expect(writers.writers.allSatisfy { $0.keptUpAt == [1_001] })
    }

    @available(macOS 15, *)
    @Test("An overlay added while the screen can't be read joins the video on a retry")
    func overlayRetry() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.contentFailures = 2
        await recorder.includeOverlayWindow(31)
        #expect(system.videoStreams[0].plans == [.display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31])],
                "it returns once a retry shows it")
        #expect(system.contentReads == 4)
    }

    @available(macOS 15, *)
    @Test("Retries stop after a few attempts, and the call returns")
    func overlayRetryGivesUp() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.contentFailures = 100
        await recorder.includeOverlayWindow(31)
        #expect(system.videoStreams[0].plans.isEmpty)
        #expect(system.contentReads == 1 + 4, "one attempt and three retries")
        system.contentFailures = 0
        await recorder.removeOverlayWindow(31)
        await recorder.includeOverlayWindow(31)
        #expect(system.videoStreams[0].plans == [.display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31])])
    }

    @available(macOS 15, *)
    @Test("A crop update that fails is tried again, unless the window has moved on")
    func cropRetry() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        let stream = system.videoStreams[0]
        stream.sourceRectFailures = 2
        system.windowFrames[10] = CGRect(x: 250, y: 150, width: 800, height: 600)
        recorder.followTick()
        #expect(await eventually { stream.sourceRects == [CGRect(x: 250, y: 150, width: 800, height: 600)] })

        stream.sourceRectFailures = 100
        system.windowFrames[10] = CGRect(x: 300, y: 150, width: 800, height: 600)
        recorder.followTick()
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(stream.sourceRects.count == 1 && stream.sourceRectFailures == 100 - 4, "one attempt and three retries, then it waits for the next move")
        stream.sourceRectFailures = 0
        system.windowFrames[10] = CGRect(x: 310, y: 150, width: 800, height: 600)
        recorder.followTick()
        #expect(await eventually { stream.sourceRects.last == CGRect(x: 310, y: 150, width: 800, height: 600) })
    }

    @available(macOS 15, *)
    @Test("A filter rebuild waiting out a retry returns when the recording stops, is discarded, or ends early", arguments: ["stop", "discard", "early"])
    func rebuildWaiterReturnsWhenTheRecordingEnds(ending: String) async throws {
        defer { captures.remove() }
        let recorder = makeRecorder(retryDelays: [0.5, 0.5, 0.5])
        try await start(recorder)
        system.contentFailures = 100
        var returned = false
        let including = Task {
            await recorder.includeOverlayWindow(31)
            returned = true
        }
        #expect(await eventually { system.contentReads == 2 }, "the first attempt failed and waits to try again")
        switch ending {
        case "stop": _ = try await recorder.stop()
        case "discard": await recorder.discard()
        default: system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        }
        #expect(await eventually { returned }, "it returns at once, not after the backoff")
        await including.value
        #expect(system.contentReads == 2, "no retry once the recording is over")
    }

    @available(macOS 15, *)
    @Test("A crop retry never puts back a frame the window has since left")
    func cropRetryAfterTheWindowMoved() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder(retryDelays: [0.05, 0.05, 0.05])
        try await start(recorder, .window(10))
        let stream = system.videoStreams[0]
        stream.sourceRectFailures = 1
        system.windowFrames[10] = CGRect(x: 250, y: 150, width: 800, height: 600)
        recorder.followTick()
        #expect(await eventually { stream.sourceRectFailures == 0 }, "the first crop failed")
        system.windowFrames[10] = CGRect(x: 400, y: 200, width: 800, height: 600)
        recorder.followTick()
        #expect(await eventually { stream.sourceRects == [CGRect(x: 400, y: 200, width: 800, height: 600)] })
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            recorder.followTick()
        }
        #expect(stream.sourceRects == [CGRect(x: 400, y: 200, width: 800, height: 600)], "the old frame's retry was dropped")
    }

    @available(macOS 15, *)
    @Test("A microphone in a format no file can take fails cleanly: it's dropped, and the Mac's sound records on")
    func unusableMicrophone() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].handler.audio(ScreencastSamples.audio(at: 1_000.1, channelValues: [0.5, 0.5, 0.5, 0.5]), .microphone)
        #expect(await eventually { recorder.microphone == .failed })
        #expect(recorder.systemAudio == .on && recorder.state == .recording)
        system.audioStreams[0].deliverAudio(.systemAudio, at: 1_000.2)
        let calls = writers.writers[0].calls
        #expect(calls == [.audio(.systemAudio, host: 1_000.2)], "no microphone buffer reached the file")
    }

    @available(macOS 15, *)
    @Test("A microphone that failed stays out of the file, even when it comes back in a format that converts")
    func failedMicrophoneStaysOut() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].handler.audio(ScreencastSamples.audio(at: 1_000.1, channelValues: [0.5, 0.5, 0.5, 0.5]), .microphone)
        #expect(await eventually { recorder.microphone == .failed })
        // The person switches to another microphone, which ScreenCaptureKit follows.
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.2)
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.3)
        recorder.setAudio(.microphone, on: false)
        recorder.setAudio(.microphone, on: true)
        #expect(recorder.microphone == .failed && recorder.microphoneLevel == 0)
        #expect(!writers.writers[0].calls.contains { if case .audio(.microphone, _) = $0 { true } else { false } },
                "no microphone buffer reaches the file")
        #expect(!writers.writers[0].calls.contains { if case .setAudio = $0 { true } else { false } }, "switching it does nothing")
    }

    @available(macOS 15, *)
    @Test("A microphone lost with the sound stream stays out too, whatever its old stream still delivers")
    func lostMicrophoneStaysOut() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].handler.stopped(.captureFailed)
        #expect(await eventually { recorder.microphone == .failed && system.audioStreams.count == 2 })
        system.audioStreams[0].deliverAudio(.microphone, at: 1_000.2)
        system.audioStreams[1].deliverAudio(.systemAudio, at: 1_000.2)
        #expect(writers.writers[0].calls == [.audio(.systemAudio, host: 1_000.2)])
    }

    @available(macOS 15, *)
    @Test("One change to the app's windows costs one screen read, however many ticks see it while it's read")
    func oneReadPerChange() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        recorder.followTick()
        #expect(await eventually { system.contentReads == 2 })
        system.holdsContent = true
        let menu = ScreencastContent.Window(id: 14, frame: CGRect(x: 400, y: 300, width: 200, height: 150), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        system.screen = Screens.content(windows: Screens.content().windows + [menu])
        recorder.followTick()
        #expect(await eventually { system.heldContentCount == 1 })
        for _ in 0..<5 {
            recorder.followTick()
            await Task.yield()
        }
        #expect(system.contentReads == 3, "the ticks that saw the same windows asked for nothing")
        system.holdsContent = false
        system.releaseContent()
        #expect(await eventually { system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13, 14]) })
        for _ in 0..<5 {
            recorder.followTick()
            await Task.yield()
        }
        #expect(system.contentReads == 3)
        #expect(system.readKinds == [false, true, true], "a window recording's rebuilds read only what's on screen")
    }

    @available(macOS 15, *)
    @Test("A burst of window changes costs one read in flight and one waiting, which sees the latest windows")
    func burstsAreCoalesced() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        recorder.followTick()
        #expect(await eventually { system.contentReads == 2 })
        system.holdsContent = true
        func popup(_ id: CGWindowID) -> ScreencastContent.Window {
            ScreencastContent.Window(id: id, frame: CGRect(x: 400, y: 300, width: 200, height: 150), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        }
        // A menu opens, a submenu joins it, then the menu closes and leaves the submenu.
        for windows in [[popup(14)], [popup(14), popup(15)], [popup(15)]] {
            system.screen = Screens.content(windows: Screens.content().windows + windows)
            recorder.followTick()
            #expect(await eventually { system.heldContentCount == 1 })
        }
        #expect(system.contentReads == 3)
        system.holdsContent = false
        system.releaseContent()
        #expect(await eventually { system.contentReads == 4 && system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13, 15]) })
        for _ in 0..<10 { await Task.yield() }
        #expect(system.contentReads == 4, "one read in flight, then one waiting")
    }

    @available(macOS 15, *)
    @Test("A failed read waits out its backoff, however often the ticks see a change")
    func ticksRespectTheBackoff() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder(retryDelays: [0.2, 0.2, 0.2])
        try await start(recorder, .window(10))
        system.contentFailures = 2
        func popup(_ id: CGWindowID) -> ScreencastContent.Window {
            ScreencastContent.Window(id: id, frame: CGRect(x: 400, y: 300, width: 200, height: 150), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        }
        system.screen = Screens.content(windows: Screens.content().windows + [popup(14)])
        recorder.followTick()
        #expect(await eventually { system.contentReads == 2 }, "the first read failed")
        for id in 15..<25 {
            system.screen = Screens.content(windows: Screens.content().windows + [popup(CGWindowID(id))])
            recorder.followTick()
            recorder.tick()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(system.contentReads == 2, "no read during the backoff")
        #expect(await eventually { system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13, 24]) })
        #expect(system.contentReads == 4, "two retries, the second with the latest windows")
    }

    @available(macOS 15, *)
    @Test("includeOverlayWindow waits through the whole backoff, ticks or not, and returns with the overlay shown")
    func overlayWaitsThroughTheBackoff() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder(retryDelays: [0.05, 0.05, 0.05])
        try await start(recorder)
        system.contentFailures = 3
        system.ownWindows = [31]
        var returned = false
        let including = Task {
            await recorder.includeOverlayWindow(31)
            returned = true
        }
        let started = Date()
        while !returned, Date().timeIntervalSince(started) < 2 {
            recorder.tick()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await including.value
        #expect(Date().timeIntervalSince(started) >= 0.15, "three backoffs")
        #expect(system.videoStreams[0].plans.last == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31]))
        #expect(system.contentReads == 1 + 4, "the ticks added no reads")
        #expect(system.readKinds.allSatisfy { !$0 }, "a display recording reads every window, to find Keybumps")
    }

    @available(macOS 15, *)
    @Test("endingEarly says an early end owns the recording's end while its files close")
    func endingEarlyDuringAnEarlyEnd() async throws {
        defer { captures.remove() }
        writers.configure = { $0.holdsFinish = true }
        let recorder = makeRecorder()
        var stateWhenReported: ScreencastRecorderState?
        var endingWhenReported: ScreencastFailure?
        recorder.onEndedEarly = { _, _ in
            stateWhenReported = recorder.state
            endingWhenReported = recorder.endingEarly
        }
        try await start(recorder)
        #expect(recorder.endingEarly == nil)
        system.videoStreams[0].handler.stopped(.stoppedByMacOS)
        #expect(await eventually { recorder.state == .stopping })
        #expect(recorder.endingEarly == .stoppedByMacOS, "set in the same step as .stopping")
        #expect(await eventually { writers.writers[0].isHoldingFinish })
        #expect(recorder.endingEarly == .stoppedByMacOS)
        writers.writers[0].releaseFinish()
        #expect(await eventually { stateWhenReported != nil })
        #expect(stateWhenReported == .failed(.stoppedByMacOS) && endingWhenReported == nil)

        writers.configure = { _ in }
        try await start(recorder)
        #expect(recorder.endingEarly == nil)
    }

    @available(macOS 15, *)
    @Test("stop(), discard(), and restart() never set endingEarly", arguments: ["stop", "discard", "restart"])
    func notEndingEarly(action: String) async throws {
        defer { captures.remove() }
        writers.configure = { writer in
            writer.holdsFinish = true
            writer.holdsCancel = true
        }
        let recorder = makeRecorder()
        try await start(recorder)
        let acting = Task {
            switch action {
            case "stop": _ = try? await recorder.stop()
            case "discard": await recorder.discard()
            default: try? await recorder.restart()
            }
        }
        #expect(await eventually { writers.writers[0].isHoldingFinish || writers.writers[0].isHoldingCancel })
        #expect(recorder.state == (action == "restart" ? .recording : .stopping))
        #expect(recorder.endingEarly == nil)
        writers.writers.forEach {
            $0.releaseFinish()
            $0.releaseCancel()
        }
        await acting.value
        #expect(recorder.endingEarly == nil)
    }

    @available(macOS 15, *)
    @Test("A file that fails mid-recording ends it and keeps its footage")
    func writerFails() async throws {
        defer { captures.remove() }
        writers.configure = { $0.finishFailed = true }
        let recorder = makeRecorder()
        var ended: (ScreencastCapture?, ScreencastFailure)?
        recorder.onEndedEarly = { ended = ($0, $1) }
        try await start(recorder)
        writers.writers[0].onFailure()

        #expect(await eventually { ended != nil })
        #expect(ended?.1 == .writerFailed)
        #expect(ended?.0?.videos.count == 1, "the movie fragments still play")
        #expect(recorder.state == .failed(.writerFailed))
    }

    @available(macOS 15, *)
    @Test("Losing the shared sound stream costs the microphone; the Mac's sound gets a stream of its own")
    func soundStreamStops() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].handler.stopped(.captureFailed)
        #expect(await eventually { system.audioStreams.count == 2 && system.audioStreams[1].isRunning })
        #expect(system.audioStreams[1].kind == .audio(ScreencastAudio(microphone: false, systemAudio: true)))
        #expect(recorder.microphone == .failed && recorder.systemAudio == .on && recorder.state == .recording)

        system.audioStreams[0].handler.stopped(.captureFailed)
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.systemAudio == .on, "a report from the replaced stream is ignored")

        system.audioStreams[1].handler.stopped(.captureFailed)
        #expect(await eventually { recorder.systemAudio == .failed })
        #expect(system.audioStreams.count == 2, "the Mac's sound alone isn't tried again")
        #expect(recorder.state == .recording)
    }

    @available(macOS 15, *)
    @Test("Stopping before any picture was written keeps nothing")
    func noFootage() async throws {
        defer { captures.remove() }
        writers.configure = { $0.finishDuration = 0 }
        let recorder = makeRecorder()
        try await start(recorder)
        await #expect(throws: ScreencastFailure.noFootage) { _ = try await recorder.stop() }
        #expect(recorder.state == .failed(.noFootage))
        #expect(captures.captureFolders().isEmpty)
    }

    // MARK: Overlays and following

    @available(macOS 15, *)
    @Test("An overlay added mid-recording joins the video; removed, it leaves")
    func overlays() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        await recorder.includeOverlayWindow(31)
        #expect(recorder.overlayWindows == [31])
        #expect(system.videoStreams[0].plans == [.display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31])])
        await recorder.includeOverlayWindow(31)
        #expect(system.videoStreams[0].plans.count == 1, "already in")
        await recorder.removeOverlayWindow(31)
        #expect(system.videoStreams[0].plans.last == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: []))
    }

    @available(macOS 15, *)
    @Test("An overlay added before recording is in from the start, on every display")
    func overlayBeforeStart() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        await recorder.includeOverlayWindow(31)
        try await start(recorder, .everyDisplay)
        #expect(system.videoStreams.map { videoKind($0)?.0 } == [
            .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31]),
            .display(2, excludingProcess: Screens.ownProcess, exceptingWindows: [31])
        ])
    }

    @available(macOS 15, *)
    @Test("A Keybumps window opening mid-window-recording is never in any filter; its overlays are, from the first")
    func ownWindowsNeverInAWindowRecording() async throws {
        defer { captures.remove() }
        system.ownWindows = [30, 31]
        let recorder = makeRecorder()
        await recorder.includeOverlayWindow(31)
        try await start(recorder, .window(10))
        #expect(videoKind(system.videoStreams.first)?.0 == .windows(1, includingWindows: [10, 11, 13, 31]))

        // A notch notice and the Command Palette open, then the app opens a popover.
        let notice = ScreencastContent.Window(id: 40, frame: CGRect(x: 500, y: 0, width: 300, height: 40), layer: 25, processID: Screens.ownProcess, isUntitled: true, isOnScreen: true)
        let palette = ScreencastContent.Window(id: 41, frame: CGRect(x: 300, y: 200, width: 700, height: 450), layer: 8, processID: Screens.ownProcess, isUntitled: true, isOnScreen: true)
        let popover = ScreencastContent.Window(id: 14, frame: CGRect(x: 400, y: 300, width: 200, height: 150), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        system.screen = Screens.content(windows: Screens.content().windows + [notice, palette])
        system.ownWindows = [30, 31, 40, 41]
        recorder.tick()
        recorder.followTick()
        system.screen = Screens.content(windows: Screens.content().windows + [notice, palette, popover])
        recorder.followTick()
        #expect(await eventually { system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13, 14, 31]) })
        let every = [videoKind(system.videoStreams[0])?.0].compactMap { $0 } + system.videoStreams[0].plans
        for plan in every {
            guard case .windows(_, let windows) = plan else { Issue.record("not a window list"); continue }
            #expect(Set(windows).isDisjoint(with: [30, 40, 41]), "Keybumps's other windows are never named")
        }
    }

    @available(macOS 15, *)
    @Test("The recorded app's new window joins at the next follow tick, and leaves when it closes")
    func appWindowJoins() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        recorder.followTick()
        for _ in 0..<20 { await Task.yield() }
        let menu = ScreencastContent.Window(id: 14, frame: CGRect(x: 400, y: 300, width: 200, height: 150), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        system.screen = Screens.content(windows: Screens.content().windows + [menu])
        recorder.followTick()
        #expect(await eventually { system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13, 14]) })
        system.screen = Screens.content()
        recorder.followTick()
        #expect(await eventually { system.videoStreams[0].plans.last == .windows(1, includingWindows: [10, 11, 13]) })
    }

    @available(macOS 15, *)
    @Test("Without an overlay, a window recording never rebuilds for Keybumps's windows: none can show")
    func ownWindowOpensWithoutOverlays() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        system.ownWindows = [30, 40]
        recorder.tick()
        for _ in 0..<20 { await Task.yield() }
        #expect(system.videoStreams[0].plans.isEmpty && system.contentReads == 1)
    }

    @available(macOS 15, *)
    @Test("An overlay registered before its window is on screen joins the video when it appears")
    func overlayAppearsLater() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        await recorder.includeOverlayWindow(50)
        try await start(recorder)
        #expect(videoKind(system.videoStreams.first)?.0 == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: []))
        let drawing = ScreencastContent.Window(id: 50, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 3, processID: Screens.ownProcess, isUntitled: true, isOnScreen: true)
        system.screen = Screens.content(windows: Screens.content().windows + [drawing])
        system.ownWindows = [50]
        recorder.tick()
        #expect(await eventually { system.videoStreams[0].plans.last == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [50]) })
    }

    @available(macOS 15, *)
    @Test("A display recording needs no rebuild when Keybumps opens a window: it's left out whole")
    func ownWindowOpensOnADisplay() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.ownWindows = [30, 40]
        recorder.tick()
        for _ in 0..<20 { await Task.yield() }
        #expect(system.videoStreams[0].plans.isEmpty)
        #expect(system.contentReads == 1)
    }

    @available(macOS 15, *)
    @Test("Following a dragged window keeps one update in flight, and jumps to its latest frame")
    func followingIsCoalesced() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        let stream = system.videoStreams[0]
        stream.holdsUpdates = true
        for step in 1...10 {
            system.windowFrames[10] = CGRect(x: 100 + Double(step) * 10, y: 100, width: 800, height: 600)
            recorder.followTick()
            await Task.yield()
        }
        #expect(await eventually { stream.heldUpdateCount == 1 })
        let including = Task { await recorder.includeOverlayWindow(31) }
        for _ in 0..<20 { await Task.yield() }
        #expect(stream.heldUpdateCount == 1, "the filter rebuild waits its turn")
        stream.holdsUpdates = false
        stream.releaseUpdates()
        await including.value
        #expect(await eventually { stream.sourceRects.last == CGRect(x: 200, y: 100, width: 800, height: 600) })
        #expect(stream.mostUpdatesInFlight == 1)
        #expect(stream.plans.count == 1)
        #expect(stream.sourceRects.count == 2, "the frames in between were skipped")
    }

    @available(macOS 15, *)
    @Test("A window recording follows its window as it moves, and onto another display")
    func followsTheWindow() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        system.windowFrames[10] = CGRect(x: 100, y: 100, width: 800, height: 600)
        recorder.followTick()
        for _ in 0..<20 { await Task.yield() }
        #expect(system.videoStreams[0].sourceRects.isEmpty, "it hasn't moved")

        system.windowFrames[10] = CGRect(x: 250, y: 150, width: 800, height: 600)
        recorder.followTick()
        #expect(await eventually { system.videoStreams[0].sourceRects == [CGRect(x: 250, y: 150, width: 800, height: 600)] })

        let moved = CGRect(x: 1700, y: 200, width: 800, height: 600)
        var windows = Screens.content().windows
        windows[0] = ScreencastContent.Window(id: 10, frame: moved, layer: 0, processID: Screens.browser, isUntitled: false, isOnScreen: true)
        system.screen = Screens.content(windows: windows)
        system.windowFrames[10] = moved
        recorder.followTick()
        #expect(await eventually { system.videoStreams[0].plans.last?.displayID == 2 })
        #expect(await eventually { system.videoStreams[0].sourceRects.last == CGRect(x: 188, y: 200, width: 800, height: 600) })
    }
}
