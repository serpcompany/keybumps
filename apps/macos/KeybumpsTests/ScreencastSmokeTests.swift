import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Keybumps

/// The QA smoke test's runner (#470), driven through the real controller, control bar, and
/// overlays with the recorder's fake capture system and writers, a made-up screen, and overlays
/// that draw nothing. Nothing here captures the screen, shows a window, or asks for a permission:
/// the real path runs only on an installed QA candidate (`apps/macos/scripts/smoke-screencast.sh`).
@MainActor
@Suite("Screencast: the QA smoke test")
struct ScreencastSmokeTests {
    /// The smoke test's own window, on the left (main) display, behind the browser window.
    static let smokeWindow = ScreencastContent.Window(
        id: 40, frame: CGRect(x: 120, y: 120, width: 360, height: 220), layer: 0,
        processID: ScreencastScreens.ownProcess, isUntitled: false, isOnScreen: true
    )

    static func screen() -> ScreencastContent {
        ScreencastScreens.content(windows: [ScreencastScreens.browserWindow, smokeWindow, ScreencastScreens.otherAppWindow])
    }

    let captureSystem = FakeCaptureSystem(content: Self.screen())
    let pickerSystem = FakePickerSystem(content: Self.screen())
    let writers = FakeWriterFactory()
    let clock = FakeHostClock()
    let overlays = FakeOverlays()
    let defaults = InMemoryDefaults()
    let folder = TemporaryCapturesFolder()

    var capturesURL: URL { folder.url.appendingPathComponent("captures", isDirectory: true) }
    var resultURL: URL { folder.url.appendingPathComponent("QA/screencast-smoke-test.json") }

    @available(macOS 15, *)
    static var quick: ScreencastSmokeRunner.Configuration {
        ScreencastSmokeRunner.Configuration(
            pickerTimeout: 2, startTimeout: 2, finishTimeout: 2, checkTimeout: 2, windDownTimeout: 2, pollInterval: .milliseconds(2)
        )
    }

    @available(macOS 15, *)
    func makeRunner(
        configuration: ScreencastSmokeRunner.Configuration? = nil,
        granted: Bool = true,
        video: ScreencastSmokeVideoFacts = ScreencastSmokeVideoFacts(videoTracks: 1, duration: 2, pixelWidth: 64, pixelHeight: 36)
    ) -> (ScreencastSmokeRunner, ScreencastSmokeRig) {
        let clock = clock
        let recorder = ScreencastRecorder(
            system: captureSystem,
            writers: writers,
            hostClock: { clock.now },
            ownProcessID: ScreencastScreens.ownProcess,
            microphoneGranted: { false },
            tickInterval: nil
        )
        let rig = ScreencastSmokeRig.make(
            recorder: recorder,
            captureSystem: captureSystem,
            pickerSystem: pickerSystem,
            presenter: overlays,
            screens: { PickerScreens.both },
            defaults: defaults,
            capturesFolder: capturesURL,
            ownProcessID: ScreencastScreens.ownProcess
        )
        let runner = ScreencastSmokeRunner(
            rig: rig,
            inspector: ScreencastSmokeInspector(video: { _ in video }, image: ScreencastSmokeInspector.system.image),
            configuration: configuration ?? Self.quick,
            environment: ScreencastSmokeRunner.Environment(
                macOS: "15.6.1",
                displayCount: 2,
                screenRecordingGranted: { granted },
                mainDisplay: { 1 },
                ownWindow: { Self.smokeWindow.id },
                isFinder: { $0 == ScreencastScreens.otherApp },
                resultURL: resultURL,
                record: { seconds in clock.advance(seconds) }
            )
        )
        return (runner, rig)
    }

    private var videoPlans: [ScreencastFilterPlan] {
        captureSystem.videoStreams.compactMap { stream in
            if case .video(let plan, _) = stream.kind { plan } else { nil }
        }
    }

    // MARK: Running

