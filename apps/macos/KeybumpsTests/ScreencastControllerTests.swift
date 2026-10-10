import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Keybumps

/// `ScreencastController`, the flow from Start Screencast to a saved capture, driven through fakes:
/// the recorder's capture system and writers, a made-up screen for the picker and screenshots,
/// overlays that draw nothing, and a countdown clock the test moves. Nothing here captures, opens
/// the microphone, asks for a permission, or shows a window.
@MainActor
@Suite("Screencast: the capture flow")
struct ScreencastControllerTests {
    typealias Screens = ScreencastScreens

    let captureSystem = FakeCaptureSystem(content: Screens.content())
    let writers = FakeWriterFactory()
    let clock = FakeHostClock()
    let captures = TemporaryCapturesFolder()
    let pickerSystem = FakePickerSystem(content: Screens.content())
    let overlays = FakeOverlays()
    let sleeper = ManualSleeper()
    let defaults = InMemoryDefaults()
    let startDate = Date(timeIntervalSince1970: 1_791_000_000)

    /// An area on the right display, in AppKit's space.
    let rightArea = ScreencastPickedArea(display: 2, rect: CGRect(x: 1612, y: 0, width: 400, height: 300))
    /// The browser window's frame on the left display, in AppKit's space.
    let leftArea = ScreencastPickedArea(display: 1, rect: CGRect(x: 100, y: 282, width: 800, height: 600))
    /// (150, 150) in the top-left space: on the browser window.
    let onBrowserWindow = CGPoint(x: 150, y: 832)

    @available(macOS 15, *)
    func makeController(
        countdown: Int = 3,
        microphoneAvailable: Bool = true,
        writers: (any ScreencastWriterFactory)? = nil
    ) -> ScreencastController {
        let clock = clock
        let startDate = startDate
        let sleeper = sleeper
        let recorder = ScreencastRecorder(
            system: captureSystem,
            writers: writers ?? self.writers,
            hostClock: { clock.now },
            now: { startDate },
            ownProcessID: Screens.ownProcess,
            microphoneGranted: { true },
            tickInterval: nil
        )
        let preferences = PickerScreens.preferences(countdown: countdown, captures: captures.url)
        return ScreencastController(
            recorder: recorder,
            system: pickerSystem,
            presenter: overlays,
            areaMemory: ScreencastAreaMemory(defaults: defaults),
            preferences: { preferences },
            screens: { PickerScreens.both },
            microphoneAvailable: { microphoneAvailable },
            sleep: { try await sleeper.sleep($0) },
            now: { startDate },
            ownProcessID: Screens.ownProcess
        )
    }

    private func remember(_ area: ScreencastPickedArea) {
        ScreencastAreaMemory(defaults: defaults).save(area.rect)
    }

    /// Opens the picker on `target` as `kind`, with windows read, and presses Record.
    @available(macOS 15, *)
    private func record(
        _ controller: ScreencastController,
        _ target: ScreencastPickerTarget = .area,
        kind: ScreencastCaptureKind = .video,
        configure: (ScreencastPickerModel) -> Void = { _ in }
    ) async throws {
        controller.open()
        let model = try #require(controller.picker)
        #expect(await ScreencastWait.until { overlays.picker === model })
        #expect(!model.windows.isEmpty)
        model.kind = kind
        model.target = target
        if target == .window { model.clickWindow(at: onBrowserWindow) }
        configure(model)
        overlays.record()
    }

    private func videoStream(_ index: Int = 0) -> (ScreencastFilterPlan, ScreencastStreamConfiguration)? {
        guard captureSystem.videoStreams.indices.contains(index),
              case .video(let plan, let configuration) = captureSystem.videoStreams[index].kind else { return nil }
        return (plan, configuration)
    }

    private var showedHighlight: Bool {
        overlays.events.contains { if case .highlight = $0 { true } else { false } }
    }

    // MARK: Opening the picker

