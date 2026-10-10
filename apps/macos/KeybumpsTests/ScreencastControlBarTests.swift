import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Keybumps

/// A recording the control bar drives, which keeps every call. Its phase moves as the capture
/// flow's does, so the bar can be seen following it.
@MainActor
@Observable
final class FakeBarRecording: ScreencastBarRecording {
    enum Call: Equatable {
        case pause, resume, restart, stop, discard
        case setAudio(ScreencastAudioSource, on: Bool)
    }

    var phase: ScreencastPhase = .recording
    var elapsed: TimeInterval = 0
    var microphone: ScreencastAudioSourceState = .on
    var systemAudio: ScreencastAudioSourceState = .on
    var microphoneLevel: Float = 0
    @ObservationIgnored private(set) var calls: [Call] = []
    /// `stop()` waits for `releaseStop()`, so a test sees the bar while it stops.
    @ObservationIgnored var holdsStop = false
    @ObservationIgnored private var heldStop: CheckedContinuation<Void, Never>?
    /// `restart()` waits for `releaseRestart()`, still recording, as the controller does while the
    /// recorder opens new files.
    @ObservationIgnored var holdsRestart = false
    @ObservationIgnored private var heldRestart: CheckedContinuation<Void, Never>?

    var isHoldingStop: Bool { heldStop != nil }
    var isHoldingRestart: Bool { heldRestart != nil }

    func pause() {
        calls.append(.pause)
        if phase == .recording { phase = .paused }
    }

    func resume() {
        calls.append(.resume)
        if phase == .paused { phase = .recording }
    }

    func setAudio(_ source: ScreencastAudioSource, on: Bool) {
        calls.append(.setAudio(source, on: on))
        switch (source, state(of: source)) {
        case (.microphone, .on), (.microphone, .off): microphone = on ? .on : .off
        case (.systemAudio, .on), (.systemAudio, .off): systemAudio = on ? .on : .off
        default: break
        }
    }

    func restart() async {
        calls.append(.restart)
        if holdsRestart { await withCheckedContinuation { heldRestart = $0 } }
        elapsed = 0
        phase = .recording
    }

    func releaseRestart() {
        heldRestart?.resume()
        heldRestart = nil
    }

    func stop() async {
        calls.append(.stop)
        phase = .finishing
        if holdsStop { await withCheckedContinuation { heldStop = $0 } }
        phase = .idle
    }

    func releaseStop() {
        heldStop?.resume()
        heldStop = nil
    }

    func discard() async {
        calls.append(.discard)
        phase = .finishing
        phase = .idle
    }
}

/// The capture flow for real, with the recorder's and picker's fakes and no countdown: a
/// recording of the left screen starts at once, captures nothing, and keeps made-up files.
@available(macOS 15, *)
@MainActor
struct ScreencastFlow {
    let captureSystem: FakeCaptureSystem
    let clock: FakeHostClock
    let captures: TemporaryCapturesFolder
    let overlays: FakeOverlays
    let controller: ScreencastController

    init(microphone: Bool = true, systemAudio: Bool = true) {
        let captureSystem = FakeCaptureSystem(content: ScreencastScreens.content())
        let clock = FakeHostClock()
        let captures = TemporaryCapturesFolder()
        let overlays = FakeOverlays()
        let startDate = Date(timeIntervalSince1970: 1_791_000_000)
        let recorder = ScreencastRecorder(
            system: captureSystem,
            writers: FakeWriterFactory(),
            hostClock: { clock.now },
            now: { startDate },
            ownProcessID: ScreencastScreens.ownProcess,
            microphoneGranted: { true },
            tickInterval: nil
        )
        let preferences = PickerScreens.preferences(microphone: microphone, systemAudio: systemAudio, countdown: 0, captures: captures.url)
        controller = ScreencastController(
            recorder: recorder,
            system: FakePickerSystem(content: ScreencastScreens.content()),
            presenter: overlays,
            areaMemory: ScreencastAreaMemory(defaults: InMemoryDefaults()),
            preferences: { preferences },
            screens: { PickerScreens.both },
            microphoneAvailable: { true },
            sleep: { _ in },
            now: { startDate },
            ownProcessID: ScreencastScreens.ownProcess
        )
        self.captureSystem = captureSystem
        self.clock = clock
        self.captures = captures
        self.overlays = overlays
    }

    /// Start Screencast, the left screen, Record: recording once this returns.
    func record() async throws {
        controller.open()
        let picker = try #require(controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        controller.confirm()
        #expect(await ScreencastWait.until { controller.phase == .recording })
    }
}

/// The control bar's model, driven through a fake recording, and through the capture flow (with
/// the recorder's and picker's fakes) where the two must agree. Nothing here shows a window, starts
/// a capture, or opens the microphone.
@MainActor
@Suite("Screencast: the control bar")
struct ScreencastControlBarTests {
    let recording = FakeBarRecording()

    func makeBar(confirmationTimeout: Duration = .seconds(60)) -> ScreencastControlBarModel {
        ScreencastControlBarModel(recording: recording, confirmationTimeout: confirmationTimeout)
    }

    /// Waits, a little at a time, until `condition` holds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Pause and the timer

    @Test("Pause pauses and becomes Resume; Resume resumes and becomes Pause")
    func pauseAndResume() {
        let bar = makeBar()
        #expect(bar.pauseTitle == "Pause" && bar.pauseSystemImage == "pause.fill" && bar.pauseHelp == "Pause recording")

        bar.togglePause()
        #expect(recording.calls == [.pause])
        #expect(bar.isPaused)
        #expect(bar.pauseTitle == "Resume" && bar.pauseSystemImage == "play.fill" && bar.pauseHelp == "Resume recording")

        bar.togglePause()
        #expect(recording.calls == [.pause, .resume])
        #expect(!bar.isPaused && bar.pauseTitle == "Pause")
    }

