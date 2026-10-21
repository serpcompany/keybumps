import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Where a capture is, from the shortcut to the saved file.
enum ScreencastPhase: Equatable, Sendable {
    case idle
    /// The picker covers the screens.
    case picking
    /// The seconds left before a video starts recording.
    case countingDown(remaining: Int)
    /// The recorder is starting its streams.
    case starting
    case recording
    case paused
    /// Saving: the recording stopping.
    case finishing

    /// Recording or paused: while the control bar shows.
    var isRecording: Bool {
        self == .recording || self == .paused
    }
}

/// One observer added with `ScreencastController.addPhaseObserver(_:)`, to remove it with.
struct ScreencastPhaseObservation: Hashable, Sendable {
    let id: Int
}

/// A capture saved in ScreenGrabs' history, for the review panel (#450).
enum ScreencastCaptureResult: Equatable, Sendable {
    case video(ScreencastCapture)

    /// Its `screengrabs/recordings/<timestamp>/` folder.
    var folder: URL {
        switch self {
        case .video(let capture): capture.folder
        }
    }
}

/// What Screencast draws around a capture: the picker on every screen, the countdown, the
/// highlight while an area records, and short messages. `ScreencastOverlayWindows` in the app; an
/// inert one in the unit-test host, and fakes in tests. Every window it opens is Keybumps's own,
/// so recordings leave it out.
@MainActor
protocol ScreencastOverlayPresenting: AnyObject {
    /// Covers every screen with the picker for `model`. Its Record (or Return) runs `confirm`, and
    /// its close button `cancel`.
    func showPicker(_ model: ScreencastPickerModel, confirm: @escaping () -> Void, cancel: @escaping () -> Void)
    func closePicker()
    /// Shows `remaining` seconds centered on each of `frames` (AppKit's global space), or updates
    /// it. Its Cancel runs `cancel`.
    func showCountdown(_ remaining: Int, in frames: [CGRect], cancel: @escaping () -> Void)
    func closeCountdown()
    /// Dims everything on the area's screen but the area. It ignores the mouse, and recordings
    /// leave it out because it's never registered as an overlay.
    func showAreaHighlight(_ area: ScreencastPickedArea)
    func closeAreaHighlight()
    /// Runs `handler` on Escape, in Keybumps or another app, until `stopWatchingEscape()`. The
    /// controller watches only while the picker is open.
    func watchEscape(_ handler: @escaping () -> Void)
    func stopWatchingEscape()
    /// A short message, such as why a capture couldn't start.
    func showMessage(_ message: String)
    /// "Getting ready…", while the screen is read before the picker shows, if that takes a moment.
    func showGettingReady()
    func hideGettingReady()
}

