import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// `ScreencastController`, the flow from Record Screen to a saved capture, driven through fakes:
/// the recorder's capture system and writers, a made-up screen for the picker,
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
        writers: (any ScreencastWriterFactory)? = nil,
        pointer: @escaping @MainActor () -> CGPoint = { CGPoint(x: -10_000, y: -10_000) },
        screens: @escaping @MainActor () -> ScreencastScreenLayout = { PickerScreens.both },
        gettingReadyDelay: TimeInterval = 0.3,
        screenReadTimeout: TimeInterval = 30,
        screenChanges: NotificationCenter = NotificationCenter()
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
            pickerMemory: ScreencastPickerMemory(defaults: defaults),
            preferences: { preferences },
            saveSwitches: { _ in },
            screens: screens,
            pointerLocation: pointer,
            microphoneAvailable: { microphoneAvailable },
            sleep: { try await sleeper.sleep($0) },
            gettingReadyDelay: gettingReadyDelay,
            screenReadTimeout: screenReadTimeout,
            screenChanges: screenChanges,
            ownProcessID: Screens.ownProcess
        )
    }

    private func remember(_ area: ScreencastPickedArea) {
        ScreencastAreaMemory(defaults: defaults).save(area.rect)
    }

    /// Opens the picker on `target`, with windows read, and presses Record.
    @available(macOS 15, *)
    private func record(
        _ controller: ScreencastController,
        _ target: ScreencastPickerTarget = .area,
        configure: (ScreencastPickerModel) -> Void = { _ in }
    ) async throws {
        controller.open()
        let model = try #require(controller.picker)
        #expect(await ScreencastWait.until { overlays.picker === model })
        #expect(!model.windows.isEmpty)
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
    @Test("If the screen can't be read, the picker never shows, and the message says why")
    func openWithoutScreen() async throws {
        defer { captures.remove() }
        pickerSystem.contentError = .screenRecordingDenied
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(controller.picker == nil)
        #expect(!overlays.events.contains(.showPicker))
        #expect(!overlays.isWatchingEscape)
        #expect(overlays.messages == [ScreencastMessages.text(for: .screenRecordingDenied)])
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
        // Area with none drawn: Screen, where the picker opens, always has a screen chosen.
        controller.picker?.target = .area
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
        // On the area, and on the bar's screen, the left one, which isn't recorded.
        #expect(overlays.events.contains(.countdown(3, frames: [rightArea.rect, PickerScreens.left.frame])))
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
        try await record(controller, .screen) { $0.chooseEveryScreen() }
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
    @Test("Screen mode starts on the screen with the pointer")
    func pointerScreen() async throws {
        defer { captures.remove() }
        let controller = makeController(pointer: { CGPoint(x: 2000, y: 500) })
        controller.open()
        #expect(controller.picker?.selectedScreen == 2)
    }

    @available(macOS 15, *)
    @Test("The bar and Screen mode both use the screen the pointer was on at Record Screen, even if it moves while the screen is read")
    func pointerReadOnce() async throws {
        defer { captures.remove() }
        var pointer = CGPoint(x: 2000, y: 500)
        pickerSystem.holdsContent = true
        let controller = makeController(pointer: { pointer })
        controller.open()
        // To answer an alert macOS shows on the other screen, say.
        pointer = CGPoint(x: 100, y: 100)
        pickerSystem.releaseContent()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        #expect(overlays.picker?.pointerScreen == PickerScreens.right)
        #expect(overlays.picker?.selectedScreen == 2)
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
    @Test("A window chosen, then the pointer over other windows and the bar, and a click and a double click there: Record records the window chosen")
    func windowChosenBeforeTheBar() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .window) { model in
            // The bar over the browser's other window (12), and a point on it over only that one.
            model.barFrame = CGRect(x: 250, y: 190, width: 700, height: 100)
            let onBar = CGPoint(x: 920, y: 240)
            for point in [CGPoint(x: 975, y: 232), CGPoint(x: 1400, y: 20), onBar] {
                model.hoverWindow(at: point)
            }
            #expect(!model.press(at: onBar, on: PickerScreens.left, clickCount: 1))
            #expect(!model.press(at: onBar, on: PickerScreens.left, clickCount: 2))
            #expect(model.selectedWindow == 10)
        }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(overlays.events.contains(.countdown(3, frames: [leftArea.rect])))
        for remaining in [2, 1] {
            sleeper.advance()
            #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: remaining) })
        }
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(controller.recorder.target == .window(10))
    }

    @available(macOS 15, *)
    @Test("Every screen counts down on every screen")
    func everyScreenCountdown() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .screen) { $0.chooseEveryScreen() }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(overlays.events.contains(.countdown(3, frames: [PickerScreens.left.frame, PickerScreens.right.frame])))
    }

    @available(macOS 15, *)
    @Test("A screen recorded away from the bar counts down on it and on the bar's screen (#520)")
    func countdownOnTheBarsScreen() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.right) }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        let frames = [PickerScreens.right.frame, PickerScreens.left.frame]
        #expect(overlays.events.contains(.countdown(3, frames: frames)))
        #expect(controller.choice?.regions.map(\.display) == [2])
    }

    @available(macOS 15, *)
    @Test("With the bar on the right screen, the left screen recorded counts down on it and on the right one (#520)")
    func countdownOnTheRightBarsScreen() async throws {
        defer { captures.remove() }
        // The bar opens on the pointer's screen: the right one, not the first.
        let controller = makeController(pointer: { CGPoint(x: 2000, y: 500) })
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        let frames = [PickerScreens.left.frame, PickerScreens.right.frame]
        #expect(overlays.events.contains(.countdown(3, frames: frames)))
    }

    @available(macOS 15, *)
    @Test("A window on the screen away from the bar counts down on it and on the bar's screen (#520)")
    func windowCountdownOnTheBarsScreen() async throws {
        defer { captures.remove() }
        let controller = makeController(pointer: { CGPoint(x: 100, y: 100) })
        // (2000, 400) in the top-left space: on the other app's window, on the right screen.
        try await record(controller, .window) { $0.clickWindow(at: CGPoint(x: 2000, y: 582)) }
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(controller.choice?.target == .window(20))
        let window = CGRect(x: 1600, y: 282, width: 800, height: 600)
        #expect(overlays.events.contains(.countdown(3, frames: [window, PickerScreens.left.frame])))
    }

    @available(macOS 15, *)
    @Test("With one display, the countdown shows on it once")
    func countdownOnOneDisplay() async throws {
        defer { captures.remove() }
        let controller = makeController(screens: { PickerScreens.leftOnly })
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        #expect(overlays.events.contains(.countdown(3, frames: [PickerScreens.left.frame])))
    }

    @available(macOS 15, *)
    @Test("The countdown shows each second, closes before recording starts, and the video leaves it out")
    func countdownShowsThenCloses() async throws {
        defer { captures.remove() }
        let controller = makeController()
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        for remaining in [3, 2, 1] {
            #expect(await ScreencastWait.until { sleeper.pending == 1 })
            #expect(overlays.countdowns.last == remaining)
            #expect(captureSystem.videoStreams.isEmpty)
            sleeper.advance()
        }
        #expect(await ScreencastWait.until { controller.phase == .recording })

        let left = [PickerScreens.left.frame]
        let shown = overlays.events.filter { event in
            switch event {
            case .countdown, .closeCountdown: true
            default: false
            }
        }
        let expected: [FakeOverlays.Event] = [
            .countdown(3, frames: left), .countdown(2, frames: left), .countdown(1, frames: left), .closeCountdown,
        ]
        #expect(shown == expected)
        let plan = try #require(videoStream()).0
        #expect(plan == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: []))
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
        model?.target = .area
        model?.pressArea(at: CGPoint(x: 1612, y: 300), on: PickerScreens.right)
        model?.dragArea(to: CGPoint(x: 2012, y: 0))
        model?.releaseArea()
        #expect(model?.area != nil, "An area is drawn for Escape to drop")
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
        #expect(captureSystem.videoStreams.isEmpty)
    }

    /// Escape as the presenter hears it now, and one it heard earlier that arrives late.
    private func pressEscape() {
        overlays.pressEscape()
        overlays.pressLateEscape()
    }

    @available(macOS 15, *)
    @Test("Escape in the countdown does nothing: it counts down and the recording starts")
    func escapeInTheCountdown() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller)
        #expect(!overlays.isWatchingEscape)
        pressEscape()
        for remaining in [3, 2, 1] {
            #expect(await ScreencastWait.until { sleeper.pending == 1 })
            #expect(controller.phase == .countingDown(remaining: remaining))
            pressEscape()
            sleeper.advance()
        }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(overlays.countdowns == [3, 2, 1])
        #expect(!overlays.events.contains(.closeHighlight))
        await controller.discard()
    }

    @available(macOS 15, *)
    @Test("The countdown's Cancel stops it: nothing records and no folder is made")
    func cancelCountdown() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller)
        #expect(await ScreencastWait.until { sleeper.pending == 1 })
        sleeper.advance()
        #expect(await ScreencastWait.until { controller.phase == .countingDown(remaining: 2) })
        overlays.cancelTheCountdown()
        #expect(controller.phase == .idle && controller.choice == nil)
        #expect(await ScreencastWait.until { sleeper.pending == 0 })
        #expect(overlays.events.contains(.closeCountdown) && overlays.events.contains(.closeHighlight))

        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(captureSystem.contentReads == 0 && captureSystem.videoStreams.isEmpty)
        #expect(captures.captureFolders().isEmpty)
    }

    @available(macOS 15, *)
    @Test("A cancel before the countdown's first second still stops it")
    func cancelAtOnce() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController()
        try await record(controller)
        controller.cancel()
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(sleeper.pending == 0 && overlays.countdowns.isEmpty)
        #expect(captureSystem.videoStreams.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Escape while recording starts does nothing: the start finishes and it records")
    func escapeWhileStarting() async throws {
        defer { captures.remove() }
        captureSystem.holdsVideoStart = true
        remember(rightArea)
        let controller = makeController(countdown: 0)
        try await record(controller)
        #expect(await ScreencastWait.until { captureSystem.videoStreams.first?.isHoldingStart == true })
        #expect(controller.phase == .starting && !overlays.isWatchingEscape)
        pressEscape()
        #expect(controller.phase == .starting)
        captureSystem.videoStreams[0].releaseStart()
        #expect(await ScreencastWait.until { controller.phase == .recording })
        #expect(captures.captureFolders().count == 1)
        await controller.discard()
    }

    /// What ends a start: turning ScreenGrabs off, or the control bar's Discard (#518).
    enum StartCancel: String, CaseIterable, Sendable {
        case shutDown, discard
    }

    @available(macOS 15, *)
    @Test("Turned off, or Discard, while recording starts: a start that hasn't returned is cancelled, and nothing is kept", arguments: StartCancel.allCases)
    func cancelStarting(_ how: StartCancel) async throws {
        defer { captures.remove() }
        captureSystem.holdsVideoStart = true
        remember(rightArea)
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller)
        #expect(await ScreencastWait.until { captureSystem.videoStreams.first?.isHoldingStart == true })
        #expect(controller.phase == .starting)
        #expect(captures.captureFolders().count == 1)
        // Returns without waiting for the start, which never finishes until released below.
        switch how {
        case .shutDown: await controller.shutDown()
        case .discard: await controller.discard()
        }
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
        #expect(controller.phase == .idle && finished.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Recording or paused, Escape does nothing; Discard throws the recording away")
    func discard() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        pressEscape()
        controller.cancel()
        #expect(controller.phase == .recording && controller.recorder.state == .recording)
        controller.pause()
        pressEscape()
        #expect(controller.phase == .paused && controller.recorder.state == .paused)

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
        #expect(overlays.messages == [ScreencastMessages.text(for: .screenRecordingDenied)])
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

    /// Records one screen with both sounds, then makes the recording end on its own and holds its
    /// save at the mixdown. (With every screen, one display stopping ends only its own file.)
    @available(macOS 15, *)
    private func endEarlyAndHold(_ controller: ScreencastController, _ holding: ScriptedWriters) async throws {
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        clock.advance(3)
        captureSystem.videoStreams[0].handler.stopped(.stoppedByMacOS)
        #expect(await ScreencastWait.until { holding.isHoldingMixdown })
        #expect(controller.recorder.state == .stopping)
        // It leaves `.recording` as soon as the recorder starts saving, before any button.
        #expect(await ScreencastWait.until { controller.phase == .finishing })
    }

    @available(macOS 15, *)
    @Test("Stop while a recording that ended on its own is saving waits for that capture")
    func stopDuringEarlyEnd() async throws {
        defer { captures.remove() }
        let holding = ScriptedWriters(holdsMixdowns: true)
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        let stopping = Task { await controller.stop() }
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .finishing && finished.isEmpty)
        holding.releaseMixdowns()
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
        let holding = ScriptedWriters(holdsMixdowns: true)
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        let discarding = Task { await controller.discard() }
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .finishing)
        holding.releaseMixdowns()
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
        let holding = ScriptedWriters(holdsMixdowns: true)
        let controller = makeController(countdown: 0, writers: holding)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        try await endEarlyAndHold(controller, holding)

        await controller.restart()
        controller.pause()
        #expect(controller.phase == .finishing)
        #expect(holding.base.writers.count == 1, "No new take's files")
        holding.releaseMixdowns()
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

    // MARK: Restarting and ending on its own (round-2 review of #462)

    @available(macOS 15, *)
    @Test("A second restart while one is under way is refused, and a restart that fails leaves the controller free")
    func secondRestartRefused() async throws {
        defer { captures.remove() }
        let writers = ScriptedWriters()
        let controller = makeController(countdown: 0, writers: writers)
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        writers.base.writers[0].holdsCancel = true
        let first = Task { await controller.restart() }
        #expect(await ScreencastWait.until { writers.base.writers[0].isHoldingCancel })
        let made = writers.base.writers.count
        writers.failsNewFiles = true
        await controller.restart()
        #expect(writers.base.writers.count == made, "It never reached the recorder")
        #expect(controller.phase == .recording && controller.recorder.state == .recording)
        writers.base.writers[0].releaseCancel()
        await first.value
        #expect(controller.phase == .recording)

        // A restart that can't make its files ends the recording with its own message, never as an
        // early end, and Record Screen works again.
        await controller.restart()
        #expect(controller.phase == .idle)
        #expect(controller.recorder.state == .failed(.writerFailed))
        #expect(overlays.messages == [ScreencastMessages.text(for: .writerFailed)])
        controller.open()
        #expect(controller.phase == .picking)
    }

    /// Records one screen, starts a restart whose old take is still being deleted, and makes the new
    /// take end on its own meanwhile, with its save held at the mixdown.
    @available(macOS 15, *)
    private func endEarlyDuringRestart(_ controller: ScreencastController, _ writers: ScriptedWriters) async throws -> Task<Void, Never> {
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        writers.base.writers[0].holdsCancel = true
        writers.holdsMixdowns = true
        let restarting = Task { await controller.restart() }
        #expect(await ScreencastWait.until { writers.base.writers[0].isHoldingCancel })
        captureSystem.videoStreams[0].handler.stopped(.stoppedByMacOS)
        #expect(await ScreencastWait.until { writers.isHoldingMixdown })
        #expect(await ScreencastWait.until { controller.phase == .finishing }, "Seen even while the restart waits")
        return restarting
    }

    @available(macOS 15, *)
    @Test("Stop while a restart deletes the old take and the recording ends on its own: the capture still arrives")
    func stopDuringRestartAndEarlyEnd() async throws {
        defer { captures.remove() }
        let writers = ScriptedWriters()
        let controller = makeController(countdown: 0, writers: writers)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        let restarting = try await endEarlyDuringRestart(controller, writers)

        // Stop waits for the early end's capture, so it runs on while the save is let go.
        let stopping = Task { await controller.stop() }
        for _ in 0..<50 { await Task.yield() }
        #expect(finished.isEmpty)
        writers.releaseMixdowns()
        writers.base.writers[0].releaseCancel()
        await stopping.value
        await restarting.value
        #expect(await ScreencastWait.until { controller.recorder.state != .stopping })

        #expect(finished.count == 1, "the early end's capture reaches onCaptureFinished")
        #expect(controller.phase == .idle)
        #expect(overlays.messages == ["macOS stopped the recording. What was recorded is saved."])
        #expect(await ScreencastWait.until { captures.captureFolders().count == 1 }, "Only the capture; the old take is gone")
    }

    @available(macOS 15, *)
    @Test("Discard while a restart deletes the old take and the recording ends on its own: nothing is kept")
    func discardDuringRestartAndEarlyEnd() async throws {
        defer { captures.remove() }
        let writers = ScriptedWriters()
        let controller = makeController(countdown: 0, writers: writers)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        let restarting = try await endEarlyDuringRestart(controller, writers)

        let discarding = Task { await controller.discard() }
        for _ in 0..<50 { await Task.yield() }
        writers.releaseMixdowns()
        writers.base.writers[0].releaseCancel()
        await discarding.value
        await restarting.value
        #expect(await ScreencastWait.until { controller.recorder.state != .stopping })

        #expect(finished.isEmpty && overlays.messages.isEmpty)
        #expect(controller.phase == .idle)
        #expect(await ScreencastWait.until { captures.captureFolders().isEmpty }, "discarded footage is deleted")
    }

    // MARK: Restarting with the screen cleared (round-3 review of #465)

    /// What comes while a restart waits for a frame of the cleared screen.
    enum SettleInterruption: String, CaseIterable, Sendable {
        case stop, discard, shutDown, endedEarly
    }

    /// Records one screen with a will-restart observer that cleared something, and starts a
    /// restart that's waiting out its settle. Returns the restart and the number of files the take
    /// had, which every restart makes again.
    @available(macOS 15, *)
    private func settlingRestart(
        _ controller: ScreencastController,
        observed: @escaping () -> Void = {}
    ) async throws -> (restarting: Task<Void, Never>, files: Int) {
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        let files = writers.writers.count
        controller.addWillRestartObserver {
            observed()
            return true
        }
        let restarting = Task { await controller.restart() }
        #expect(await ScreencastWait.until { sleeper.pending == 1 }, "the restart waits")
        return (restarting, files)
    }

    @available(macOS 15, *)
    @Test("A restart's settle is three frames at the recording's rate, and at least 0.1 s")
    func restartSettle() {
        #expect(ScreencastController.restartSettle(framesPerSecond: ScreencastOptions().framesPerSecond) == 0.1)
        #expect(ScreencastController.restartSettle(framesPerSecond: 60) == 0.1)
        #expect(ScreencastController.restartSettle(framesPerSecond: 24) == 0.125)
        #expect(ScreencastController.restartSettle(framesPerSecond: 0) == 3, "never a division by zero")
    }

    @available(macOS 15, *)
    @Test("A restart clears the screen, waits its settle, and only then restarts the recorder")
    func restartWaitsAfterClearing() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var events: [String] = []
        var filesAtClear: Int?
        let (restarting, files) = try await settlingRestart(controller) {
            events.append("cleared")
            filesAtClear = writers.writers.count
            #expect(sleeper.requested.isEmpty, "cleared before the settle")
        }
        #expect(events == ["cleared"])
        #expect(filesAtClear == files)
        #expect(sleeper.requested == [0.1])
        for _ in 0..<50 { await Task.yield() }
        #expect(writers.writers.count == files, "the recorder hasn't restarted during the settle")
        #expect(controller.phase == .recording)

        sleeper.advance()
        await restarting.value
        #expect(writers.writers.count == 2 * files, "then the new take's files")
        #expect(controller.phase == .recording && controller.recorder.state == .recording)
        #expect(events == ["cleared"])
        await controller.stop()
    }

    @available(macOS 15, *)
    @Test("With nothing cleared, a restart doesn't wait")
    func restartWithNothingCleared() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        let files = writers.writers.count
        var told = 0
        controller.addWillRestartObserver {
            told += 1
            return false
        }
        await controller.restart()
        #expect(told == 1)
        #expect(sleeper.requested.isEmpty)
        #expect(writers.writers.count == 2 * files)
        #expect(controller.phase == .recording)
        await controller.stop()
    }

    @available(macOS 15, *)
    @Test("A stop, discard, shutdown, or early end during a restart's settle wins, and nothing restarts", arguments: SettleInterruption.allCases)
    func interruptedSettle(_ interruption: SettleInterruption) async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        let (restarting, files) = try await settlingRestart(controller)

        switch interruption {
        case .stop:
            await controller.stop()
            #expect(finished.count == 1, "the old take is kept")
        case .discard:
            await controller.discard()
            #expect(finished.isEmpty)
        case .shutDown:
            await controller.shutDown()
            #expect(finished.isEmpty, "kept in the captures folder, and nothing opens")
            #expect(captures.captureFolders().count == 1)
        case .endedEarly:
            captureSystem.videoStreams[0].handler.stopped(.stoppedByMacOS)
            #expect(await ScreencastWait.until { finished.count == 1 })
            #expect(overlays.messages == ["macOS stopped the recording. What was recorded is saved."])
        }
        #expect(controller.phase == .idle)

        sleeper.advance()
        await restarting.value
        #expect(writers.writers.count == files, "the recorder never restarted")
        #expect(controller.phase == .idle)
        #expect(controller.recorder.state != .recording)
        if interruption != .endedEarly { #expect(overlays.messages.isEmpty) }
    }

    @available(macOS 15, *)
    @Test("A second restart during the settle is refused: the recording restarts once")
    func secondRestartDuringSettle() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        var told = 0
        let (first, files) = try await settlingRestart(controller) { told += 1 }

        await controller.restart()
        #expect(told == 1, "the second never cleared again")
        #expect(sleeper.requested.count == 1 && sleeper.pending == 1)
        #expect(writers.writers.count == files)

        sleeper.advance()
        await first.value
        #expect(writers.writers.count == 2 * files, "one restart")
        #expect(controller.phase == .recording)
        await controller.stop()
    }

    @available(macOS 15, *)
    @Test("A recording started after a stop during the settle isn't restarted by it")
    func newRecordingDuringSettle() async throws {
        defer { captures.remove() }
        let controller = makeController(countdown: 0)
        let (restarting, _) = try await settlingRestart(controller)
        await controller.stop()
        try await record(controller, .screen) { $0.clickScreen(PickerScreens.left) }
        #expect(await ScreencastWait.until { controller.phase == .recording })
        let files = writers.writers.count

        sleeper.advance()
        await restarting.value
        #expect(writers.writers.count == files, "the new recording keeps its take")
        #expect(controller.phase == .recording)
        await controller.stop()
    }

    // MARK: Getting ready

    @available(macOS 15, *)
    @Test("If reading the screen takes a moment, Getting ready… shows until the picker does")
    func gettingReady() async throws {
        defer { captures.remove() }
        pickerSystem.holdsContent = true
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.events.contains(.gettingReady) })
        #expect(!overlays.events.contains(.showPicker))
        pickerSystem.releaseContent()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        #expect(overlays.events == [.watchEscape, .gettingReady, .hideGettingReady, .showPicker])
    }

    @available(macOS 15, *)
    @Test("Escape while getting ready cancels, hides the cue, and the picker never shows")
    func escapeWhileGettingReady() async throws {
        defer { captures.remove() }
        pickerSystem.holdsContent = true
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.events.contains(.gettingReady) })
        overlays.pressEscape()
        #expect(controller.phase == .idle)
        #expect(overlays.events.contains(.hideGettingReady))
        pickerSystem.releaseContent()
        for _ in 0..<50 { await Task.yield() }
        #expect(!overlays.events.contains(.showPicker))
    }

    @available(macOS 15, *)
    @Test("A read that takes too long gives up: the cue hides, the message says why, and the picker never shows")
    func screenReadTimesOut() async throws {
        defer { captures.remove() }
        pickerSystem.holdsContent = true
        let controller = makeController(gettingReadyDelay: 0.01, screenReadTimeout: 0.1)
        controller.open()
        #expect(await ScreencastWait.until { !overlays.messages.isEmpty })
        #expect(controller.phase == .idle && controller.picker == nil)
        #expect(overlays.events == [
            .watchEscape, .gettingReady, .hideGettingReady, .closePicker, .stopWatchingEscape,
            .message(ScreencastMessages.text(for: .captureFailed)),
        ])
        pickerSystem.releaseContent()
        for _ in 0..<50 { await Task.yield() }
        #expect(!overlays.events.contains(.showPicker))
    }

    @available(macOS 15, *)
    @Test("A quick read never shows Getting ready…")
    func quickReadNoCue() async throws {
        defer { captures.remove() }
        let controller = makeController()
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        try await Task.sleep(for: .milliseconds(450))
        #expect(!overlays.events.contains(.gettingReady))
    }

    // MARK: Displays changing

    @available(macOS 15, *)
    @Test("A display unplugged while the picker is open closes it and says so; the next one offers only the screens left")
    func displayUnpluggedWhilePicking() async throws {
        defer { captures.remove() }
        var layout = PickerScreens.both
        let screenChanges = NotificationCenter()
        let controller = makeController(screens: { layout }, screenChanges: screenChanges)
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })

        layout = PickerScreens.leftOnly
        screenChanges.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(controller.picker == nil && overlays.picker == nil)
        #expect(!overlays.isWatchingEscape)
        #expect(overlays.messages == [ScreencastMessages.screensChanged])

        controller.open()
        let model = try #require(controller.picker)
        #expect(model.layout == PickerScreens.leftOnly)
        #expect(model.layout.orderedScreens.map(\.id) == [1] && !model.offersEveryScreen)
        #expect(model.selectedScreen == 1)
    }

    @available(macOS 15, *)
    @Test("A display change while the screen is read cancels, and the picker never shows")
    func displayChangeWhileReading() async throws {
        defer { captures.remove() }
        var layout = PickerScreens.both
        let screenChanges = NotificationCenter()
        pickerSystem.holdsContent = true
        let controller = makeController(screens: { layout }, screenChanges: screenChanges)
        controller.open()
        layout = PickerScreens.leftOnly
        screenChanges.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        pickerSystem.releaseContent()
        for _ in 0..<50 { await Task.yield() }
        #expect(!overlays.events.contains(.showPicker))
        #expect(overlays.messages == [ScreencastMessages.screensChanged])
    }

    @available(macOS 15, *)
    @Test("A screen notice that changes nothing leaves the picker open, and none is heard once it closes")
    func screenNoticeWithoutChange() async throws {
        defer { captures.remove() }
        var layout = PickerScreens.both
        let screenChanges = NotificationCenter()
        let controller = makeController(screens: { layout }, screenChanges: screenChanges)
        controller.open()
        #expect(await ScreencastWait.until { overlays.picker != nil })
        screenChanges.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .picking && overlays.picker != nil)

        overlays.pressEscape()
        layout = PickerScreens.leftOnly
        screenChanges.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(overlays.messages.isEmpty)
    }

    // MARK: Turning off

    @available(macOS 15, *)
    @Test("Turned off while recording, the recording stops and is kept, nothing opens, and it goes to onCaptureKept once")
    func shutDownWhileRecording() async throws {
        defer { captures.remove() }
        remember(rightArea)
        let controller = makeController(countdown: 0)
        var finished: [ScreencastCaptureResult] = []
        var kept: [ScreencastCaptureResult] = []
        controller.onCaptureFinished = { finished.append($0) }
        controller.onCaptureKept = { kept.append($0) }
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
        #expect(kept.map { ProductPaths.canonicalPath($0.folder) } == [ProductPaths.canonicalPath(folder)], "listed and copied from there (#605)")

        // Opened again, captures open as before.
        try await record(controller, .screen)
        #expect(await ScreencastWait.until { controller.phase == .recording })
        await controller.stop()
        #expect(finished.count == 1)
        #expect(kept.count == 1)
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

    // MARK: Messages and the unit-test host

    @Test("Every failure has a message, and one that ended early says whether it kept the footage")
    func messages() {
        for failure in [ScreencastFailure.screenRecordingDenied, .targetUnavailable, .captureFailed, .stoppedByMacOS, .writerFailed, .folderUnavailable, .noFootage] {
            #expect(!ScreencastMessages.text(for: failure).isEmpty)
            #expect(ScreencastMessages.endedEarly(failure, kept: true).hasSuffix("What was recorded is saved."))
            #expect(!ScreencastMessages.endedEarly(failure, kept: false).contains("saved"))
        }
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