    @available(macOS 15, *)
    @Test("Each capture goes from Start Screencast through Record and Stop to checked files, all deleted, with no picker window")
    func passes() async throws {
        defer { folder.remove() }
        let (runner, rig) = makeRunner()
        let report = await runner.run()

        #expect(report.passed && report.complete && report.cleanedUp && report.exitCode == 0)
        #expect(report.captures.map(\.mode) == ScreencastSmokeMode.allCases)
        for capture in report.captures {
            #expect(capture.passed && capture.stage == .cleanedUp && capture.errorCategory == nil, "\(capture.mode)")
            #expect(capture.timings.pickerMs != nil && capture.timings.finishMs != nil && capture.timings.checkMs != nil)
            #expect((capture.bytes ?? 0) > 0 && (capture.pixelWidth ?? 0) > 0)
        }
        let videos = report.captures.filter { $0.mode.kind == .video }
        #expect(videos.allSatisfy { $0.controlBarShown == true && $0.overlaysShown == true && $0.durationSeconds == 2 })
        #expect(videos.allSatisfy { $0.timings.startMs != nil && $0.timings.recordMs != nil })
        #expect(report.captures[1].windowSource == .own)
        #expect(report.captures[4].windowSource == .finder)

        // The main display, the smoke test's own window, and an area in the middle of the main
        // display, with no sound.
        let plans = videoPlans
        #expect(plans.count == 3 && plans.allSatisfy { $0.displayID == 1 })
        guard plans.count == 3, case .windows(_, let included) = plans[1] else {
            Issue.record("the window video didn't record a window")
            return
        }
        #expect(included.contains(Self.smokeWindow.id))
        #expect(captureSystem.audioStreams.isEmpty)
        if case .video(_, let configuration) = captureSystem.videoStreams[2].kind {
            let area = ScreencastSmokeRunner.area(in: PickerScreens.left.frame)
            #expect(abs(configuration.sourceRect.width - area.width) < 2 && abs(configuration.sourceRect.height - area.height) < 2)
        }
        // Screenshots: the main display, Finder's window rather than the browser in front, the area.
        #expect(pickerSystem.plans.count == 3)
        #expect(pickerSystem.plans.map(\.filter.displayID) == [1, nil, 1])
        #expect(pickerSystem.plans.dropFirst().first?.filter == .window(ScreencastScreens.otherAppWindow.id))

        // The picker's windows never opened; the area's highlight did, and closed; nothing is left.
        #expect(!overlays.events.contains(.showPicker))
        #expect(overlays.events.contains { if case .highlight = $0 { true } else { false } })
        #expect(overlays.messages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: capturesURL.path))
        #expect(rig.controller.phase == .idle && rig.recordingControls.bar?.isShown == false && rig.overlays.overlays == nil)
        #expect(defaults.object(forKey: ScreencastAreaMemory.key) != nil, "the area went to the smoke test's own defaults")
    }

    @available(macOS 15, *)
    @Test("The result on disk is the run's, with only structure in it: no paths, file names, or window details")
    func resultShape() async throws {
        defer { folder.remove() }
        let (runner, _) = makeRunner()
        let report = await runner.run()

        let data = try Data(contentsOf: resultURL)
        #expect(try JSONDecoder().decode(ScreencastSmokeReport.self, from: data) == report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "complete", "passed", "macOS", "displayCount", "cleanedUp", "captures"])
        let captures = try #require(object["captures"] as? [[String: Any]])
        let allowed: Set<String> = [
            "mode", "passed", "stage", "errorCategory", "timings", "windowSource", "controlBarShown", "overlaysShown",
            "overlayWindows", "durationSeconds", "pixelWidth", "pixelHeight", "bytes",
        ]
        #expect(captures.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/") && !text.contains(".mov") && !text.contains(".png"))
    }

    @available(macOS 15, *)
    @Test("A video that can't start fails with the engine's reason, shown as the app shows it, and the screenshots still run")
    func failedStart() async throws {
        defer { folder.remove() }
        captureSystem.videoStartError = .captureFailed
        let (runner, _) = makeRunner()
        let report = await runner.run()

        #expect(!report.passed && report.complete && report.exitCode == 1)
        let videos = report.captures.filter { $0.mode.kind == .video }
        #expect(videos.count == 3 && videos.allSatisfy { !$0.passed && $0.stage == .starting && $0.errorCategory == "captureFailed" })
        #expect(report.captures.filter { $0.mode.kind == .screenshot }.allSatisfy { $0.passed })
        #expect(overlays.messages.contains(ScreencastMessages.text(for: .captureFailed, kind: .video)))
        #expect(!FileManager.default.fileExists(atPath: capturesURL.path))
    }