    @Test("The timer reads mm:ss, its minutes going past 59 rather than adding hours")
    func timerText() {
        let cases: [(TimeInterval, String)] = [
            (0, "00:00"), (0.9, "00:00"), (5, "00:05"), (65.9, "01:05"), (599, "09:59"),
            (3_600, "60:00"), (6_000, "100:00"), (-3, "00:00"), (.nan, "00:00"), (.infinity, "00:00"),
        ]
        for (elapsed, text) in cases {
            #expect(ScreencastControlBarModel.timerText(elapsed) == text, "\(elapsed)")
        }
        recording.elapsed = 125
        #expect(makeBar().timerText == "02:05")
    }

    @Test("VoiceOver reads the timer in words, and says when it's paused")
    func timerAccessibility() {
        let bar = makeBar()
        recording.elapsed = 65.7
        #expect(bar.timerAccessibilityValue == "1 minute, 5 seconds")
        #expect(bar.spokenTime == "Screencast recording, 1 minute, 5 seconds")
        recording.phase = .paused
        #expect(bar.timerAccessibilityValue == "1 minute, 5 seconds, paused")
    }

    @available(macOS 15, *)
    @Test("Through the capture flow, the timer holds still while paused and goes on from there")
    func timerHoldsWhilePaused() async throws {
        let flow = ScreencastFlow()
        defer { flow.captures.remove() }
        try await flow.record()
        let bar = ScreencastControlBarModel(recording: flow.controller)

        flow.clock.advance(65)
        flow.controller.recorder.tick()
        #expect(bar.timerText == "01:05")

        bar.togglePause()
        #expect(flow.controller.phase == .paused && flow.controller.recorder.state == .paused)
        #expect(bar.pauseTitle == "Resume")
        flow.clock.advance(30)
        flow.controller.recorder.refreshElapsed()
        #expect(bar.timerText == "01:05")

        bar.togglePause()
        #expect(flow.controller.phase == .recording && bar.pauseTitle == "Pause")
        flow.clock.advance(3)
        flow.controller.recorder.tick()
        #expect(bar.timerText == "01:08")
        await flow.controller.discard()
    }

    // MARK: Sound