/// Draws nothing: the unit-test host's default, so no test opens a window.
@MainActor
final class InertScreencastOverlays: ScreencastOverlayPresenting {
    func showPicker(_ model: ScreencastPickerModel, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {}
    func closePicker() {}
    func showCountdown(_ remaining: Int, in frames: [CGRect], cancel: @escaping () -> Void) {}
    func closeCountdown() {}
    func showAreaHighlight(_ area: ScreencastPickedArea) {}
    func closeAreaHighlight() {}
    func watchEscape(_ handler: @escaping () -> Void) {}
    func stopWatchingEscape() {}
    func showMessage(_ message: String) {}
    func showGettingReady() {}
    func hideGettingReady() {}
}

/// Runs one capture at a time, from Record Screen to the saved file: it opens the picker, counts
/// down, starts `recorder`, keeps an area highlighted while it records, and hands each saved
/// capture to `onCaptureFinished`.
///
/// The pieces around a recording hang on it:
/// - **#448, the control bar,** shows from `.starting` until the recording ends, reads `recorder` for the elapsed
///   time, the sounds, and the microphone level, and acts through `pause()`, `resume()`,
///   `restart()`, `setAudio(_:on:)`, `stop()`, and `discard()`, never the recorder's own, so the
///   phase, the highlight, and the finished capture stay right.
/// - **#449, the overlays,** go up when the phase leaves `.picking` for a video
///   (`.countingDown` or `.starting`), as `choice` says (`showsShortcuts`, `highlightsClicks`, and
///   the `regions` it shows on), and register their windows with `recorder.includeOverlayWindow`
///   before it starts, so the first frame has them. A restart clears the drawing and the keys
///   first (`addWillRestartObserver(_:)`) and gives the screen a moment to show that, and they come
///   down when the phase is `.idle` again.
/// - **#450, the review panel,** is `onCaptureFinished`, which gets every saved recording.
///
/// Each piece watches the phase with its own `addPhaseObserver(_:)`, so none replaces another's,
/// whatever order they're added in; `onPhaseChange` reports it too. Escape closes the picker, and
/// does nothing once Record is pressed (#518): not in the countdown, while starting, recording, or
/// paused. Only `discard()`, the control bar's Discard, which asks first, throws a recording away;
/// it also cancels a start, so one that hangs has a way out.
///
/// A recording that ends on its own (macOS stopped it, its display went away, the disk filled)
/// leaves `.recording` for `.finishing` as soon as the recorder starts saving what it has, and its
/// capture reaches `onCaptureFinished` once saved. Meanwhile `stop()` waits for that capture,
/// `discard()` deletes it when it arrives (it never reaches `onCaptureFinished`), and `restart()`
/// does nothing.
@available(macOS 15, *)
@MainActor
@Observable
final class ScreencastController {
    let recorder: ScreencastRecorder