    @available(macOS 15, *)
    @Test("Opening shows the picker with the settings' switches, the last area, and other apps' windows")
    func open() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController(microphoneAvailable: false)
        var phases: [ScreencastPhase] = []
        controller.onPhaseChange = { phases.append($0) }
        var pickerShownAtRead: Bool?
        pickerSystem.onContent = { pickerShownAtRead = overlays.picker != nil }
        controller.open()

        #expect(controller.phase == .picking)
        // The screen is read before the picker covers it, so a macOS alert is never under it.
        #expect(overlays.events == [.watchEscape])
        #expect(await ScreencastWait.until { overlays.picker != nil })
        #expect(pickerShownAtRead == false)
        #expect(overlays.events == [.watchEscape, .showPicker])
        let model = try #require(overlays.picker)
        #expect(model === controller.picker)
        #expect(model.area == rightArea)
        #expect(!model.recordsMicrophone && model.recordsSystemAudio && model.showsShortcuts && !model.highlightsClicks)
        // Read before it showed: not Keybumps's control bar or drawing layer, and not the browser's menu.
        #expect(model.windows.map(\.id) == [10, 11, 12, 20])

        controller.open()
        #expect(overlays.events.filter { $0 == .showPicker }.count == 1)
        #expect(phases == [.picking])
    }

    @available(macOS 15, *)
    @Test("Without the screen, the picker still opens, with no windows to pick")
    func openWithoutScreen() async throws {
        defer { captures.remove() }
        pickerSystem.contentError = .screenRecordingDenied
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        #expect(controller.phase == .picking)
        #expect(controller.picker?.windows.isEmpty == true)
    }

    @available(macOS 15, *)
    @Test("A window the window server draws transparent can't be picked")
    func transparentWindow() async throws {
        defer { captures.remove() }
        pickerSystem.transparent = [Screens.browserWindow.id]
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        #expect(controller.picker?.windows.map(\.id) == [11, 12, 20])
    }

    @available(macOS 15, *)
    @Test("Escape while the screen is still being read never shows the picker")
    func escapeBeforeThePickerShows() async {
        defer { captures.remove() }
        let controller = makeController()
        controller.open()
        overlays.pressEscape()
        #expect(controller.phase == .idle)
        for _ in 0..<50 { await Task.yield() }
        #expect(!overlays.events.contains(.showPicker))
    }

    @available(macOS 15, *)
    @Test("Record does nothing until something is chosen")
    func nothingChosen() async {
        defer { captures.remove() }
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        overlays.record()
        #expect(controller.phase == .picking)
        #expect(!overlays.events.contains(.closePicker))
    }

    // MARK: Counting down and recording

    @available(macOS 15, *)
    @Test("Record counts down on the area, then records it with the sounds the switches chose")
    func countdownThenRecord() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller) { $0.recordsSystemAudio = false }

        #expect(controller.picker == nil)
        #expect(overlays.events.contains(.closePicker))
        #expect(overlays.events.contains(.highlight(rightArea)))
        #expect(controller.phase == .countingDown(remaining: 3))
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: 2) })
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: 1) })
        #expect(captureSystem.videoStreams.isEmpty)
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .recording })

        #expect(overlays.countdowns == [3, 2, 1])
        #expect(overlays.events.contains(.countdown(3, frames: [rightArea.rect])))
        #expect(overlays.events.contains(.closeCountdown))
        #expect(sleeper.requested == [1, 1, 1])
        #expect(controller.recorder.target == .area(display: 2, rect: CGRect(x: 100, y: 682, width: 400, height: 300)))
        let (plan, configuration) = try #require(videoStream())
        // The highlight, the countdown, and the picker are Keybumps's: all of it is left out.
        #expect(plan == .display(2, excludingProcess: Screens.ownProcess, exceptingWindows: []))
        #expect(configuration.sourceRect == CGRect(x: 100, y: 682, width: 400, height: 300))
        #expect(!configuration.showsMouseClicks)
        #expect(captureSystem.audioStreams.first?.kind == .audio(ScreencastAudio(microphone: true, systemAudio: false)))
        // The highlight stays while it records; Escape no longer cancels.
        #expect(!overlays.events.contains(.closeHighlight))
        #expect(!overlays.isWatchingEscape)
        #expect(controller.choice?.area == rightArea)
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: PickerScreens.both) == rightArea)
    }

    @available(macOS 15, *)
    @Test("With no countdown, Record starts at once; every screen records each display, with no highlight")
    func noCountdown() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        try await record(controller, .screen)
        #expect(controller.phase == .starting)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(sleeper.requested.isEmpty && overlays.countdowns.isEmpty)
        #expect(controller.recorder.target == .everyDisplay)
        #expect(captureSystem.videoStreams.count == 2)
        #expect(!showedHighlight)
        // Every screen isn't an area: the last area stays as it was.
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: PickerScreens.both) == nil)
    }

    @available(macOS 15, *)
    @Test("A screen clicked in Screen mode records that display alone")
    func oneScreen() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.right) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(controller.recorder.target == .display(2))
        #expect(captureSystem.videoStreams.count == 1)
        #expect(controller.choice?.regions == [ScreencastChoice.Region(display: 2, frame: PickerScreens.right.frame)])
    }

    @available(macOS 15, *)
    @Test("A window counts down on the window and records it, with clicks shown when switched on")
    func window() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .window) { $0.highlightsClicks = true }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(overlays.events.contains(.countdown(3, frames: [leftArea.rect])))
        for remaining in [2, 1] {
            sleeper.advance()
            #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: remaining) })
        }
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(controller.recorder.target == .window(10))
        #expect(videoStream()?.1.showsMouseClicks == true)
        #expect(controller.choice?.highlightsClicks == true && controller.choice?.regions.map(\.display) == [1])
        #expect(!showedHighlight)
    }

    @available(macOS 15, *)
    @Test("Every screen counts down on every screen")
    func everyScreenCountdown() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(overlays.events.contains(.countdown(3, frames: [PickerScreens.left.frame, PickerScreens.right.frame])))
    }

    // MARK: Cancelling

    @available(macOS 15, *)
    @Test("Escape, or the bar's close button, closes the picker and keeps nothing")
    func cancelPicking() async {
        defer { captures.remove() }
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        let model = controller.picker
        model?.pressArea(at: CGPoint(x: 1612, y: 300), on: PickerScreens.right)
        model?.dragArea(to: CGPoint(x: 2012, y: 0))
        model?.releaseArea()
        overlays.pressEscape()
        #expect(controller.phase == .idle && controller.picker == nil)
        #expect(overlays.events.suffix(2) == [.closePicker, .stopWatchingEscape])
        // Only Record remembers the area.
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: PickerScreens.both) == nil)

        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        overlays.cancel()
        #expect(controller.phase == .idle && !overlays.isWatchingEscape)
        #expect(captures.captureFolders().isEmpty)
        #expect(pickerSystem.plans.isEmpty && captureSystem.videoStreams.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Escape, or its Cancel, stops the countdown: nothing records and no folder is made")
    func cancelCountdown() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: 2) })
        overlays.pressEscape()
        #expect(controller.phase == .idle && controller.choice == nil)
        #expect(await ScreencastWait.until { sleeper.pending == 0 })
        #expect(overlays.events.contains(.closeCountdown) && overlays.events.contains(.closeHighlight))

        try await record(controller)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        overlays.cancelTheCountdown()
        #expect(controller.phase == .idle)
        #expect(await ScreencastWait.until { sleeper.pending == 0 })

        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(captureSystem.contentReads == 0 && captureSystem.videoStreams.isEmpty)
        #expect(captures.captureFolders().isEmpty)
    }

    @available(macOS 15, *)
    @Test("Escape before the countdown's first second is still a cancel")
    func cancelAtOnce() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller)
        overlays.pressEscape()
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(sleeper.pending == 0 && overlays.countdowns.isEmpty)
        #expect(captureSystem.videoStreams.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Escape while recording starts cancels the start and deletes its folder")
    func cancelStarting() async throws {
        defer { captures.remove() }
        captureSystem.holdsVideoStart = true
        remember(rightArea)
        let controller = makeController(countdown: 0)
        try await record(controller)
        #expect(await ScreencastWait.until { captureSystem.videoStreams.first?.isHoldingStart == true })
        #expect(controller.phase == .starting && overlays.isWatchingEscape)
        #expect(captures.captureFolders().count == 1)
        overlays.pressEscape()
        #expect(controller.phase == .idle)
        #expect(overlays.events.contains(.closeHighlight))
        // The recorder winds the start down once it returns, and only then is free again.
        #expect(await ScreencastWait.until { controller.recorder.state == .stopping })
        controller.open()
        #expect(controller.phase == .idle, "Not while the cancelled start winds down")
        captureSystem.videoStreams[0].releaseStart()
        #expect(await ScreencastWait.until { controller.recorder.state == .idle })
        #expect(await ScreencastWait.until { captureSystem.videoStreams[0].stopCount == 1 })
        #expect(await ScreencastWait.until { captures.captureFolders().isEmpty })
        #expect(controller.phase == .idle)
    }

    @available(macOS 15, *)
    @Test("Once recording, Escape does nothing; Discard throws the recording away")
    func discard() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        overlays.pressEscape()
        controller.cancel()
        #expect(controller.phase == .recording)

        await controller.discard()
        #expect(controller.phase == .idle && controller.recorder.state == .idle)
        #expect(finished.isEmpty)
        #expect(captures.captureFolders().isEmpty)
    }

    // MARK: Recording and stopping

    @available(macOS 15, *)
    @Test("Pausing, resuming, and switching a sound go through to the recorder")
    func pauseAndResume() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        controller.pause()
        #expect(controller.phase == .paused && controller.recorder.state == .paused)
        controller.setAudio(.microphone, on: false)
        #expect(controller.recorder.microphone == .off)
        controller.resume()
        #expect(controller.phase == .recording && controller.recorder.state == .recording)
        await controller.restart()
        #expect(controller.phase == .recording)
    }

    @available(macOS 15, *)
    @Test("Stop keeps the recording and hands it to the review panel, after every phase in order")
    func stop() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController(countdown: 0)
        var phases: [ScreencastPhase] = []
        var finished: [ScreencastCaptureResult] = []
        controller.onPhaseChange = { phases.append($0) }
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        clock.advance(5)
        await controller.stop()

        #expect(controller.phase == .idle && controller.choice == nil)
        #expect(phases == [.picking, .starting, .recording, .finishing, .idle])
        #expect(overlays.events.contains(.closeHighlight))
        let result = try #require(finished.first)
        guard case .video(let capture) = result else {
            Issue.record("expected a video, got \(result)")
            return
        }
        #expect(capture.folder == captures.url.appendingPathComponent("1791000000", isDirectory: true))
        #expect(result.folder == capture.folder)
        #expect(FileManager.default.fileExists(atPath: capture.metadataURL.path))
    }

    @available(macOS 15, *)
    @Test("Screen Recording refused: the start says so, closes everything, and leaves no folder")
    func startDenied() async throws {
        defer { captures.remove() }
        captureSystem.contentError = .screenRecordingDenied
        remember(rightArea)
        let controller = makeController(countdown: 0)
        try await record(controller)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(overlays.messages == [ScreencastMessages.text(for: .screenRecordingDenied, kind: .video)])
        #expect(overlays.events.contains(.closeHighlight) && !overlays.isWatchingEscape)
        #expect(controller.choice == nil)
        #expect(captures.captureFolders().isEmpty)

        controller.open()
        #expect(controller.phase == .picking)
    }

    @available(macOS 15, *)
    @Test("macOS stopping the recording keeps what was recorded, says why, and hands it on")
    func endedEarly() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        clock.advance(3)
        captureSystem.videoStreams[0].handler.stopped(.stoppedByMacOS)

        #expect(await ScreencastWait.until { !finished.isEmpty })
        #expect(controller.phase == .idle)
        guard case .video(let capture) = finished.first else {
            Issue.record("expected a video")
            return
        }
        #expect(capture.endedEarly == .stoppedByMacOS)
        #expect(overlays.messages == ["macOS stopped the recording. What was recorded is saved."])
        #expect(overlays.events.contains(.closeHighlight))
    }

    // MARK: Ending on its own while the control bar acts

    /// Records every screen with both sounds, then makes the recording end on its own and holds its
    /// save at the mixdown.
    @available(macOS 15, *)
    private func endEarlyAndHold(_ controller: ScreencastController, _ holding: HoldingMixdownWriters) async throws {
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        clock.advance(3)
        captureSystem.videoStreams[0].handler.stopped(.stoppedByMacOS)
        #expect(await ScreencastWait.until { holding.isHolding })
        #expect(controller.recorder.state == .stopping)
        // It leaves `.recording` as soon as the recorder starts saving, before any button.
        #expect(await ScreencastWait.until { controller.phase == .finishing })
    }

    @available(macOS 15, *)
    @Test("Stop while a recording that ended on its own is saving waits for that capture")
    func stopDuringEarlyEnd() async throws {
        defer { captures.remove() }
        let holding = HoldingMixdownWriters()
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        let stopping = Task { await controller.stop() }
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .finishing && finished.isEmpty)
        holding.release()
        await stopping.value

        #expect(controller.phase == .idle)
        guard case .video(let capture) = finished.first else {
            Issue.record("expected the capture it saved")
            return
        }
        #expect(finished.count == 1 && capture.endedEarly == .stoppedByMacOS)
        #expect(FileManager.default.fileExists(atPath: capture.folder.path))
        #expect(overlays.messages == ["macOS stopped the recording. What was recorded is saved."])
    }

    @available(macOS 15, *)
    @Test("Discard while a recording that ended on its own is saving deletes that capture, and nothing opens")
    func discardDuringEarlyEnd() async throws {
        defer { captures.remove() }
        let holding = HoldingMixdownWriters()
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        let discarding = Task { await controller.discard() }
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .finishing)
        holding.release()
        await discarding.value

        #expect(controller.phase == .idle)
        #expect(finished.isEmpty)
        #expect(overlays.messages.isEmpty)
        #expect(await ScreencastWait.until { captures.captureFolders().isEmpty })
    }

    @available(macOS 15, *)
    @Test("Restart while a recording that ended on its own is saving is refused")
    func restartDuringEarlyEnd() async throws {
        defer { captures.remove() }
        let holding = HoldingMixdownWriters()
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        await controller.restart()
        controller.pause()
        #expect(controller.phase == .finishing)
        #expect(holding.base.writers.count == 2, "No new take's files")
        holding.release()
        #expect(await ScreencastWait.until { !finished.isEmpty })
        #expect(controller.phase == .idle)
        #expect(overlays.messages == ["macOS stopped the recording. What was recorded is saved."])
    }

    // MARK: Restarting

    /// Starts a restart whose old take is still being deleted.
    @available(macOS 15, *)
    private func holdRestart(_ controller: ScreencastController) async throws -> Task<Void, Never> {
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        // The first old file's deletion waits; the restart is still under way.
        writers.writers.first?.holdsCancel = true
        let restarting = Task { await controller.restart() }
        #expect(await ScreencastWait.until { writers.writers.first?.isHoldingCancel == true })
        return restarting
    }

    private func releaseRestart() {
        writers.writers.first?.releaseCancel()
    }

    @available(macOS 15, *)
    @Test("A pause while a restart finishes stays paused")
    func pauseDuringRestart() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        let restarting = try await holdRestart(controller)
        controller.pause()
        #expect(controller.phase == .paused)
        releaseRestart()
        await restarting.value
        #expect(controller.phase == .paused && controller.recorder.state == .paused)
    }

    @available(macOS 15, *)
    @Test("A stop while a restart finishes wins: the new take is saved and the phase stays idle")
    func stopDuringRestart() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        let restarting = try await holdRestart(controller)
        await controller.stop()
        #expect(controller.phase == .idle && finished.count == 1)
        releaseRestart()
        await restarting.value
        #expect(controller.phase == .idle)
        #expect(overlays.messages.isEmpty)
    }

    // MARK: Turning off

    @available(macOS 15, *)
    @Test("Turned off while recording, the recording stops and is kept, and nothing opens")
    func shutDownWhileRecording() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        clock.advance(4)
        await controller.shutDown()

        #expect(controller.phase == .idle && controller.recorder.state == .idle)
        #expect(finished.isEmpty)
        #expect(overlays.events.contains(.closeHighlight))
        let folder = try #require(captures.captureFolders().first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("video-1.mov").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ScreencastMetadata.fileName).path))

        // Opened again, captures open as before.
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        await controller.stop()
        #expect(finished.count == 1)
    }

    @available(macOS 15, *)
    @Test("Turned off while a screenshot is saving, it's saved, and nothing opens")
    func shutDownWhileSavingAScreenshot() async throws {
        defer { captures.remove() }
        pickerSystem.holdsScreenshots = true
        let controller = makeController()
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .screen, kind: .screenshot)
        #expect(await ScreencastWait.until { pickerSystem.isHoldingScreenshot })
        #expect(controller.phase == .finishing)
        await controller.shutDown()
        pickerSystem.releaseScreenshots()
        // The second display's screenshot is held too.
        #expect(await ScreencastWait.until { pickerSystem.isHoldingScreenshot })
        pickerSystem.releaseScreenshots()
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(finished.isEmpty)
        let folder = try #require(captures.captureFolders().first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("screenshot-2.png").path))
    }

    @available(macOS 15, *)
    @Test("Turned off while picking or counting down, nothing is kept")
    func shutDownBeforeRecording() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        controller.open()
        await controller.shutDown()
        #expect(controller.phase == .idle)
        try await record(controller)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        await controller.shutDown()
        #expect(controller.phase == .idle)
        #expect(await ScreencastWait.until { sleeper.pending == 0 })
        #expect(captureSystem.videoStreams.isEmpty && captures.captureFolders().isEmpty)
    }

    // MARK: Screenshots

    @available(macOS 15, *)
    @Test("A screenshot of an area: no countdown, all of Keybumps left out, a PNG and a structure-only meta.json")
    func screenshotArea() async throws {
        defer { captures.remove() }
        remember(leftArea)
        let controller = makeController()
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, kind: .screenshot)
        #expect(controller.phase == .finishing && !overlays.isWatchingEscape)
        #expect(await ScreencastWait.until { !finished.isEmpty })

        #expect(controller.phase == .idle)
        #expect(sleeper.requested.isEmpty && overlays.countdowns.isEmpty && !showedHighlight)
        #expect(captureSystem.contentReads == 0 && captureSystem.videoStreams.isEmpty)
        #expect(pickerSystem.plans == [ScreencastScreenshotPlan(
            filter: .display(.display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [])),
            configuration: ScreencastStreamConfiguration(
                pixelWidth: 1600, pixelHeight: 1200, sourceRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                framesPerSecond: 1, showsCursor: false, showsMouseClicks: false, scalesToFit: false
            )
        )])
        guard case .screenshot(let screenshot) = finished.first else {
            Issue.record("expected a screenshot")
            return
        }
        let folder = captures.url.appendingPathComponent("1791000000", isDirectory: true)
        #expect(screenshot.folder == folder)
        #expect(screenshot.images == [.init(file: folder.appendingPathComponent("screenshot-1.png"), pixelWidth: 1600, pixelHeight: 1200)])
        let source = try #require(CGImageSourceCreateWithURL(screenshot.images[0].file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 1600)

        let metadata = try ScreencastScreenshotMetadata.read(from: screenshot.metadataURL)
        #expect(metadata.kind == "screenshot" && metadata.target == "area" && metadata.displayCount == 1)
        #expect(metadata.images == [.init(file: "screenshot-1.png", width: 1600, height: 1200)])
        #expect(metadata.startedAt == startDate)
        let keys = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: screenshot.metadataURL)) as? [String: Any]).keys
        #expect(Set(keys) == ["version", "kind", "startedAt", "target", "displayCount", "images"])
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: PickerScreens.both) == leftArea)
    }

    @available(macOS 15, *)
    @Test("A screenshot of every screen is one PNG per display, left to right")
    func screenshotEveryScreen() async throws {
        defer { captures.remove() }
        let controller = makeController()
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .screen, kind: .screenshot)
        #expect(await ScreencastWait.until { !finished.isEmpty })
        #expect(pickerSystem.plans.map(\.filter.displayID) == [1, 2])
        guard case .screenshot(let screenshot) = finished.first else {
            Issue.record("expected a screenshot")
            return
        }
        #expect(screenshot.images.map(\.file.lastPathComponent) == ["screenshot-1.png", "screenshot-2.png"])
        #expect(screenshot.images.map(\.pixelWidth) == [3024, 1920])
        #expect(try ScreencastScreenshotMetadata.read(from: screenshot.metadataURL).target == "everyDisplay")
    }

    @available(macOS 15, *)
    @Test("A window's screenshot is the window on its own, whole, at its display's scale")
    func screenshotWindow() async throws {
        defer { captures.remove() }
        let controller = makeController()
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .window, kind: .screenshot)
        #expect(await ScreencastWait.until { !finished.isEmpty })
        let plan = try #require(pickerSystem.plans.first)
        // Not its app's other windows, menus, or palettes, and not cut to one display.
        #expect(plan.filter == .window(10))
        #expect(plan.filter.displayID == nil)
        #expect(plan.configuration.sourceRect == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(plan.configuration.pixelWidth == 1600 && plan.configuration.pixelHeight == 1200)
        #expect(!plan.configuration.showsCursor)
    }

    @available(macOS 15, *)
    @Test("A screenshot Screen Recording refuses says so and saves nothing")
    func screenshotDenied() async throws {
        defer { captures.remove() }
        pickerSystem.screenshotError = .screenRecordingDenied
        let controller = makeController()
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .screen, kind: .screenshot)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(finished.isEmpty)
        #expect(overlays.messages == [ScreencastMessages.text(for: .screenRecordingDenied, kind: .screenshot)])
        #expect(captures.captureFolders().isEmpty)
    }

    @Test("Keybumps's own process is never a window screenshot's target")
    func screenshotOwnWindow() {
        let own = ScreencastContent.Window(id: 32, frame: CGRect(x: 200, y: 200, width: 600, height: 400), layer: 0, processID: Screens.ownProcess, isUntitled: false, isOnScreen: true)
        #expect(throws: ScreencastFailure.targetUnavailable) {
            try ScreencastScreenshots.plans(for: .window(32), content: Screens.content(windows: [own]), ownProcessID: Screens.ownProcess)
        }
    }

    // MARK: Messages and the unit-test host

    @Test("Every failure has a message, and one that ended early says whether it kept the footage")
    func messages() {
        for failure in [ScreencastFailure.screenRecordingDenied, .targetUnavailable, .captureFailed, .stoppedByMacOS, .writerFailed, .folderUnavailable, .noFootage] {
            #expect(!ScreencastMessages.text(for: failure, kind: .video).isEmpty)
            #expect(ScreencastMessages.endedEarly(failure, kept: true).hasSuffix("What was recorded is saved."))
            #expect(!ScreencastMessages.endedEarly(failure, kept: false).contains("saved"))
        }
        #expect(ScreencastMessages.text(for: .captureFailed, kind: .screenshot).contains("screenshot"))
    }

    @available(macOS 15, *)
    @Test("In the unit-test host the picker's screen reads nothing")
    func inertInTheTestHost() async {
        #expect(UnitTestHost.isActive)
        let system = ScreenCaptureKitPickerSystem.current
        #expect(system is InertScreencastPickerSystem)
        await #expect(throws: ScreencastFailure.captureFailed) { try await system.content() }
    }
}