    @Test("The microphone and the Mac's sound mute and unmute")
    func audioSwitches() {
        let bar = makeBar()
        #expect(bar.audioButton(for: .microphone) == ScreencastBarAudioButton(
            systemImage: "mic.fill", label: "Microphone", value: "On",
            help: "Mute the microphone", isEnabled: true, isWarning: false
        ))
        #expect(bar.audioButton(for: .systemAudio) == ScreencastBarAudioButton(
            systemImage: "speaker.wave.2.fill", label: "Mac’s sound", value: "On",
            help: "Mute the Mac’s sound in the recording", isEnabled: true, isWarning: false
        ))

        bar.toggleAudio(.microphone)
        bar.toggleAudio(.systemAudio)
        #expect(recording.calls == [.setAudio(.microphone, on: false), .setAudio(.systemAudio, on: false)])
        #expect(bar.audioButton(for: .microphone).systemImage == "mic.slash.fill")
        #expect(bar.audioButton(for: .microphone).value == "Off")
        #expect(bar.audioButton(for: .microphone).help == "Unmute the microphone")
        #expect(bar.audioButton(for: .systemAudio).systemImage == "speaker.slash.fill")
        #expect(bar.audioButton(for: .systemAudio).help == "Unmute the Mac’s sound in the recording")

        bar.toggleAudio(.microphone)
        #expect(recording.calls.last == .setAudio(.microphone, on: true))
        #expect(recording.microphone == .on)
    }

    @Test("A sound that was off when recording started shows off, can't be switched on, and says to turn it on before recording")
    func notRecordedSoundsStayOff() {
        recording.microphone = .notRecorded
        recording.systemAudio = .notRecorded
        let bar = makeBar()
        for source in ScreencastAudioSource.allCases {
            let button = bar.audioButton(for: source)
            #expect(!button.isEnabled)
            #expect(button.value == "Not recorded")
            #expect(button.systemImage.hasSuffix(".slash"))
            #expect(button.help.hasSuffix("Turn it on before you start recording."))
            bar.toggleAudio(source)
        }
        #expect(bar.audioButton(for: .microphone).help == "The microphone isn’t in this recording. Turn it on before you start recording.")
        #expect(bar.audioButton(for: .systemAudio).help == "The Mac’s sound isn’t in this recording. Turn it on before you start recording.")
        #expect(recording.calls.isEmpty)
        #expect(recording.microphone == .notRecorded && recording.systemAudio == .notRecorded)
    }

    @available(macOS 15, *)
    @Test("Through the capture flow, a sound left off at the start stays off when its button is clicked")
    func notRecordedThroughTheFlow() async throws {
        let flow = ScreencastFlow(systemAudio: false)
        defer { flow.captures.remove() }
        try await flow.record()
        let bar = ScreencastControlBarModel(recording: flow.controller)

        #expect(!bar.audioButton(for: .systemAudio).isEnabled)
        bar.toggleAudio(.systemAudio)
        #expect(flow.controller.recorder.systemAudio == .notRecorded)
        bar.toggleAudio(.microphone)
        #expect(flow.controller.recorder.microphone == .off)
        #expect(bar.audioButton(for: .microphone).value == "Off")
        await flow.controller.discard()
    }

    @Test("A sound that stopped working can't be switched, and says so in orange")
    func failedSounds() {
        recording.microphone = .failed
        recording.systemAudio = .failed
        let bar = makeBar()
        #expect(bar.audioButton(for: .microphone) == ScreencastBarAudioButton(
            systemImage: "mic.slash", label: "Microphone", value: "Stopped working",
            help: "The microphone stopped working. The recording goes on without it.", isEnabled: false, isWarning: true
        ))
        #expect(bar.audioButton(for: .systemAudio).help == "The Mac’s sound stopped working. The recording goes on without it.")
        bar.toggleAudio(.microphone)
        bar.toggleAudio(.systemAudio)
        #expect(recording.calls.isEmpty)
    }

    @Test("The microphone's level shows only while it's on: within 0…1, resting just above 0, flat while paused")
    func microphoneMeter() {
        let floor = ScreencastControlBarModel.meterFloor
        func level(_ microphone: ScreencastAudioSourceState, _ phase: ScreencastPhase, _ level: Float) -> Double? {
            ScreencastControlBarModel.meterLevel(microphone: microphone, phase: phase, level: level)
        }
        #expect(level(.on, .recording, 0.5) == 0.5)
        #expect(level(.on, .recording, 0) == floor)
        #expect(level(.on, .recording, 0.01) == floor)
        #expect(level(.on, .recording, 1.7) == 1)
        #expect(level(.on, .recording, -1) == floor)
        #expect(level(.on, .recording, .nan) == floor)
        #expect(level(.on, .paused, 0.8) == 0)
        #expect(level(.on, .finishing, 0.8) == 0)
        for microphone in [ScreencastAudioSourceState.off, .notRecorded, .failed] {
            #expect(level(microphone, .recording, 0.8) == nil)
        }

        let bar = makeBar()
        recording.microphoneLevel = 0.3
        #expect(bar.microphoneMeter.map { abs($0 - 0.3) < 0.0001 } == true)
        bar.toggleAudio(.microphone)
        #expect(bar.microphoneMeter == nil)
    }

    // MARK: Stop

    @Test("Stop stops through the flow")
    func stop() async {
        let bar = makeBar()
        bar.askToDiscard()
        await bar.stop()
        #expect(recording.calls == [.stop])
        #expect(bar.question == nil, "Stop takes a question away")
        #expect(!bar.acceptsActions && !bar.isWorking)
    }

    @available(macOS 15, *)
    @Test("Through the capture flow, Stop hands the saved capture on, and Discard keeps nothing")
    func stopAndDiscardThroughTheFlow() async throws {
        let flow = ScreencastFlow()
        defer { flow.captures.remove() }
        var finished: [ScreencastCaptureResult] = []
        flow.controller.onCaptureFinished = { finished.append($0) }

        try await flow.record()
        let bar = ScreencastControlBarModel(recording: flow.controller)
        flow.clock.advance(5)
        await bar.stop()
        #expect(flow.controller.phase == .idle && !bar.acceptsActions)
        guard case .video(let capture) = try #require(finished.first) else {
            Issue.record("Stopped with \(finished)")
            return
        }
        #expect(capture.folder.deletingLastPathComponent() == flow.captures.url)

        try await flow.record()
        bar.askToDiscard()
        await bar.confirm()
        #expect(flow.controller.phase == .idle)
        #expect(finished.count == 1, "A discarded recording goes to no review")
        #expect(flow.captures.captureFolders().count == 1, "Only the stopped one is kept")
    }

    @Test("While Stop finishes, every button waits")
    func buttonsWaitWhileStopping() async {
        recording.holdsStop = true
        let bar = makeBar()
        let stopping = Task { await bar.stop() }
        #expect(await eventually { recording.isHoldingStop })
        #expect(bar.isWorking && !bar.acceptsActions)

        bar.togglePause()
        bar.toggleAudio(.microphone)
        bar.askToDiscard()
        bar.askToRestart()
        await bar.stop()
        #expect(recording.calls == [.stop])
        #expect(bar.question == nil)

        recording.releaseStop()
        await stopping.value
        #expect(!bar.isWorking)
    }

    @Test("While Restart opens new files, still recording, every other action waits")
    func everythingWaitsForRestart() async {
        recording.holdsRestart = true
        let bar = makeBar()
        var drew = false
        bar.onToggleDrawing = { drew = true }
        bar.askToRestart()
        let restarting = Task { await bar.confirm() }
        #expect(await eventually { recording.isHoldingRestart })
        #expect(recording.phase == .recording, "The flow is still recording")
        #expect(bar.isWorking && !bar.acceptsActions)

        bar.togglePause()
        bar.toggleAudio(.microphone)
        bar.toggleAudio(.systemAudio)
        bar.toggleDrawing()
        bar.askToDiscard()
        bar.askToRestart()
        await bar.discardFromShortcut()
        await bar.confirm()
        await bar.stop()
        #expect(recording.calls == [.restart], "Only the one restart")
        #expect(!drew && bar.question == nil)

        recording.releaseRestart()
        await restarting.value
        #expect(!bar.isWorking && bar.acceptsActions)
        bar.togglePause()
        #expect(recording.calls == [.restart, .pause], "The buttons work again")
    }

    @Test("Before recording, and once it ends, the buttons do nothing")
    func outsideARecording() async {
        let bar = makeBar()
        var drew = false
        bar.onToggleDrawing = { drew = true }
        for phase in [ScreencastPhase.idle, .picking, .countingDown(remaining: 3), .starting, .finishing] {
            recording.phase = phase
            #expect(!bar.acceptsActions)
            bar.togglePause()
            bar.toggleAudio(.microphone)
            bar.toggleDrawing()
            bar.askToDiscard()
            bar.askToRestart()
            await bar.confirm()
            await bar.stop()
        }
        #expect(recording.calls.isEmpty)
        #expect(!drew && bar.question == nil)
    }

    // MARK: Discard and Restart ask first

    @Test("Discard asks first, in the bar; Keep goes back with the recording untouched")
    func discardThenKeep() {
        let bar = makeBar()
        bar.askToDiscard()
        #expect(bar.question == .discard)
        #expect(bar.question?.prompt == "Discard?" && bar.question?.confirmTitle == "Discard")
        #expect(recording.calls.isEmpty && recording.phase == .recording)

        bar.keep()
        #expect(bar.question == nil)
        #expect(recording.calls.isEmpty && recording.phase == .recording)
    }

    @Test("Discard, answering Discard?, discards through the flow")
    func discardConfirmed() async {
        let bar = makeBar()
        await bar.confirm()
        #expect(recording.calls.isEmpty, "Nothing is discarded without the question")

        bar.askToDiscard()
        await bar.confirm()
        #expect(recording.calls == [.discard])
        #expect(bar.question == nil && !bar.isWorking)
    }

    @Test("Restart asks first too; Keep keeps the take, and Restart starts over")
    func restartAsksFirst() async {
        let bar = makeBar()
        recording.elapsed = 40
        bar.askToRestart()
        #expect(bar.question == .restart)
        #expect(bar.question?.prompt == "Restart?" && bar.question?.confirmTitle == "Restart")
        #expect(recording.calls.isEmpty)

        bar.keep()
        #expect(bar.question == nil && recording.calls.isEmpty && bar.timerText == "00:40")

        bar.askToRestart()
        await bar.confirm()
        #expect(recording.calls == [.restart])
        #expect(bar.timerText == "00:00" && bar.question == nil)
    }

    @Test("A question asked over another replaces it")
    func oneQuestionAtATime() async {
        let bar = makeBar()
        bar.askToDiscard()
        bar.askToRestart()
        #expect(bar.question == .restart)
        await bar.confirm()
        #expect(recording.calls == [.restart], "Never both")
    }

    @Test("The Discard shortcut asks, and discards when pressed again while it asks")
    func discardShortcut() async {
        let bar = makeBar()
        await bar.discardFromShortcut()
        #expect(bar.question == .discard && recording.calls.isEmpty)
        await bar.discardFromShortcut()
        #expect(recording.calls == [.discard])

        recording.phase = .recording
        bar.askToRestart()
        await bar.discardFromShortcut()
        #expect(bar.question == .discard, "Restart? gives way to Discard?")
        #expect(recording.calls == [.discard])
        bar.keep()
    }

    @Test("A question goes back to the controls after a while without an answer, and changes nothing")
    func questionTimesOut() async {
        let bar = makeBar(confirmationTimeout: .milliseconds(10))
        bar.askToDiscard()
        #expect(bar.question == .discard)
        #expect(await eventually { bar.question == nil })
        bar.askToRestart()
        #expect(await eventually { bar.question == nil })
        #expect(recording.calls.isEmpty)
        await bar.confirm()
        #expect(recording.calls.isEmpty)
    }

    @Test("A question waits for its answer until the timeout, and asked again gets its full wait")
    func questionWaits() async {
        let bar = makeBar(confirmationTimeout: .milliseconds(200))
        bar.askToDiscard()
        bar.keep()
        bar.askToDiscard()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(bar.question == .discard)
        bar.keep()
    }

    // MARK: Draw

    @Test("Draw shows only when something supplies drawing, and toggles it")
    func draw() {
        let bar = makeBar()
        #expect(!bar.showsDrawButton)
        bar.toggleDrawing()

        var toggles = 0
        bar.onToggleDrawing = { toggles += 1 }
        #expect(bar.showsDrawButton)
        #expect(bar.drawSystemImage == "pencil.tip.crop.circle" && bar.drawHelp == "Draw on the screen")
        bar.toggleDrawing()
        #expect(toggles == 1)
        bar.isDrawing = true
        #expect(bar.drawSystemImage == "pencil.tip.crop.circle.fill" && bar.drawHelp == "Stop drawing")
    }

    // MARK: What the bar draws

    @Test("Every symbol the bar and its menu items draw is one macOS has")
    func symbolsExist() {
        let bar = makeBar()
        bar.isDrawing = true
        var names = ["pause.fill", "play.fill", "pencil.tip.crop.circle", bar.drawSystemImage,
                     "arrow.counterclockwise", "trash", "line.3.horizontal"]
        for source in ScreencastAudioSource.allCases {
            for state in [ScreencastAudioSourceState.on, .off, .notRecorded, .failed] {
                names.append(ScreencastControlBarModel.audioButton(for: source, state: state).systemImage)
            }
        }
        names += ScreencastRecordingControls.menuItems(for: bar).compactMap(\.systemImage)
        recording.phase = .paused
        names += ScreencastRecordingControls.menuItems(for: bar).compactMap(\.systemImage)
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test("Each control's accessibility identifier is its own, under screencast.bar")
    func identifiers() {
        let identifiers = [
            ScreencastControlBarID.timer, ScreencastControlBarID.pause, ScreencastControlBarID.draw,
            ScreencastControlBarID.microphone, ScreencastControlBarID.systemAudio, ScreencastControlBarID.restart,
            ScreencastControlBarID.discard, ScreencastControlBarID.stop, ScreencastControlBarID.confirmDiscard,
            ScreencastControlBarID.confirmRestart, ScreencastControlBarID.keep, ScreencastControlBarID.question,
        ]
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.hasPrefix("screencast.bar.") })
        #expect(ScreencastControlBarID.audio(.microphone) == "screencast.bar.microphone")
        #expect(ScreencastControlBarID.audio(.systemAudio) == "screencast.bar.systemAudio")
        #expect(ScreencastControlBarID.confirm(.discard) == "screencast.bar.confirmDiscard")
        #expect(ScreencastControlBarID.confirm(.restart) == "screencast.bar.confirmRestart")
    }
}

