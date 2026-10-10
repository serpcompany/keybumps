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
    func makeRecorder() -> ScreencastRecorder {
        let clock = clock
        let startDate = startDate
        return ScreencastRecorder(
            system: system,
            writers: writers,
            hostClock: { clock.now },
            now: { startDate },
            ownProcessID: Screens.ownProcess,
            tickInterval: nil
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

    /// Lets the main actor run what was handed to it until `condition` holds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await Task.yield()
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
        #expect(plan == .applications(1, includedProcesses: [Screens.browser, Screens.ownProcess], exceptingWindows: [12, 30, 31]),
                "no overlay is registered, so every Keybumps window stays out")
        #expect(configuration.sourceRect == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(configuration.pixelWidth == 1600 && configuration.pixelHeight == 1200)
        #expect(configuration.scalesToFit)
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
        #expect(writers.writers.first?.audioSources == [.microphone, .systemAudio], "the microphone's track stays, silent")
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
        await recorder.discard()
        #expect(recorder.state == .idle)
        system.videoStreams[0].releaseStart()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(recorder.state == .idle)
        #expect(system.videoStreams[0].stopCount == 1)
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
    @Test("Losing the sound stream keeps the recording going, with both sounds failed")
    func soundStreamStops() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder)
        system.audioStreams[0].handler.stopped(.captureFailed)
        #expect(await eventually { recorder.microphone == .failed })
        #expect(recorder.systemAudio == .failed && recorder.state == .recording)
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
    @Test("A window recording leaves out a Keybumps window that opens mid-recording")
    func ownWindowOpens() async throws {
        defer { captures.remove() }
        system.ownWindows = [30, 31]
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        recorder.tick()
        #expect(system.videoStreams[0].plans.isEmpty, "nothing changed")

        let notice = ScreencastContent.Window(id: 40, frame: CGRect(x: 500, y: 0, width: 300, height: 40), layer: 25, processID: Screens.ownProcess, isUntitled: true, isOnScreen: true)
        system.screen = Screens.content(windows: Screens.content().windows + [notice])
        system.ownWindows = [30, 31, 40]
        recorder.tick()
        #expect(await eventually { !system.videoStreams[0].plans.isEmpty })
        #expect(system.videoStreams[0].plans.last == .applications(1, includedProcesses: [Screens.browser, Screens.ownProcess], exceptingWindows: [12, 30, 31, 40]))
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
    @Test("A window recording follows its window as it moves, and onto another display")
    func followsTheWindow() async throws {
        defer { captures.remove() }
        let recorder = makeRecorder()
        try await start(recorder, .window(10))
        system.windowFrames[10] = CGRect(x: 100, y: 100, width: 800, height: 600)
        recorder.tick()
        for _ in 0..<20 { await Task.yield() }
        #expect(system.videoStreams[0].sourceRects.isEmpty, "it hasn't moved")

        system.windowFrames[10] = CGRect(x: 250, y: 150, width: 800, height: 600)
        recorder.tick()
        #expect(await eventually { system.videoStreams[0].sourceRects == [CGRect(x: 250, y: 150, width: 800, height: 600)] })

        let moved = CGRect(x: 1700, y: 200, width: 800, height: 600)
        var windows = Screens.content().windows
        windows[0] = ScreencastContent.Window(id: 10, frame: moved, layer: 0, processID: Screens.browser, isUntitled: false, isOnScreen: true)
        system.screen = Screens.content(windows: windows)
        system.windowFrames[10] = moved
        recorder.tick()
        #expect(await eventually { system.videoStreams[0].plans.last?.displayID == 2 })
        #expect(await eventually { system.videoStreams[0].sourceRects.last == CGRect(x: 188, y: 200, width: 800, height: 600) })
    }
}