    @available(macOS 15, *)
    @Test("A stop that hangs times out at the stage it reached, and the captures after it are skipped")
    func hang() async throws {
        defer { folder.remove() }
        writers.configure = { $0.holdsFinish = true }
        var configuration = Self.quick
        configuration.finishTimeout = 0.2
        configuration.windDownTimeout = 0.2
        let (runner, rig) = makeRunner(configuration: configuration)
        let report = await runner.run()

        #expect(!report.passed && report.complete && report.cleanedUp && report.exitCode == 1)
        #expect(report.captures[0].stage == .finishing && report.captures[0].errorCategory == "timeout")
        #expect(report.captures.dropFirst().allSatisfy { $0.stage == .notStarted && $0.errorCategory == "skipped" })
        #expect(try JSONDecoder().decode(ScreencastSmokeReport.self, from: Data(contentsOf: resultURL)) == report)

        writers.writers.forEach { $0.releaseFinish() }
        #expect(await ScreencastWait.until { rig.controller.phase == .idle })
    }

    @available(macOS 15, *)
    @Test("Without Screen Recording nothing is read or captured, and the result says why")
    func permissionDenied() async throws {
        defer { folder.remove() }
        let (runner, _) = makeRunner(granted: false)
        let report = await runner.run()

        #expect(report.errorCategory == "permissionDenied" && report.exitCode == 2 && !report.passed && report.complete)
        #expect(report.captures.allSatisfy { $0.stage == .notStarted })
        #expect(pickerSystem.contentReads == 0 && captureSystem.contentReads == 0 && overlays.events.isEmpty)
    }

    @available(macOS 15, *)
    @Test("A recording of the wrong length fails its check, and its file is still deleted")
    func wrongLength() async throws {
        defer { folder.remove() }
        let (runner, _) = makeRunner(video: ScreencastSmokeVideoFacts(videoTracks: 1, duration: 0.3, pixelWidth: 64, pixelHeight: 36))
        let report = await runner.run()

        let videos = report.captures.filter { $0.mode.kind == .video }
        #expect(videos.count == 3 && videos.allSatisfy { $0.stage == .saved && $0.errorCategory == "durationOutOfRange" })
        #expect(report.captures.filter { $0.mode.kind == .screenshot }.allSatisfy { $0.passed })
        #expect(!FileManager.default.fileExists(atPath: capturesURL.path))
    }

    // MARK: Checks

    @available(macOS 15, *)
    @Test("A check fails a missing or empty file, a video with no picture or of the wrong length, and an image that doesn't decode")
    func checks() throws {
        defer { folder.remove() }
        let missing = folder.url.appendingPathComponent("missing.mov")
        #expect(throws: ScreencastSmokeFailure.missingFile) { try ScreencastSmokeChecks.size(of: missing, fileManager: .default) }
        let empty = folder.url.appendingPathComponent("empty.mov")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(throws: ScreencastSmokeFailure.emptyFile) { try ScreencastSmokeChecks.size(of: empty, fileManager: .default) }

        func video(tracks: Int = 1, duration: TimeInterval, width: Int = 64) -> ScreencastSmokeVideoFacts {
            ScreencastSmokeVideoFacts(videoTracks: tracks, duration: duration, pixelWidth: width, pixelHeight: 36)
        }
        #expect(throws: ScreencastSmokeFailure.noVideoTrack) { try ScreencastSmokeChecks.check(video(tracks: 0, duration: 2), durations: 1...4) }
        #expect(throws: ScreencastSmokeFailure.noVideoTrack) { try ScreencastSmokeChecks.check(video(duration: 2, width: 0), durations: 1...4) }
        #expect(throws: ScreencastSmokeFailure.durationOutOfRange) { try ScreencastSmokeChecks.check(video(duration: 0.5), durations: 1...4) }
        #expect(throws: ScreencastSmokeFailure.durationOutOfRange) { try ScreencastSmokeChecks.check(video(duration: 9), durations: 1...4) }
        #expect(throws: Never.self) { try ScreencastSmokeChecks.check(video(duration: 2.1), durations: 1...4) }
        #expect(throws: ScreencastSmokeFailure.undecodableImage) { try ScreencastSmokeChecks.check(nil) }
        #expect(ScreencastSmokeChecks.pixels(.nan) == 0 && ScreencastSmokeChecks.pixels(.infinity) == 0)
        #expect(ScreencastSmokeChecks.pixels(1919.6) == 1920)

        let message = ScreencastMessages.text(for: .writerFailed, kind: .screenshot)
        #expect(ScreencastSmokeRunner.failure(shownAs: message, kind: .screenshot) == .writerFailed)
        #expect(ScreencastSmokeRunner.failure(shownAs: ScreencastMessages.endedEarly(.stoppedByMacOS, kept: true), kind: .video) == .stoppedByMacOS)
        #expect(ScreencastSmokeRunner.area(in: PickerScreens.left.frame) == CGRect(x: 436, y: 311, width: 640, height: 360))
    }