// MARK: - While recording: the bar, the menu bar, and the shortcuts

/// Hot keys that never reach macOS: it keeps what's registered, and `press` runs a binding's
/// handler as macOS would.
@MainActor
final class PressableHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private(set) var registered: [UInt32: ShortcutBinding] = [:]
    private var handler: ((UInt32) -> Void)?

    func installHandler(_ handler: @escaping (UInt32) -> Void) {
        self.handler = handler
    }

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        registered[identifier] = binding
        return true
    }

    func unregister(identifier: UInt32) {
        registered[identifier] = nil
    }

    func press(_ binding: ShortcutBinding) {
        guard let identifier = registered.first(where: { $0.value == binding })?.key else { return }
        handler?(identifier)
    }
}

@MainActor
@Suite("Screencast: while recording")
struct ScreencastRecordingControlsTests {
    static let laptop = ScreencastControlBarPlacementTests.laptop
    /// The left half of the laptop, recorded as an area.
    static let area = CGRect(x: 0, y: 70, width: 756, height: 500)

    let recording = FakeBarRecording()
    let defaults = InMemoryDefaults()
    let status = MenuBarStatus()
    let hotKeys = PressableHotKeys()

    func makeControls() -> ScreencastRecordingControls {
        ScreencastRecordingControls(
            menuBar: CapabilityMenuBarStatus(status: status, capability: .screencast),
            placement: ScreencastControlBarPlacement(defaults: defaults),
            barDisplay: { _ in Self.laptop },
            ordersPanelIn: false
        )
    }

