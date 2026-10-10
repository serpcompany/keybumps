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
    /// Saving: the recording stopping, or a screenshot being taken.
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

/// A capture saved in the captures folder, for the review panel (#450).
enum ScreencastCaptureResult: Equatable, Sendable {
    case video(ScreencastCapture)
    case screenshot(ScreencastScreenshot)

    /// Its `<captures folder>/<timestamp>/` folder.
    var folder: URL {
        switch self {
        case .video(let capture): capture.folder
        case .screenshot(let screenshot): screenshot.folder
        }
    }
}

/// What Screencast draws around a capture: the picker on every screen, the countdown, the
/// highlight while an area records, and short messages. `ScreencastOverlayWindows` in the app; an
/// inert one in the unit-test host, and fakes in tests. Every window it opens is Keybumps's own,
/// so recordings and screenshots leave it out.
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
    /// Runs `handler` on Escape, in Keybumps or another app, until `stopWatchingEscape()`.
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

/// Runs one capture at a time, from Start Screencast to the saved file: it opens the picker, counts
/// down, starts `recorder`, keeps an area highlighted while it records, takes screenshots, and hands
/// each saved capture to `onCaptureFinished`.
///
/// The pieces around a recording hang on it:
/// - **#448, the control bar,** shows from `.starting` until the recording ends, reads `recorder` for the elapsed
///   time, the sounds, and the microphone level, and acts through `pause()`, `resume()`,
///   `restart()`, `setAudio(_:on:)`, `stop()`, and `discard()`, never the recorder's own, so the
///   phase, the highlight, and the finished capture stay right.
/// - **#449, the overlays,** go up when the phase leaves `.picking` for a video
///   (`.countingDown` or `.starting`), as `choice` says (`showsShortcuts`, `highlightsClicks`, and
///   the `regions` it shows on), and register their windows with `recorder.includeOverlayWindow`
///   before it starts, so the first frame has them. A restart clears the drawing
///   (`addRestartObserver(_:)`), and they come down when the phase is `.idle` again.
/// - **#450, the review panel,** is `onCaptureFinished`, which gets every saved video and screenshot.
///
/// Each piece watches the phase with its own `addPhaseObserver(_:)`, so none replaces another's,
/// whatever order they're added in; `onPhaseChange` reports it too. Escape cancels while picking,
/// counting down, or starting; once recording, only `discard()` throws it away.
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
    /// `addRestartObserver(_:)`'s observers, in the order they were added.
    @ObservationIgnored private var restartObservers: [() -> Void] = []
    /// Phases entered while the observers are being told of an earlier one, told next, in order.
    @ObservationIgnored private var unannouncedPhases: [ScreencastPhase] = []
    @ObservationIgnored private var isAnnouncingPhase = false
    /// A video or screenshot was saved: the review panel takes it from here. A recording that
    /// ended early comes here too, with `endedEarly` set, after its message.
    @ObservationIgnored var onCaptureFinished: ((ScreencastCaptureResult) -> Void)?

    @ObservationIgnored private let system: any ScreencastPickerSystem
    @ObservationIgnored private let presenter: any ScreencastOverlayPresenting
    @ObservationIgnored private let areaMemory: ScreencastAreaMemory
    @ObservationIgnored private let preferences: @MainActor () -> ScreencastPreferences
    @ObservationIgnored private let screens: @MainActor () -> ScreencastScreenLayout
    @ObservationIgnored private let microphoneAvailable: @MainActor () -> Bool
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private let now: () -> Date
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
    /// The "Getting ready…" cue, shown if reading the screen takes a moment.
    @ObservationIgnored private var gettingReadyCue: Task<Void, Never>?
    @ObservationIgnored private var showsGettingReady = false
    @ObservationIgnored private let gettingReadyDelay: TimeInterval
    /// False after `shutDown()`: what's saved stays in the captures folder and nothing opens.
    @ObservationIgnored private var opensFinishedCaptures = true

    /// - Parameters:
    ///   - recorder: The recording engine; a new one, inert in the unit-test host, unless given.
    ///   - system: The screen, for the windows to pick and for screenshots; inert in the unit-test
    ///     host unless a test passes a fake.
    ///   - presenter: The picker's and countdown's windows; inert in the unit-test host.
    ///   - preferences: Settings › Screencast, read each time the picker opens.
    ///   - screens: The displays, read each time the picker opens.
    ///   - microphoneAvailable: Whether Keybumps has Microphone access, so the microphone switch can
    ///     start on without recording ever asking for it.
    ///   - sleep: Waits a number of seconds, for the countdown; tests pass their own clock.
    ///   - gettingReadyDelay: How long reading the screen may take before "Getting ready…" shows.
    init(
        recorder: ScreencastRecorder? = nil,
        system: (any ScreencastPickerSystem)? = nil,
        presenter: (any ScreencastOverlayPresenting)? = nil,
        areaMemory: ScreencastAreaMemory,
        preferences: @escaping @MainActor () -> ScreencastPreferences,
        screens: @escaping @MainActor () -> ScreencastScreenLayout = { ScreencastScreenLayout.current() },
        microphoneAvailable: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        gettingReadyDelay: TimeInterval = 0.3,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.recorder = recorder ?? ScreencastRecorder()
        self.system = system ?? ScreenCaptureKitPickerSystem.current
        self.presenter = presenter ?? (UnitTestHost.isActive ? InertScreencastOverlays() : ScreencastOverlayWindows())
        self.areaMemory = areaMemory
        self.preferences = preferences
        self.screens = screens
        self.microphoneAvailable = microphoneAvailable
        self.sleep = sleep
        self.gettingReadyDelay = gettingReadyDelay
        self.now = now
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

    /// Calls `observer` each time a restart has started a new take, which stays in the same phase:
    /// the overlays clear the drawing then (#449).
    func addRestartObserver(_ observer: @escaping () -> Void) {
        restartObservers.append(observer)
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
            assert(rounds < 100, "Screencast's phase observers keep changing the phase")
            let next = unannouncedPhases.removeFirst()
            onPhaseChange?(next)
            for observation in phaseObservers.map(\.0) {
                // Removed by an observer told before it: told nothing more.
                guard let observer = phaseObservers.first(where: { $0.0 == observation })?.1 else { continue }
                observer(next)
            }
        }
    }

    // MARK: Picking

    /// Start Screencast: opens the picker, with the switches as Settings has them and the last
    /// area drawn. Does nothing while a capture is under way.
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
            rememberedArea: areaMemory.area(in: layout)
        )
        picker = model
        choice = nil
        opensFinishedCaptures = true
        phase = .picking
        presenter.watchEscape { [weak self] in self?.cancel() }

        // The screen is read before the picker covers it, so an alert macOS shows for the read
        // (such as its monthly question about apps that record the screen) is never under it. If
        // the read takes a moment, "Getting ready…" says Start Screencast was heard.
        let generation = generation
        let delay = gettingReadyDelay
        gettingReadyCue = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation, self.phase == .picking else { return }
            self.showsGettingReady = true
            self.presenter.showGettingReady()
        }
        windowsLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await self.system.content()
                if self.generation == generation, self.picker === model {
                    model.windows = ScreencastWindowPicking.pickableWindows(
                        in: content,
                        ownProcessID: self.ownProcessID,
                        transparent: self.system.transparentWindows()
                    )
                }
            } catch {
                // Window picking offers nothing; Record says why if the screen can't be read.
                self.logger.error("screencast picker windows unavailable category=\(Self.category(of: error), privacy: .public)")
            }
            guard self.generation == generation, self.picker === model, self.phase == .picking else { return }
            self.endGettingReady()
            self.presenter.showPicker(model, confirm: { [weak self] in self?.confirm() }, cancel: { [weak self] in self?.cancel() })
            self.logger.info("screencast picker opened displays=\(layout.screens.count, privacy: .public)")
        }
    }

    /// Record or Capture: closes the picker, remembers an area, then takes the screenshot, or counts
    /// down and starts recording. Does nothing until something is chosen.
    func confirm() {
        guard phase == .picking, let model = picker, let choice = model.choice(), let settings else { return }
        if let area = choice.area { areaMemory.save(area.rect) }
        windowsLoad?.cancel()
        presenter.closePicker()
        picker = nil
        self.choice = choice
        logger.info("screencast picker confirmed kind=\(choice.kind.rawValue, privacy: .public) target=\(choice.target.kind, privacy: .public)")
        let generation = generation
        switch choice.kind {
        case .screenshot:
            presenter.stopWatchingEscape()
            phase = .finishing
            flow = Task { [weak self] in await self?.takeScreenshot(choice, settings: settings, generation: generation) }
        case .video:
            if let area = choice.area { presenter.showAreaHighlight(area) }
            // Entered now, so Escape before the countdown's first second still cancels it.
            phase = settings.countdownSeconds > 0 ? .countingDown(remaining: settings.countdownSeconds) : .starting
            flow = Task { [weak self] in await self?.countDownAndRecord(choice, settings: settings, generation: generation) }
        }
    }

    /// Escape: closes the picker, stops the countdown, or cancels a start, and leaves nothing
    /// behind. Does nothing once recording; `discard()` throws a recording away.
    func cancel() {
        switch phase {
        case .picking:
            windowsLoad?.cancel()
            endGettingReady()
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
            presenter.showCountdown(remaining, in: choice.regions.map(\.frame), cancel: { [weak self] in self?.cancel() })
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
        presenter.stopWatchingEscape()
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

    /// Throws away what's recorded and starts again at once, recording, or paused if `pause()`
    /// came meanwhile. Refused while another restart is under way, or while a recording that ended
    /// on its own is saving; a `stop()`, `discard()`, or early end that comes while it waits on the
    /// recorder wins.
    func restart() async {
        guard !noticeEarlyEnd(), phase.isRecording, !restartInFlight else { return }
        restartInFlight = true
        defer { restartInFlight = false }
        do {
            try await recorder.restart()
        } catch {
            // A stop or discard took over meanwhile.
            guard phase.isRecording else { return }
            end(showing: error)
            return
        }
        guard !noticeEarlyEnd(), phase.isRecording else { return }
        for observer in restartObservers { observer() }
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
    /// deletes that capture once it's saved, and nothing opens for it.
    func discard() async {
        if noticeEarlyEnd() {
            discardsEarlyEnd = true
            await earlyEndSaved()
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
    /// anything: they stay in the captures folder. Footage is never thrown away here.
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

    // MARK: Screenshots

    private func takeScreenshot(_ choice: ScreencastChoice, settings: ScreencastPreferences, generation: Int) async {
        do {
            let screenshot = try await ScreencastScreenshots.take(
                choice.target,
                system: system,
                ownProcessID: ownProcessID,
                capturesFolder: settings.capturesFolder,
                takenAt: now(),
                fileManager: fileManager
            )
            guard generation == self.generation else { return }
            logger.info("screencast screenshot saved displays=\(screenshot.images.count, privacy: .public)")
            finish(with: .screenshot(screenshot))
        } catch {
            guard generation == self.generation else { return }
            end(showing: error)
        }
    }

    // MARK: Ending

    private func finish(with result: ScreencastCaptureResult) {
        choice = nil
        phase = .idle
        if opensFinishedCaptures {
            onCaptureFinished?(result)
        } else {
            logger.info("screencast capture kept while turned off")
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
            presenter.showMessage(ScreencastMessages.text(for: failure, kind: choice?.kind ?? .video))
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

/// What Screencast says when a capture can't start or save.
enum ScreencastMessages {
    static func text(for failure: ScreencastFailure, kind: ScreencastCaptureKind) -> String {
        switch failure {
        case .screenRecordingDenied:
            "Turn on Screen Recording for Keybumps in System Settings to capture your screen."
        case .targetUnavailable:
            "That window or screen isn’t there anymore."
        case .captureFailed:
            kind == .video ? "The recording couldn’t start. Try again." : "The screenshot couldn’t be taken. Try again."
        case .stoppedByMacOS:
            "macOS stopped the recording."
        case .writerFailed:
            "The capture couldn’t be saved. Check that the disk has room."
        case .folderUnavailable:
            "The captures folder couldn’t be created."
        case .noFootage:
            "Nothing was recorded."
        }
    }

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