    @Test("The checks read a real 2-second movie and a real PNG, and neither reading accepts a file that's neither")
    func realFiles() async throws {
        defer { folder.remove() }
        let writer = try ScreencastMovieWriter(
            url: folder.url.appendingPathComponent("video-1.mov"),
            pixelWidth: 320,
            pixelHeight: 180,
            audio: [],
            options: ScreencastOptions(),
            onFailure: {}
        )
        for frame in 0..<60 {
            writer.appendVideo(ScreencastSamples.video(at: 100 + Double(frame) / 30, width: 320, height: 180, shade: UInt8(frame)))
            usleep(2_000)
        }
        let result = await writer.finish(at: 102)
        let facts = try await ScreencastSmokeInspector.system.video(result.fileURL)
        #expect(facts.videoTracks == 1 && facts.pixelWidth == 320 && facts.pixelHeight == 180)
        #expect(abs(facts.duration - 2) < 0.1)
        #expect(throws: Never.self) { try ScreencastSmokeChecks.check(facts, durations: 1...4) }

        let png = folder.url.appendingPathComponent("screenshot-1.png")
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, ScreencastImages.blank(width: 64, height: 36), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(ScreencastSmokeInspector.system.image(png) == ScreencastSmokeImageFacts(pixelWidth: 64, pixelHeight: 36))

        let garbage = folder.url.appendingPathComponent("garbage.mov")
        FileManager.default.createFile(atPath: garbage.path, contents: Data("movie".utf8))
        #expect(ScreencastSmokeInspector.system.image(garbage) == nil)
        let garbageVideo = try? await ScreencastSmokeInspector.system.video(garbage)
        #expect(garbageVideo == nil || garbageVideo?.videoTracks == 0)
    }

    // MARK: Launching

    @Test("The option runs only in a QA candidate, and the result goes beside the QA candidates' backups")
    func launchOption() {
        let defaults = InMemoryDefaults()
        #expect(!ScreencastSmokeTest.isRequested(version: "0.0.3-dev.issue470", defaults: defaults))
        defaults.set(true, forKey: ScreencastSmokeTest.launchOption)
        #expect(ScreencastSmokeTest.isRequested(version: "0.0.3-dev.issue470", defaults: defaults))
        #expect(!ScreencastSmokeTest.isRequested(version: "0.0.3-beta.25", defaults: defaults))
        #expect(
            ScreencastSmokeTest.resultURL(home: URL(fileURLWithPath: "/Users/someone", isDirectory: true)).path
                == "/Users/someone/Library/Developer/Keybumps-QA/screencast-smoke-test.json"
        )
    }

    @Test("The script launches the option the app reads, reads the result where the app writes it, and never kills by name")
    func scriptMatchesApp() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/smoke-screencast.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("option=\(ScreencastSmokeTest.launchOption)\n"))
        #expect(text.contains("result=\"$HOME/Library/Developer/Keybumps-QA/screencast-smoke-test.json\""))
        #expect(text.contains("== \(ScreencastSmokeFailure.permissionDenied.rawValue) ]]"))
        #expect(!text.contains("pkill") && !text.contains("killall"))
    }

    @available(macOS 15, *)
    @Test("A step that hangs times out without being waited for, and one that finishes returns its value")
    func timeLimits() async throws {
        #expect(try await ScreencastSmokeRunner.within(1) { 42 } == 42)
        let step = HeldStep()
        let started = ContinuousClock.now
        await #expect(throws: ScreencastSmokeFailure.timeout) {
            try await ScreencastSmokeRunner.within(0.05) { await step.wait() }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(step.isWaiting, "the hung step is left behind, not waited for")
        step.release()
    }
}

/// A step that waits until released, and doesn't stop when its task is cancelled.
@MainActor
private final class HeldStep {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