    func attach(_ controls: ScreencastRecordingControls, area: CGRect? = nil) {
        controls.attach(
            to: recording,
            regions: { [ScreencastChoice.Region(display: 1, frame: Self.laptop.visibleFrame)] },
            area: { area }
        )
    }

    /// Binds every recording shortcut, and gives the controls Screencast's context.
    func apply(_ controls: ScreencastRecordingControls, enabled: Bool = true) -> [CapabilityShortcut: ShortcutBinding] {
        let preferences = AppPreferences(defaults: defaults)
        var bindings: [CapabilityShortcut: ShortcutBinding] = [:]
        for (index, shortcut) in ScreencastRecordingControls.shortcuts.enumerated() {
            let binding = ShortcutBinding(keyCode: UInt32(index), modifiers: UInt32(256 | 512), displayName: "⇧⌘\(index)")
            _ = preferences.setCapabilityShortcut(binding, for: shortcut)
            bindings[shortcut] = binding
        }
        controls.apply(CapabilityContext(
            enabledCapabilities: enabled ? [.screencast] : [],
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: hotKeys),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
        return bindings
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("The bar shows on the recorded screen while recording or paused, above the area, and goes when it ends")
    func barFollowsThePhase() throws {
        recording.phase = .idle
        let controls = makeControls()
        attach(controls, area: Self.area)
        let bar = try #require(controls.bar)
        #expect(!bar.isShown)

        for phase in [ScreencastPhase.picking, .countingDown(remaining: 1)] {
            recording.phase = phase
            controls.phaseChanged(phase)
            #expect(!bar.isShown, "\(phase)")
        }
        // Up as the recording starts, before the recorder reads what to leave out, with its
        // buttons waiting.
        recording.phase = .starting
        controls.phaseChanged(.starting)
        #expect(bar.isShown && !bar.model.acceptsActions)
        #expect(status.title == nil, "The menu bar waits for the recording")
        recording.phase = .recording
        controls.phaseChanged(.recording)
        #expect(bar.isShown && bar.model.acceptsActions)
        #expect(bar.panel.frame.minY == Self.area.maxY + ScreencastControlBarPlacement.margin, "Above the area")
        #expect(abs(bar.panel.frame.midX - Self.laptop.visibleFrame.midX) < 1)

        recording.phase = .paused
        controls.phaseChanged(.paused)
        #expect(bar.isShown)
        recording.phase = .finishing
        controls.phaseChanged(.finishing)
        #expect(!bar.isShown)
    }

    @Test("The menu bar shows the time with Stop and Pause, follows the recording, and clears when it ends")
    func menuBar() async throws {
        recording.elapsed = 65
        let controls = makeControls()
        attach(controls)
        #expect(status.title == "01:05")
        #expect(status.spokenTitle == "Screencast recording, 1 minute, 5 seconds")
        #expect(status.sections.map { $0.map(\.title) } == [["Stop Recording", "Pause Recording"]])

        recording.elapsed = 66
        #expect(await eventually { status.title == "01:06" }, "It follows the time")

        let pause = try #require(status.sections.first?.last)
        pause.action()
        #expect(recording.calls == [.pause])
        #expect(await eventually { status.sections.first?.last?.title == "Resume Recording" })
        #expect(status.spokenTitle?.hasSuffix("paused") == true)

        let stop = try #require(status.sections.first?.first)
        stop.action()
        #expect(await eventually { recording.calls.last == .stop })
        controls.phaseChanged(recording.phase)
        #expect(await eventually { status.title == nil && status.sections.isEmpty })
    }

    @Test("The recording shortcuts work only while recording, and act as the bar's buttons do")
    func shortcuts() async throws {
        recording.phase = .idle
        let controls = makeControls()
        attach(controls)
        let bindings = apply(controls)
        #expect(hotKeys.registered.isEmpty, "Their keys work normally until a recording starts")

        recording.phase = .recording
        controls.phaseChanged(.recording)
        #expect(Set(hotKeys.registered.values) == Set(bindings.values))

        hotKeys.press(try #require(bindings[.screencastPause]))
        #expect(recording.calls == [.pause])
        var drew = 0
        controls.bar?.onToggleDrawing = { drew += 1 }
        hotKeys.press(try #require(bindings[.screencastDraw]))
        #expect(drew == 1)
        hotKeys.press(try #require(bindings[.screencastDiscard]))
        #expect(await eventually { controls.bar?.model.question == .discard })
        #expect(recording.calls == [.pause], "Discard asks first")
        hotKeys.press(try #require(bindings[.screencastDiscard]))
        #expect(await eventually { recording.calls.last == .discard })

        controls.phaseChanged(recording.phase)
        #expect(hotKeys.registered.isEmpty, "Gone once it ends")

        recording.phase = .recording
        controls.phaseChanged(.recording)
        hotKeys.press(try #require(bindings[.screencastStop]))
        #expect(await eventually { recording.calls.last == .stop })

        recording.phase = .recording
        controls.phaseChanged(.recording)
        #expect(!hotKeys.registered.isEmpty)
        controls.deactivate()
        #expect(hotKeys.registered.isEmpty, "Turning Screencast off takes them away")
    }

    @Test("While Screencast is off, the recording shortcuts never register")
    func shortcutsWhileOff() {
        let controls = makeControls()
        attach(controls)
        _ = apply(controls, enabled: false)
        controls.phaseChanged(.recording)
        #expect(hotKeys.registered.isEmpty)
    }

    @Test("The recording shortcuts are Screencast's, unassigned, say when they work, and Draw waits for drawing")
    func shortcutCases() {
        for shortcut in ScreencastRecordingControls.shortcuts {
            #expect(shortcut.capability == .screencast)
            #expect(shortcut.defaultBinding == nil)
            #expect(!shortcut.worksEverywhere)
            #expect(shortcut.detail?.hasPrefix("Only while Screencast is recording") == true)
        }
        #expect(ScreencastRecordingControls.shortcuts.map(\.title) == [
            "Pause & Resume Recording", "Stop Recording", "Discard Recording", "Draw While Recording",
        ])
        #expect(CapabilityDescriptor.screencast.shortcuts == [.screencast, .screencastPause, .screencastStop, .screencastDiscard])
        #expect(!CapabilityShortcut.screencastDraw.isListed)
    }

    @available(macOS 15, *)
    @Test("Attached to the capture flow, the controls follow its recording, whatever watches its phase before or after them")
    func throughTheFlow() async throws {
        let flow = ScreencastFlow()
        defer { flow.captures.remove() }
        var before: [ScreencastPhase] = []
        flow.controller.addPhaseObserver { before.append($0) }
        var finished = 0
        flow.controller.onCaptureFinished = { _ in finished += 1 }
        let controls = makeControls()
        controls.attach(to: flow.controller)
        // Added after the controls, as the overlays and the review panel may be.
        var after: [ScreencastPhase] = []
        flow.controller.addPhaseObserver { after.append($0) }
        flow.controller.onPhaseChange = { _ in }
        let bar = try #require(controls.bar)
        #expect(!bar.isShown && status.title == nil)

        try await flow.record()
        #expect(bar.isShown)
        #expect(status.title == "00:00")
        #expect(before.contains(.recording) && after.contains(.recording), "Every observer hears")

        await bar.model.stop()
        #expect(!bar.isShown && finished == 1)
        #expect(await eventually { status.title == nil })
        #expect(before.last == .idle && after.last == .idle)
    }

    @available(macOS 15, *)
    @Test("Through Screencast's module, the bar, the menu bar, and the shortcuts follow a recording, with another phase observer added after them")
    func throughTheModule() async throws {
        let preferences = AppPreferences(defaults: defaults)
        preferences.set(.choice("0"), of: .screencastCountdown, for: .screencast)
        let pause = ShortcutBinding(keyCode: 35, modifiers: UInt32(256 | 512), displayName: "⇧⌘P")
        _ = preferences.setCapabilityShortcut(pause, for: .screencastPause)
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            menuBar: CapabilityMenuBarStatus(status: status, capability: .screencast),
            seams: ScreencastSeams(
                captureSystem: FakeCaptureSystem(content: ScreencastScreens.content()),
                pickerSystem: FakePickerSystem(content: ScreencastScreens.content()),
                presenter: FakeOverlays(),
                screens: { PickerScreens.both },
                sleep: { _ in },
                revealCapture: { _ in }
            )
        )
        module.apply(CapabilityContext(
            enabledCapabilities: [.screencast],
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: hotKeys),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))

        module.start()
        let controller = try #require(module.controller)
        // What the overlays or the review panel do once the module has made its controller.
        var heard: [ScreencastPhase] = []
        controller.addPhaseObserver { heard.append($0) }
        controller.onPhaseChange = { _ in }

        let picker = try #require(controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        controller.confirm()
        #expect(await ScreencastWait.until { controller.phase == .recording })
        let bar = try #require(module.recordingControls.bar)
        #expect(bar.isShown && heard.contains(.recording))
        #expect(status.title == "00:00")
        #expect(hotKeys.registered.values.contains(pause))

        hotKeys.press(pause)
        #expect(controller.phase == .paused)
        #expect(await ScreencastWait.until { status.sections.first?.last?.title == "Resume Recording" })

        await controller.discard()
        #expect(!bar.isShown && hotKeys.registered.isEmpty)
        #expect(await ScreencastWait.until { status.title == nil })
    }

    @available(macOS 15, *)
    @Test("The controller tells its phase observers in the order added, after onPhaseChange, until one is removed")
    func phaseObservers() {
        let flow = ScreencastFlow()
        defer { flow.captures.remove() }
        var heard: [String] = []
        flow.controller.onPhaseChange = { heard.append("handler \($0)") }
        let first = flow.controller.addPhaseObserver { heard.append("first \($0)") }
        flow.controller.addPhaseObserver { heard.append("second \($0)") }

        flow.controller.open()
        #expect(heard == ["handler picking", "first picking", "second picking"])
        flow.controller.removePhaseObserver(first)
        flow.controller.cancel()
        #expect(Array(heard.dropFirst(3)) == ["handler idle", "second idle"])
    }

    @Test("While recording, Screencast's time and items come before Timer's in the menu bar")
    func menuBarPrecedence() async throws {
        let timer = CapabilityMenuBarStatus(status: status, capability: .timer)
        let timerItem = MenuBarItem(id: "tea", title: "Tea — 4:00", systemImage: "timer") {}
        timer.set(title: "4:00", spoken: "Tea, 4 minutes left", items: [timerItem])
        #expect(status.title == "4:00")

        recording.elapsed = 7
        let controls = makeControls()
        attach(controls)
        #expect(status.title == "00:07", "The recording's time, not the timer's")
        #expect(status.spokenTitle == "Screencast recording, 7 seconds")
        #expect(status.sections.map { $0.map(\.title) } == [["Stop Recording", "Pause Recording"], ["Tea — 4:00"]])

        recording.phase = .finishing
        controls.phaseChanged(.finishing)
        #expect(await eventually { status.title == "4:00" }, "The timer's again once it ends")
        #expect(status.sections.map { $0.map(\.title) } == [["Tea — 4:00"]])
    }
}

// MARK: - Where the bar sits

@MainActor
@Suite("Screencast: where the control bar sits")
struct ScreencastControlBarPlacementTests {
    /// A laptop with the Dock along the bottom, and a display to its right with none.
    static let laptop = ScreencastBarDisplay(key: "laptop", visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874))
    static let external = ScreencastBarDisplay(key: "external", visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
    static let size = CGSize(width: 360, height: 42)

    let defaults = InMemoryDefaults()
    var placement: ScreencastControlBarPlacement { ScreencastControlBarPlacement(defaults: defaults) }

    @Test("With nothing remembered, the bar sits centered near the bottom of the display, above the Dock")
    func defaultSpot() {
        let origin = placement.origin(for: Self.size, on: Self.laptop)
        #expect(origin == CGPoint(x: 756 - 180, y: 70 + ScreencastControlBarPlacement.bottomInset))
        #expect(placement.origin(for: Self.size, on: Self.external) == CGPoint(
            x: 1512 + 960 - 180, y: ScreencastControlBarPlacement.bottomInset
        ))
    }

    @Test("The default spot clears the newest line of keys a recording shows at the bottom centre, at their largest")
    func clearsTheKeys() {
        // The newest line at Large, with keycaps and an action's name, or as KeyCastr's bezel. The
        // older lines above it are smaller and fade quickly, so they may pass over the bar.
        let metrics = KeystrokeMetrics(.large)
        let entry = KeystrokeTimeline.Entry(
            id: 1, keycaps: ["⇧", "⌘", "4"], text: "⇧⌘4", name: "Screenshot Area", isTyping: false, lastPress: Date()
        )
        func height(_ line: KeystrokeLine) -> CGFloat { NSHostingView(rootView: line).fittingSize.height }
        let keycaps = height(KeystrokeLine(entry: entry, style: .keycaps, metrics: metrics))
        let bezel = height(KeystrokeLine(entry: entry, style: .bezel, metrics: metrics))
        let newest = KeyDisplayOverlayView.margin + max(keycaps, bezel)
        #expect(keycaps > 80, "Measured: \(keycaps)")
        #expect(ScreencastControlBarPlacement.bottomInset >= newest + 12, "The newest line reaches \(newest) above the bottom")
        #expect(ScreencastControlBarPlacement.bottomInset <= newest + 30, "Not much higher than it must")
    }

    @Test("The default spot moves above an area being recorded, when there's room")
    func avoidsTheArea() {
        let margin = ScreencastControlBarPlacement.margin
        // An area reaching down to the Dock: the bar goes just above it, still centered.
        let bottom = CGRect(x: 400, y: 70, width: 700, height: 400)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: bottom) == CGPoint(x: 576, y: 470 + margin))
        // One just reaching the default spot moves it too.
        let low = CGRect(x: 400, y: 130, width: 700, height: 310)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: low).y == 440 + margin)
        // One that stays below it doesn't.
        let short = CGRect(x: 400, y: 70, width: 700, height: 150)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: short) == placement.origin(for: Self.size, on: Self.laptop))
        // One reaching nearly to the top leaves no room above: the bar stays put.
        let tall = CGRect(x: 400, y: 70, width: 700, height: 850)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: tall) == placement.origin(for: Self.size, on: Self.laptop))
        // An area elsewhere doesn't move it.
        let corner = CGRect(x: 0, y: 600, width: 300, height: 300)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: corner) == placement.origin(for: Self.size, on: Self.laptop))
        // The whole screen leaves no room: it stays put, since it's never in the video.
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: Self.laptop.visibleFrame) == placement.origin(for: Self.size, on: Self.laptop))
    }

    @Test("Where the bar was left is remembered for each display, and a spot the person chose isn't moved off an area")
    func rememberedPerDisplay() {
        placement.remember(CGPoint(x: 100, y: 800), on: Self.laptop)
        #expect(placement.origin(for: Self.size, on: Self.laptop) == CGPoint(x: 100, y: 800))
        #expect(placement.origin(for: Self.size, on: Self.external) == placement.origin(for: Self.size, on: Self.external, avoiding: nil))
        #expect(placement.storedOffset(on: Self.external) == nil)

        placement.remember(CGPoint(x: 3000, y: 40), on: Self.external)
        #expect(placement.origin(for: Self.size, on: Self.external) == CGPoint(x: 3000, y: 40))
        #expect(placement.origin(for: Self.size, on: Self.laptop) == CGPoint(x: 100, y: 800), "Each display keeps its own")
        let area = CGRect(x: 50, y: 700, width: 600, height: 200)
        #expect(placement.origin(for: Self.size, on: Self.laptop, avoiding: area) == CGPoint(x: 100, y: 800))
    }

    @Test("A remembered spot is kept relative to its display, so it follows the display when they're rearranged")
    func followsTheDisplay() {
        placement.remember(CGPoint(x: 1600, y: 900), on: Self.external)
        #expect(placement.storedOffset(on: Self.external) == CGPoint(x: 88, y: 900))
        let movedLeft = ScreencastBarDisplay(key: "external", visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        #expect(placement.origin(for: Self.size, on: movedLeft) == CGPoint(x: -1832, y: 900))
    }

    @Test("A remembered spot is kept inside the visible frame, which may have shrunk since")
    func clampsToTheVisibleFrame() {
        placement.remember(CGPoint(x: 3300, y: 1040), on: Self.external)
        let origin = placement.origin(for: Self.size, on: Self.external)
        #expect(origin == CGPoint(x: 1512 + 1920 - 360, y: 1055 - 42))

        // Left over the Dock (a borderless panel can be dragged there): brought up above it.
        placement.remember(CGPoint(x: 600, y: 10), on: Self.laptop)
        #expect(placement.origin(for: Self.size, on: Self.laptop) == CGPoint(x: 600, y: 70))

        // The Dock grew on the laptop: a bar left just above it stays just above it.
        placement.remember(CGPoint(x: 600, y: 72), on: Self.laptop)
        let biggerDock = ScreencastBarDisplay(key: "laptop", visibleFrame: CGRect(x: 0, y: 120, width: 1512, height: 824))
        #expect(placement.origin(for: Self.size, on: biggerDock) == CGPoint(x: 600, y: 122))

        // The display is smaller now (a lower resolution): the bar stays on it.
        placement.remember(CGPoint(x: 1400, y: 900), on: Self.laptop)
        let smaller = ScreencastBarDisplay(key: "laptop", visibleFrame: CGRect(x: 0, y: 70, width: 1024, height: 600))
        #expect(placement.origin(for: Self.size, on: smaller) == CGPoint(x: 1024 - 360, y: 670 - 42))
    }

    @Test("Clamping moves a frame no more than it must")
    func clamping() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 40)
        #expect(ScreencastControlBarPlacement.clamped(CGPoint(x: 300, y: 300), size: size, within: frame) == CGPoint(x: 300, y: 300))
        #expect(ScreencastControlBarPlacement.clamped(CGPoint(x: -50, y: -10), size: size, within: frame) == CGPoint(x: 0, y: 0))
        #expect(ScreencastControlBarPlacement.clamped(CGPoint(x: 950, y: 790), size: size, within: frame) == CGPoint(x: 800, y: 760))
        // A bar wider than the frame keeps its left edge on it.
        #expect(ScreencastControlBarPlacement.clamped(CGPoint(x: 50, y: 10), size: CGSize(width: 1200, height: 40), within: frame).x == 0)
    }

    @Test("Stored positions that aren't two numbers are ignored")
    func badStoredPositions() {
        for value in [["x"], [1.0], [1.0, 2.0, 3.0], [Double.nan, 4.0]] as [Any] {
            defaults.set(["laptop": value], forKey: ScreencastControlBarPlacement.defaultsKey)
            #expect(placement.storedOffset(on: Self.laptop) == nil, "\(value)")
        }
        defaults.set("not a dictionary", forKey: ScreencastControlBarPlacement.defaultsKey)
        #expect(placement.origin(for: Self.size, on: Self.laptop) == ScreencastControlBarPlacement.defaultOrigin(
            for: Self.size, in: Self.laptop.visibleFrame, avoiding: nil
        ))
        placement.remember(CGPoint(x: 10, y: 80), on: Self.laptop)
        #expect(placement.storedOffset(on: Self.laptop) == CGPoint(x: 10, y: 10))
        #expect(defaults.leakedDomain == nil)
    }

    @Test("A moved bar belongs to the display that holds its middle, else the one it overlaps most")
    func displayOfAFrame() {
        let displays = [Self.laptop, Self.external]
        func display(_ frame: CGRect) -> String? {
            ScreencastControlBarPlacement.display(for: frame, among: displays)?.key
        }
        #expect(display(CGRect(x: 100, y: 100, width: 360, height: 42)) == "laptop")
        #expect(display(CGRect(x: 1400, y: 500, width: 360, height: 42)) == "external", "Its middle is on the external display")
        #expect(display(CGRect(x: 600, y: 930, width: 360, height: 42)) == "laptop", "Over the menu bar, overlapping only the laptop")
        #expect(display(CGRect(x: 6000, y: 6000, width: 360, height: 42)) == nil)
    }
}