    private(set) var phase: ScreencastPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            announce(phase)
        }
    }

    /// The picker while it's open.
    private(set) var picker: ScreencastPickerModel?
    /// What the picker chose, from Record until the capture is saved or thrown away.
    private(set) var choice: ScreencastChoice?

    @ObservationIgnored var onPhaseChange: ((ScreencastPhase) -> Void)?
    /// `addPhaseObserver(_:)`'s observers, in the order they were added.
    @ObservationIgnored private var phaseObservers: [(ScreencastPhaseObservation, (ScreencastPhase) -> Void)] = []
    @ObservationIgnored private var nextPhaseObservation = 0
    /// `addWillRestartObserver(_:)`'s observers, in the order they were added.
    @ObservationIgnored private var willRestartObservers: [() -> Bool] = []
    /// Phases entered while the observers are being told of an earlier one, told next, in order.
    @ObservationIgnored private var unannouncedPhases: [ScreencastPhase] = []
    @ObservationIgnored private var isAnnouncingPhase = false
    /// A recording was saved: the review panel takes it from here. A recording that ended early
    /// comes here too, with `endedEarly` set, after its message.
    @ObservationIgnored var onCaptureFinished: ((ScreencastCaptureResult) -> Void)?

    @ObservationIgnored private let system: any ScreencastPickerSystem
    @ObservationIgnored private let presenter: any ScreencastOverlayPresenting
    @ObservationIgnored private let areaMemory: ScreencastAreaMemory
    @ObservationIgnored private let pickerMemory: ScreencastPickerMemory
    @ObservationIgnored private let preferences: @MainActor () -> ScreencastPreferences
    @ObservationIgnored private let saveSwitches: @MainActor (ScreencastSwitches) -> Void
    @ObservationIgnored private let screens: @MainActor () -> ScreencastScreenLayout
    @ObservationIgnored private let pointerLocation: @MainActor () -> CGPoint
    @ObservationIgnored private let microphoneAvailable: @MainActor () -> Bool
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private let restartSettle: TimeInterval
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let ownProcessID: pid_t
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    /// The settings read when the picker opened, for the capture it starts.
    @ObservationIgnored private var settings: ScreencastPreferences?
    @ObservationIgnored private var flow: Task<Void, Never>?
    @ObservationIgnored private var windowsLoad: Task<Void, Never>?
    /// Bumped by every open and cancel, so a cancelled countdown, start, or window read does nothing.
    @ObservationIgnored private var generation = 0
    /// The recorder is saving a recording that ended on its own, until `recordingEndedEarly`.
    @ObservationIgnored private var isEndingEarly = false
    /// `discard()` came while it was: the capture it saves is deleted.
    @ObservationIgnored private var discardsEarlyEnd = false
    @ObservationIgnored private var earlyEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// A restart is under way: another is refused until it returns.
    @ObservationIgnored private var restartInFlight = false
    /// The "Getting ready…" cue, shown if reading the screen takes a moment, and the read's deadline.
    @ObservationIgnored private var gettingReadyCue: Task<Void, Never>?
    @ObservationIgnored private var showsGettingReady = false
    @ObservationIgnored private let gettingReadyDelay: TimeInterval
    @ObservationIgnored private let screenReadTimeout: TimeInterval
    /// Where the displays changing is heard, while the picker is open.
    @ObservationIgnored private let screenChanges: NotificationCenter
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    /// False after `shutDown()`: what's saved stays in ScreenGrabs' history and nothing opens.
    @ObservationIgnored private var opensFinishedCaptures = true

    /// - Parameters:
    ///   - recorder: The recording engine; a new one, inert in the unit-test host, unless given.
    ///   - system: The screen, for the windows to pick; inert in the unit-test host unless a test
    ///     passes a fake.
    ///   - presenter: The picker's and countdown's windows; inert in the unit-test host.
    ///   - areaMemory: The last area recorded, which the picker opens with.
    ///   - pickerMemory: The rest of what was last recorded, which the picker opens with, but the
    ///     switches.
    ///   - preferences: Settings › ScreenGrabs, read each time the picker opens.
    ///   - saveSwitches: Saves the picker's switches as Settings › ScreenGrabs', at Record.
    ///   - screens: The displays, read each time the picker opens.
    ///   - pointerLocation: Where the pointer is, in AppKit's global space: Screen mode starts on
    ///     its screen.
    ///   - microphoneAvailable: Whether Keybumps has Microphone access, so the microphone switch can
    ///     start on without recording ever asking for it.
    ///   - sleep: Waits a number of seconds, for the countdown and a restart's settle; tests pass
    ///     their own clock.
    ///   - restartSettle: How long a restart waits, once its observers cleared the screen, before
    ///     the recorder starts the new take (`restartSettle(framesPerSecond:)`).
    ///   - gettingReadyDelay: How long reading the screen may take before "Getting ready…" shows.
    ///   - screenReadTimeout: How long reading the screen may take before the picker gives up and
    ///     says the capture couldn't start.
    ///   - screenChanges: Where `NSApplication.didChangeScreenParametersNotification` is posted.
    init(
        recorder: ScreencastRecorder? = nil,
        system: (any ScreencastPickerSystem)? = nil,
        presenter: (any ScreencastOverlayPresenting)? = nil,
        areaMemory: ScreencastAreaMemory,
        pickerMemory: ScreencastPickerMemory,
        preferences: @escaping @MainActor () -> ScreencastPreferences,
        saveSwitches: @escaping @MainActor (ScreencastSwitches) -> Void,
        screens: @escaping @MainActor () -> ScreencastScreenLayout = { ScreencastScreenLayout.current() },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        microphoneAvailable: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        restartSettle: TimeInterval = ScreencastController.restartSettle(framesPerSecond: ScreencastOptions().framesPerSecond),
        gettingReadyDelay: TimeInterval = 0.3,
        screenReadTimeout: TimeInterval = 30,
        screenChanges: NotificationCenter = .default,
        fileManager: FileManager = .default,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.recorder = recorder ?? ScreencastRecorder()
        self.system = system ?? ScreenCaptureKitPickerSystem.current
        self.presenter = presenter ?? (UnitTestHost.isActive ? InertScreencastOverlays() : ScreencastOverlayWindows())
        self.areaMemory = areaMemory
        self.pickerMemory = pickerMemory
        self.preferences = preferences
        self.saveSwitches = saveSwitches
        self.screens = screens
        self.pointerLocation = pointerLocation
        self.microphoneAvailable = microphoneAvailable
        self.sleep = sleep
        self.restartSettle = restartSettle
        self.gettingReadyDelay = gettingReadyDelay
        self.screenReadTimeout = screenReadTimeout
        self.screenChanges = screenChanges
        self.fileManager = fileManager
        self.ownProcessID = ownProcessID
        self.recorder.onEndedEarly = { [weak self] capture, failure in
            self?.recordingEndedEarly(capture, failure)
        }
        followRecorderState()
    }

    // MARK: Watching the phase

    /// Calls `observer` with each phase as it's entered, after `onPhaseChange` and the observers
    /// added before it. The control bar, the overlays, and the review panel each add their own, so
    /// adding one never replaces another. Keep the observation to remove it.
    ///
    /// An observer may change the phase, or add or remove observers, while it's told. Every
    /// observer is still told every phase once, in order: a phase entered meanwhile waits until the
    /// current one has reached everyone, so the controller's own `phase` may already be ahead of the
    /// one an observer is given. An observer removed meanwhile isn't told anything more, and one
    /// added meanwhile starts with the next phase.
    @discardableResult
    func addPhaseObserver(_ observer: @escaping (ScreencastPhase) -> Void) -> ScreencastPhaseObservation {
        nextPhaseObservation += 1
        let observation = ScreencastPhaseObservation(id: nextPhaseObservation)
        phaseObservers.append((observation, observer))
        return observation
    }

    func removePhaseObserver(_ observation: ScreencastPhaseObservation) {
        phaseObservers.removeAll { $0.0 == observation }
    }

    /// Calls `observer` each time a restart is about to throw the take away and start a new one,
    /// which stays in the same phase. It returns whether it took something off the screen (#449:
    /// the drawing and the keys), drawn by the time it returns. If any did, the restart waits
    /// `restartSettle` before the recorder swaps its files, so ScreenCaptureKit has delivered a
    /// frame of the cleared screen by then: the recorder starts the new take with the last frame
    /// delivered, and keeps every frame after it. A screen that's slow to show the change could
    /// still put the old marks or keys in that frame; nothing waits for a particular frame.
    func addWillRestartObserver(_ observer: @escaping () -> Bool) {
        willRestartObservers.append(observer)
    }

    /// Tells `onPhaseChange` and the observers about `phase`, or, while they're being told about an
    /// earlier one, once they've heard it (`addPhaseObserver(_:)`).
    private func announce(_ phase: ScreencastPhase) {
        unannouncedPhases.append(phase)
        guard !isAnnouncingPhase else { return }
        isAnnouncingPhase = true
        defer { isAnnouncingPhase = false }
        var rounds = 0
        while !unannouncedPhases.isEmpty {
            rounds += 1
            assert(rounds < 100, "The recording's phase observers keep changing the phase")
            let next = unannouncedPhases.removeFirst()
            onPhaseChange?(next)
            for observation in phaseObservers.map(\.0) {
                // Removed by an observer told before it: told nothing more.
                guard let observer = phaseObservers.first(where: { $0.0 == observation })?.1 else { continue }
                observer(next)
            }
        }
    }

    /// A restart's settle: three frames at the recording's rate, and never less than 0.1 s. The
    /// cleared windows draw at the next screen refresh, and ScreenCaptureKit delivers the frame
    /// that shows them at most one frame later.
    nonisolated static func restartSettle(framesPerSecond: Int) -> TimeInterval {
        max(0.1, 3 / Double(max(framesPerSecond, 1)))
    }

    // MARK: Picking

    /// Record Screen: opens the picker as it was last used to record, with the switches as
    /// Settings has them and the last area drawn. Does nothing while a capture is under way.
    func open() {
        guard phase == .idle, Self.canStart(recorder.state) else { return }
        generation += 1
        let settings = preferences()
        self.settings = settings
        let layout = screens()
        let model = ScreencastPickerModel(
            layout: layout,
            preferences: settings,
            microphoneAvailable: microphoneAvailable(),
            remembered: pickerMemory.choices,
            rememberedArea: areaMemory.area(in: layout),
            // Read once, now: the bar shows on this screen, and Screen mode starts with it.
            pointerScreen: layout.screen(containing: pointerLocation())?.id
        )
        picker = model
        choice = nil
        opensFinishedCaptures = true
        phase = .picking
        presenter.watchEscape { [weak self] in self?.escapePressed() }
        watchScreens()

        // The screen is read before the picker covers it, so an alert macOS shows for the read
        // (such as its monthly question about apps that record the screen) is never under it. If
        // the read takes a moment, "Getting ready…" says Record Screen was heard, and stays
        // until the read ends. A read that fails, or takes too long, says why instead.
        let generation = generation
        let delay = gettingReadyDelay
        let timeout = screenReadTimeout
        gettingReadyCue = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation, self.phase == .picking else { return }
            self.showsGettingReady = true
            self.presenter.showGettingReady()
            try? await Task.sleep(for: .seconds(max(timeout - delay, 0)))
            guard !Task.isCancelled, self.generation == generation, self.phase == .picking else { return }
            self.pickerUnavailable(ScreencastFailure.captureFailed)
        }
        windowsLoad = Task { [weak self] in
            guard let self else { return }
            let content: ScreencastContent
            do {
                content = try await self.system.content()
            } catch {
                guard self.generation == generation, self.picker === model, self.phase == .picking else { return }
                self.pickerUnavailable(error)
                return
            }
            guard self.generation == generation, self.picker === model, self.phase == .picking else { return }
            model.windows = ScreencastWindowPicking.pickableWindows(
                in: content,
                ownProcessID: self.ownProcessID,
                transparent: self.system.transparentWindows()
            )
            self.endGettingReady()
            self.presenter.showPicker(model, confirm: { [weak self] in self?.confirm() }, cancel: { [weak self] in self?.cancel() })
            self.logger.info("screencast picker opened displays=\(layout.screens.count, privacy: .public)")
        }
    }

    /// The screen couldn't be read, or reading it took too long: the picker never shows, and the
    /// message says why.
    private func pickerUnavailable(_ error: Error) {
        guard phase == .picking else { return }
        let failure = (error as? ScreencastFailure) ?? .captureFailed
        logger.error("screencast picker unavailable category=\(failure.rawValue, privacy: .public)")
        cancel()
        presenter.showMessage(ScreencastMessages.text(for: failure))
    }

    /// The displays changed while the picker is open, such as one unplugged. Its panels and its
    /// screen choices were made for the displays as they were, so it closes and says so, rather
    /// than offer a screen that's gone. A notice that leaves the displays as they were does nothing.
    private func screensChanged() {
        guard phase == .picking, let model = picker, screens() != model.layout else { return }
        logger.info("screencast picker closed: displays changed")
        cancel()
        presenter.showMessage(ScreencastMessages.screensChanged)
    }

    private func watchScreens() {
        stopWatchingScreens()
        screenObserver = screenChanges.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func stopWatchingScreens() {
        if let screenObserver { screenChanges.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Record: closes the picker, remembers what it chose and saves its switches as the settings,
    /// then counts down and starts recording. Does nothing until something is chosen.
    func confirm() {
        guard phase == .picking, let model = picker, let choice = model.choice(), let settings else { return }
        if let area = choice.area { areaMemory.save(area.rect) }
        pickerMemory.save(model.choicesToRemember)
        saveSwitches(model.switches)
        windowsLoad?.cancel()
        stopWatchingScreens()
        presenter.closePicker()
        // Escape does nothing from here on; the countdown stops only from its Cancel.
        presenter.stopWatchingEscape()
        picker = nil
        self.choice = choice
        logger.info("screencast picker confirmed target=\(choice.target.kind, privacy: .public)")
        let generation = generation
        if let area = choice.area { presenter.showAreaHighlight(area) }
        // Entered now, so a cancel before the countdown's first second still stops it.
        phase = settings.countdownSeconds > 0 ? .countingDown(remaining: settings.countdownSeconds) : .starting
        flow = Task { [weak self] in await self?.countDownAndRecord(choice, settings: settings, generation: generation) }
    }

    /// Escape, heard only while the picker is open: closes it. Never a countdown, a start, or a
    /// recording, even if a key the presenter heard arrives late.
    private func escapePressed() {
        guard phase == .picking else { return }
        cancel()
    }

    /// The picker's close button or Escape, the countdown's Cancel, or `shutDown()`: closes the
    /// picker, stops the countdown, or cancels a start (as `discard()` does), and leaves nothing
    /// behind. Does nothing once recording; `discard()` throws a recording away.
    func cancel() {
        switch phase {
        case .picking:
            windowsLoad?.cancel()
            endGettingReady()
            stopWatchingScreens()
            presenter.closePicker()
            picker = nil
        case .countingDown:
            flow?.cancel()
            presenter.closeCountdown()
            presenter.closeAreaHighlight()
        case .starting:
            flow?.cancel()
            presenter.closeAreaHighlight()
            // Cancels the start in progress, which then deletes its folder.
            Task { [recorder] in await recorder.discard() }
        default:
            return
        }
        generation += 1
        presenter.stopWatchingEscape()
        choice = nil
        phase = .idle
        logger.info("screencast cancelled")
    }

    // MARK: Counting down and starting

    private func countDownAndRecord(_ choice: ScreencastChoice, settings: ScreencastPreferences, generation: Int) async {
        var remaining = max(settings.countdownSeconds, 0)
        while remaining > 0 {
            guard generation == self.generation else { return }
            phase = .countingDown(remaining: remaining)
            presenter.showCountdown(remaining, in: choice.countdownFrames, cancel: { [weak self] in self?.cancel() })
            do {
                try await sleep(1)
            } catch {
                return
            }
            remaining -= 1
        }
        guard generation == self.generation else { return }
        presenter.closeCountdown()
        phase = .starting
        do {
            try await recorder.start(
                target: choice.target,
                audio: choice.audio,
                capturesFolder: settings.capturesFolder,
                options: ScreencastOptions(showsMouseClicks: choice.highlightsClicks)
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            end(showing: error)
            return
        }
        guard generation == self.generation else { return }
        phase = .recording
    }

    // MARK: Recording

    func pause() {
        guard !noticeEarlyEnd(), phase == .recording else { return }
        recorder.pause()
        if recorder.state == .paused { phase = .paused }
    }

    func resume() {
        guard !noticeEarlyEnd(), phase == .paused else { return }
        recorder.resume()
        if recorder.state == .recording { phase = .recording }
    }

    /// Switches a recorded sound off or back on (`ScreencastRecorder.setAudio`).
    func setAudio(_ source: ScreencastAudioSource, on: Bool) {
        guard !noticeEarlyEnd(), phase.isRecording else { return }
        recorder.setAudio(source, on: on)
    }

    /// Throws away what's recorded and starts again, recording, or paused if `pause()` came while
    /// the recorder restarted. Refused while another restart is under way, or while a recording
    /// that ended on its own is saving; a `stop()`, `discard()`, `shutDown()`, or early end that
    /// comes while it waits wins.
    ///
    /// The will-restart observers clear the screen first. If they took anything off it, the restart
    /// waits `restartSettle` for a frame of the cleared screen to reach the recorder, then checks
    /// again that this recording is still going before restarting it.
    func restart() async {
        guard !noticeEarlyEnd(), phase.isRecording, !restartInFlight else { return }
        restartInFlight = true
        defer { restartInFlight = false }
        // Every observer is told, whatever the others cleared.
        let cleared = willRestartObservers.reduce(false) { cleared, observer in observer() || cleared }
        if cleared {
            let generation = generation
            // A cancelled wait still restarts, once the checks below pass.
            try? await sleep(restartSettle)
            // A stop, discard, shutdown, or early end came meanwhile, or another recording started.
            guard generation == self.generation, !noticeEarlyEnd(), phase.isRecording else { return }
        }
        do {
            try await recorder.restart()
        } catch {
            // A stop or discard took over meanwhile.
            guard phase.isRecording else { return }
            end(showing: error)
            return
        }
        guard !noticeEarlyEnd(), phase.isRecording else { return }
        switch recorder.state {
        case .recording: phase = .recording
        case .paused: phase = .paused
        default: break
        }
    }

    /// Stops and keeps the recording, then hands it to `onCaptureFinished`. While a recording that
    /// ended on its own is saving, it waits for that capture instead.
    func stop() async {
        if noticeEarlyEnd() {
            await earlyEndSaved()
            return
        }
        guard phase.isRecording else { return }
        phase = .finishing
        presenter.closeAreaHighlight()
        do {
            let capture = try await recorder.stop()
            finish(with: .video(capture))
        } catch {
            end(showing: error)
        }
    }

    /// Stops and deletes the recording. While a recording that ended on its own is saving, it
    /// deletes that capture once it's saved, and nothing opens for it. While the recording starts,
    /// it cancels the start, without waiting for one that hangs, so the bar's Discard always ends it.
    func discard() async {
        if noticeEarlyEnd() {
            discardsEarlyEnd = true
            await earlyEndSaved()
            return
        }
        if phase == .starting {
            cancel()
            return
        }
        guard phase.isRecording else { return }
        phase = .finishing
        presenter.closeAreaHighlight()
        await recorder.discard()
        choice = nil
        phase = .idle
    }

    /// Screencast turned off, or Keybumps Locked: the picker closes, and a countdown or a start is
    /// cancelled. A recording stops and is kept, and a capture being saved finishes; neither opens
    /// anything: they stay in the history they were made in (`ScreencastPreferences.capturesFolder`),
    /// which the recordings index reads again at the next launch, so it lists them. Footage is never
    /// thrown away here.
    func shutDown() async {
        opensFinishedCaptures = false
        switch phase {
        case .picking, .countingDown, .starting:
            cancel()
        case .recording, .paused:
            await stop()
        case .finishing:
            if isEndingEarly { await earlyEndSaved() }
        case .idle:
            break
        }
    }

    /// Whether the recorder is saving a recording that ended on its own (`endingEarly`, which its
    /// own stop, discard, or restart never sets). The first time it's seen while still showing a
    /// recording, the phase becomes `.finishing` and the highlight closes; `recordingEndedEarly`
    /// completes it.
    @discardableResult
    private func noticeEarlyEnd() -> Bool {
        if !isEndingEarly, phase.isRecording, recorder.endingEarly != nil {
            isEndingEarly = true
            presenter.closeAreaHighlight()
            phase = .finishing
        }
        return isEndingEarly
    }

    /// Notices an early end as soon as the recorder starts saving one, not only when the control
    /// bar acts.
    private func followRecorderState() {
        withObservationTracking {
            _ = recorder.endingEarly
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.noticeEarlyEnd()
                self?.followRecorderState()
            }
        }
    }

    /// Returns once the capture a recording that ended on its own saves has been handled.
    private func earlyEndSaved() async {
        guard isEndingEarly else { return }
        await withCheckedContinuation { earlyEndWaiters.append($0) }
    }

    private func recordingEndedEarly(_ capture: ScreencastCapture?, _ failure: ScreencastFailure) {
        guard phase.isRecording || phase == .finishing else { return }
        let discards = discardsEarlyEnd
        isEndingEarly = false
        discardsEarlyEnd = false
        presenter.closeAreaHighlight()
        if discards {
            // Asked for while it saved: nothing is kept, and nothing says it was.
            if let capture { try? fileManager.removeItem(at: capture.folder) }
            logger.info("screencast discarded after it ended early category=\(failure.rawValue, privacy: .public)")
            choice = nil
            phase = .idle
        } else {
            presenter.showMessage(ScreencastMessages.endedEarly(failure, kept: capture != nil))
            if let capture {
                finish(with: .video(capture))
            } else {
                choice = nil
                phase = .idle
            }
        }
        let waiters = earlyEndWaiters
        earlyEndWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Ending

    private func finish(with result: ScreencastCaptureResult) {
        choice = nil
        phase = .idle
        if opensFinishedCaptures {
            onCaptureFinished?(result)
        } else {
            logger.info("screencast recording kept while turned off")
        }
    }

    /// Something failed: everything closes, and the message says why. A call the recorder refused
    /// (`ScreencastRecorderError`) has nothing to tell the person, so it closes quietly.
    private func end(showing error: Error) {
        presenter.closeCountdown()
        presenter.closeAreaHighlight()
        presenter.stopWatchingEscape()
        if error is ScreencastRecorderError {
            logger.error("screencast ended category=\(Self.category(of: error), privacy: .public)")
        } else {
            let failure = (error as? ScreencastFailure) ?? .captureFailed
            logger.error("screencast failed category=\(failure.rawValue, privacy: .public)")
            presenter.showMessage(ScreencastMessages.text(for: failure))
        }
        choice = nil
        phase = .idle
    }

    /// Stops the "Getting ready…" cue, and hides it if it showed.
    private func endGettingReady() {
        gettingReadyCue?.cancel()
        gettingReadyCue = nil
        if showsGettingReady {
            showsGettingReady = false
            presenter.hideGettingReady()
        }
    }

    /// Whether the recorder is free: a start that was cancelled may still be winding down.
    private static func canStart(_ state: ScreencastRecorderState) -> Bool {
        switch state {
        case .idle, .failed: true
        case .starting, .recording, .paused, .stopping: false
        }
    }

    private static func category(of error: Error) -> String {
        (error as? ScreencastFailure)?.rawValue ?? String(describing: type(of: error))
    }
}

/// What ScreenGrabs says when a recording can't start or save.
enum ScreencastMessages {
    static func text(for failure: ScreencastFailure) -> String {
        switch failure {
        case .screenRecordingDenied:
            "Turn on Screen Recording for Keybumps in System Settings to record your screen."
        case .targetUnavailable:
            "That window or screen isn’t there anymore."
        case .captureFailed:
            "The recording couldn’t start. Try again."
        case .stoppedByMacOS:
            "macOS stopped the recording."
        case .writerFailed:
            "The recording couldn’t be saved. Check that the disk has room."
        case .folderUnavailable:
            "The recordings folder couldn’t be created."
        case .noFootage:
            "Nothing was recorded."
        }
    }

    /// The displays changed while the picker was open.
    static let screensChanged = "The screens changed. Choose \(PluginAction.recordScreenTitle) again."

    /// A recording that stopped on its own: why, and whether what it recorded is saved.
    static func endedEarly(_ failure: ScreencastFailure, kept: Bool) -> String {
        let reason = switch failure {
        case .stoppedByMacOS: "macOS stopped the recording."
        case .targetUnavailable: "The recording stopped: its window or screen went away."
        case .writerFailed: "The recording stopped: the disk may be full."
        case .screenRecordingDenied: "The recording stopped: Keybumps no longer has Screen Recording."
        case .captureFailed, .folderUnavailable, .noFootage: "The recording stopped unexpectedly."
        }
        return kept ? "\(reason) What was recorded is saved." : reason
    }
}