// MARK: - The panel

@MainActor
@Suite("Screencast: the control bar's panel")
struct ScreencastControlBarPanelTests {
    static let laptop = ScreencastControlBarPlacementTests.laptop
    static let external = ScreencastControlBarPlacementTests.external

    let recording = FakeBarRecording()
    let defaults = InMemoryDefaults()
    var placement: ScreencastControlBarPlacement { ScreencastControlBarPlacement(defaults: defaults) }

    func makeBar() -> ScreencastControlBar {
        ScreencastControlBar(recording: recording, placement: placement, displays: { [Self.laptop, Self.external] }, ordersPanelIn: false)
    }

    @Test("The panel floats over other apps, on every Space and beside full-screen apps, and never takes the keyboard")
    func panel() {
        let panel = ScreencastControlBarPanel()
        #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate && !panel.canHide)
        #expect(panel.identifier == ScreencastControlBarPanel.identifier)
        // The recorder's filter keeps it out of the video; sharingType, which ScreenCaptureKit
        // ignores, stays as AppKit sets it.
        #expect(panel.sharingType == .readOnly)
    }

    @Test("Shown on a display, the bar sits where it was left there; a drag is remembered on the display it ends on")
    func showAndRemember() {
        let bar = makeBar()
        bar.show(on: Self.laptop)
        let size = bar.panel.frame.size
        #expect(size.width > 250 && size.height >= 36 && size.height <= 52, "\(size)")
        #expect(bar.isShown)
        #expect(bar.panel.frame.origin == ScreencastControlBarPlacement.defaultOrigin(for: size, in: Self.laptop.visibleFrame, avoiding: nil))
        #expect(placement.storedOffset(on: Self.laptop) == nil, "Placing it isn't a drag")

        // The person drags it onto the external display.
        bar.panel.setFrameOrigin(CGPoint(x: 1700, y: 900))
        bar.panelDidMove()
        bar.hide()
        #expect(!bar.isShown)

        bar.show(on: Self.external)
        #expect(bar.panel.frame.origin == CGPoint(x: 1700, y: 900))
        bar.hide()
        bar.show(on: Self.laptop)
        #expect(bar.panel.frame.origin.y == Self.laptop.visibleFrame.minY + ScreencastControlBarPlacement.bottomInset)

        // Moves after hiding aren't the person's.
        bar.hide()
        bar.panel.setFrameOrigin(CGPoint(x: 200, y: 300))
        bar.panelDidMove()
        #expect(placement.storedOffset(on: Self.laptop) == nil)
    }

    @Test("Under the unit-test host the bar never puts its panel on screen")
    func neverOnScreenInTests() {
        let bar = ScreencastControlBar(recording: recording, placement: placement, displays: { [Self.laptop] })
        bar.show(on: Self.laptop)
        #expect(bar.isShown && !bar.panel.isVisible)
        bar.hide()
    }

    @Test("Hiding takes away a question waiting for an answer")
    func hideEndsTheQuestion() {
        let bar = makeBar()
        bar.show(on: Self.laptop)
        bar.model.askToDiscard()
        bar.hide()
        #expect(bar.model.question == nil)
        #expect(recording.calls.isEmpty)
    }

    @Test("Drawing's switch adds the Draw button, and the bar widens around its middle")
    func drawWidensTheBar() {
        let bar = makeBar()
        bar.show(on: Self.laptop)
        let before = bar.panel.frame
        bar.onToggleDrawing = {}
        let after = bar.panel.frame
        #expect(after.width > before.width + 20, "\(before.width) → \(after.width)")
        #expect(abs(after.midX - before.midX) < 1)
        #expect(after.minY == before.minY)

        bar.isDrawing = true
        #expect(bar.model.isDrawing)
        bar.hide()
    }
}
