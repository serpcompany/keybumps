import AppKit
import CoreGraphics
import Foundation

/// The app's overlays with the picker left out: the smoke test chooses through the picker's model
/// instead, so the windows that would cover every screen never open. Everything else (the area
/// highlight, the countdown, Escape, messages, "Getting ready…") goes to the app's own.
@MainActor
final class ScreencastSmokePresenter: ScreencastOverlayPresenting {
    private let base: any ScreencastOverlayPresenting
    /// The picker the controller would show now, and its Record.
    private(set) var picker: ScreencastPickerModel?
    private(set) var record: (() -> Void)?
    /// The last message shown, to tell why a capture ended. Keybumps's own words, never written
    /// to the result.
    private(set) var lastMessage: String?

    init(base: any ScreencastOverlayPresenting) {
        self.base = base
    }

    func showPicker(_ model: ScreencastPickerModel, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        picker = model
        record = confirm
    }

    func closePicker() {
        picker = nil
        record = nil
    }

    func showCountdown(_ remaining: Int, in frames: [CGRect], cancel: @escaping () -> Void) {
        base.showCountdown(remaining, in: frames, cancel: cancel)
    }

    func closeCountdown() { base.closeCountdown() }
    func showAreaHighlight(_ area: ScreencastPickedArea) { base.showAreaHighlight(area) }
    func closeAreaHighlight() { base.closeAreaHighlight() }
    func watchEscape(_ handler: @escaping () -> Void) { base.watchEscape(handler) }
    func stopWatchingEscape() { base.stopWatchingEscape() }

    func showMessage(_ message: String) {
        lastMessage = message
        base.showMessage(message)
    }

    func showGettingReady() { base.showGettingReady() }
    func hideGettingReady() { base.hideGettingReady() }

    func forgetMessage() {
        lastMessage = nil
    }
}

/// The pieces of Screencast the smoke test drives: the recorder, the controller, the control bar,
/// and the overlays, wired by Record Screen's own `ScreencastModule.wiredController`. Nothing
/// opens the review panel, no shortcut is registered, and the menu bar is left alone. The app's
/// pieces are real; tests pass fakes.
@available(macOS 15, *)
@MainActor
struct ScreencastSmokeRig {
    let controller: ScreencastController
    let presenter: ScreencastSmokePresenter
    let recordingControls: ScreencastRecordingControls
    let overlays: ScreencastOverlaysWiring
    /// What the picker reads the screen with, to wait for the script's window.
    let pickerSystem: any ScreencastPickerSystem
    let ownProcessID: pid_t
    /// Where the captures are saved: a folder of the smoke test's own, deleted when it ends.
    let capturesFolder: URL
    /// The smoke test's own defaults, for the area, the picker's mode and screen, the drawing tools,
    /// and the bar's position.
    let defaults: UserDefaults

    /// Settings › Screengrabs for the smoke test: no microphone, no Mac's sound, no countdown, no
    /// shortcuts or click highlights, and its own captures folder.
    static func preferences(capturesFolder: URL) -> ScreencastPreferences {
        ScreencastPreferences(
            recordsMicrophone: false,
            recordsSystemAudio: false,
            countdownSeconds: 0,
            showsShortcuts: false,
            highlightsClicks: false,
            capturesFolder: capturesFolder
        )
    }

    static func make(
        recorder: ScreencastRecorder,
        captureSystem: any ScreencastCaptureSystem,
        pickerSystem: any ScreencastPickerSystem,
        presenter base: any ScreencastOverlayPresenting,
        screens: @escaping @MainActor () -> ScreencastScreenLayout,
        defaults: UserDefaults,
        capturesFolder: URL,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> ScreencastSmokeRig {
        let presenter = ScreencastSmokePresenter(base: base)
        let preferences = preferences(capturesFolder: capturesFolder)
        // As `ScreencastModule.init` makes them, with no menu bar, key display, or Keystrokes, and
        // the smoke test's own defaults.
        let recordingControls = ScreencastRecordingControls(
            menuBar: nil,
            placement: ScreencastControlBarPlacement(defaults: defaults)
        )
        let overlays = ScreencastOverlaysWiring(
            keyDisplay: nil,
            drawingMemory: ScreencastDrawingMemory(defaults: defaults),
            keystrokesConfiguration: { nil },
            displays: { ScreencastOverlaysWiring.displays(in: screens(), connected: ScreencastOverlayDisplay.connected) }
        )
        let controller = ScreencastModule.wiredController(
            recorder: recorder,
            captureSystem: captureSystem,
            pickerSystem: pickerSystem,
            presenter: presenter,
            areaMemory: ScreencastAreaMemory(defaults: defaults),
            pickerMemory: ScreencastPickerMemory(defaults: defaults),
            preferences: { preferences },
            // Its switches, all off, never become the person's settings.
            saveSwitches: { _ in },
            screens: screens,
            microphoneAvailable: { false },
            ownProcessID: ownProcessID,
            recordingControls: recordingControls,
            overlays: overlays
        )
        return ScreencastSmokeRig(
            controller: controller,
            presenter: presenter,
            recordingControls: recordingControls,
            overlays: overlays,
            pickerSystem: pickerSystem,
            ownProcessID: ownProcessID,
            capturesFolder: capturesFolder,
            defaults: defaults
        )
    }

    /// Forgets the area drawn for the last capture, so the next one draws its own.
    func clearAreaMemory() {
        defaults.removeObject(forKey: ScreencastAreaMemory.key)
    }
}

/// Runs each `ScreencastSmokeMode` through the real capture path with no mouse or keyboard input
/// (#470): Record Screen (`ScreencastController.open()`), the choice made through the picker's
/// model as its clicks and drags would, Record, the control bar and overlays as recording starts,
/// two seconds of recording, Stop, and the saved files checked and deleted. Only the picker's
/// windows, the countdown (set to none), and the review panel are skipped.
///
/// The window capture takes only the blank window `smoke-screencast.sh` shows from a helper
/// process of its own, found by that process's ID (`environment.windowProcessID`), whatever is in
/// front of it. Without that window on screen in time it fails with `noSmokeWindow`; no other
/// window is ever taken instead.
///
/// Every step has a time limit, so a hang fails the capture at the stage it reached instead of
/// holding the app. After each capture the controller is brought back to idle (a start cancelled,
/// a recording discarded, a late capture waited for) and everything in the captures folder is
/// deleted, whichever way the capture ended; if the controller can't be brought back, the rest are
/// skipped. The captures folder is deleted at the end whatever happened, and the result is written
/// after every stage.
@available(macOS 15, *)
@MainActor
final class ScreencastSmokeRunner {
    struct Configuration {
        var modes = ScreencastSmokeMode.allCases
        var recordSeconds: TimeInterval = 2
        /// A sane length for a 2-second recording: its first frame comes a moment after it starts,
        /// and the file runs to Stop.
        var durations: ClosedRange<TimeInterval> = 1...4
        var pickerTimeout: TimeInterval = 15
        var startTimeout: TimeInterval = 20
        var finishTimeout: TimeInterval = 20
        var checkTimeout: TimeInterval = 15
        var windDownTimeout: TimeInterval = 10
        /// How long the script's window has to appear on screen, and how often the screen is read
        /// for it.
        var windowTimeout: TimeInterval = 10
        var windowPollInterval: Duration = .milliseconds(250)
        var pollInterval: Duration = .milliseconds(20)
    }

    struct Environment {
        var macOS: String
        var displayCount: Int
        /// Whether Keybumps has Screen Recording, read without asking (`CGPreflightScreenCaptureAccess`).
        var screenRecordingGranted: () -> Bool
        /// The display to record a screen of and draw an area on.
        var mainDisplay: () -> CGDirectDisplayID
        /// The script's helper, whose blank window is the only one the window capture takes; nil
        /// when the script couldn't show it.
        var windowProcessID: pid_t?
        var resultURL: URL
        var fileManager: FileManager = .default
        /// Waits while a video records; tests move their clock here.
        var record: @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    }

    private let rig: ScreencastSmokeRig
    private let inspector: ScreencastSmokeInspector
    private let configuration: Configuration
    private let environment: Environment
    private(set) var report: ScreencastSmokeReport
    private var current = 0
    /// The capture the controller handed over for the capture under way.
    private var saved: ScreencastCaptureResult?

    init(rig: ScreencastSmokeRig, inspector: ScreencastSmokeInspector, configuration: Configuration = Configuration(), environment: Environment) {
        self.rig = rig
        self.inspector = inspector
        self.configuration = configuration
        self.environment = environment
        report = ScreencastSmokeReport(macOS: environment.macOS, displayCount: environment.displayCount, modes: configuration.modes)
    }

    /// Runs every capture and returns the result, also written to `environment.resultURL`.
    func run() async -> ScreencastSmokeReport {
        write()
        guard environment.screenRecordingGranted() else {
            report.errorCategory = ScreencastSmokeFailure.permissionDenied.rawValue
            return finish()
        }
        try? environment.fileManager.createDirectory(at: rig.capturesFolder, withIntermediateDirectories: true)
        rig.controller.onCaptureFinished = { [weak self] result in self?.saved = result }
        var windsDown = true
        for index in report.captures.indices {
            current = index
            guard windsDown else {
                report.captures[index].errorCategory = ScreencastSmokeFailure.skipped.rawValue
                continue
            }
            await capture(index)
            windsDown = await windDown()
        }
        rig.controller.onCaptureFinished = nil
        return finish()
    }

    // MARK: One capture

    private func capture(_ index: Int) async {
        let started = ContinuousClock.now
        saved = nil
        rig.presenter.forgetMessage()
        rig.clearAreaMemory()
        do {
            try await perform(report.captures[index].mode)
            report.captures[index].passed = true
        } catch {
            report.captures[index].errorCategory = Self.category(of: error)
        }
        report.captures[index].timings.totalMs = Self.milliseconds(since: started)
        write()
    }

    private func perform(_ mode: ScreencastSmokeMode) async throws {
        let controller = rig.controller
        enter(.opening)
        if mode.target == .window { try await waitForSmokeWindow() }
        let opened = ContinuousClock.now
        controller.open()
        guard controller.phase == .picking, let model = controller.picker else { throw ScreencastSmokeFailure.openRefused }
        try await waitUntil(configuration.pickerTimeout) { self.rig.presenter.picker === model }
        report.captures[current].timings.pickerMs = Self.milliseconds(since: opened)

        enter(.picking)
        let expected = try choose(mode, on: model)
        guard let choice = model.choice(), choice.target == expected, choice.audio == .none,
              let record = rig.presenter.record else { throw ScreencastSmokeFailure.noChoice }
        let confirmed = ContinuousClock.now
        record()
        enter(.chosen)

        let late = try await recordVideo(confirmed: confirmed)
        guard let result = saved else { throw endReason() }
        enter(.saved)

        let checking = ContinuousClock.now
        do {
            try await check(result)
        } catch {
            try? environment.fileManager.removeItem(at: result.folder)
            throw error
        }
        report.captures[current].timings.checkMs = Self.milliseconds(since: checking)
        enter(.checked)

        try? environment.fileManager.removeItem(at: result.folder)
        guard !environment.fileManager.fileExists(atPath: result.folder.path) else { throw ScreencastSmokeFailure.cleanupFailed }
        enter(.cleanedUp)
        if let late { throw late }
    }

    /// Waits for recording, records, and stops. Returns what's wrong with a recording that still
    /// saved a file (it ended early, or the bar or overlays weren't up), so its file is checked and
    /// deleted first.
    private func recordVideo(confirmed: ContinuousClock.Instant) async throws -> Error? {
        let controller = rig.controller
        enter(.starting)
        try await waitUntil(configuration.startTimeout) { controller.phase == .recording || controller.phase == .idle }
        guard controller.phase == .recording else { throw endReason() }
        report.captures[current].timings.startMs = Self.milliseconds(since: confirmed)
        enter(.recording)

        let controlBarShown = rig.recordingControls.bar?.isShown == true
        let overlaysShown = rig.overlays.overlays != nil
        report.captures[current].controlBarShown = controlBarShown
        report.captures[current].overlaysShown = overlaysShown
        report.captures[current].overlayWindows = rig.overlays.includedWindowIDs.count
        let recording = ContinuousClock.now
        try await environment.record(configuration.recordSeconds)
        report.captures[current].timings.recordMs = Self.milliseconds(since: recording)

        enter(.finishing)
        let stopping = ContinuousClock.now
        if controller.phase.isRecording {
            try await Self.within(configuration.finishTimeout) { await controller.stop() }
        } else {
            // It ended on its own while recording: what it saved arrives once it's written.
            try await waitUntil(configuration.finishTimeout) { self.saved != nil || controller.phase == .idle }
        }
        report.captures[current].timings.finishMs = Self.milliseconds(since: stopping)

        if case .video(let capture) = saved, let failure = capture.endedEarly { return failure }
        if !controlBarShown { return ScreencastSmokeFailure.controlBarMissing }
        if !overlaysShown { return ScreencastSmokeFailure.overlaysMissing }
        return nil
    }

    // MARK: Choosing

    /// Makes the picker's choice for `mode` through its model, as its clicks and drags would, with
    /// every switch off, and returns the target it should record.
    private func choose(_ mode: ScreencastSmokeMode, on model: ScreencastPickerModel) throws -> ScreencastTarget {
        model.target = mode.target
        model.recordsMicrophone = false
        model.recordsSystemAudio = false
        model.showsShortcuts = false
        model.highlightsClicks = false
        let layout = model.layout
        guard let screen = layout.screen(environment.mainDisplay()) ?? layout.screens.first else {
            throw ScreencastSmokeFailure.noChoice
        }
        switch mode.target {
        case .screen:
            model.clickScreen(screen)
            return .display(screen.id)
        case .area:
            let area = Self.area(in: screen.frame)
            model.pressArea(at: CGPoint(x: area.minX, y: area.minY), on: screen)
            model.dragArea(to: CGPoint(x: area.maxX, y: area.maxY))
            model.releaseArea()
            return .area(display: screen.id, rect: ScreencastTarget.displayLocalRect(fromAppKit: area, screenFrame: screen.frame))
        case .window:
            guard let processID = environment.windowProcessID,
                  let window = model.windows.first(where: { $0.processID == processID }) else {
                throw ScreencastSmokeFailure.noSmokeWindow
            }
            // First in the list, so a click on its middle picks it even where another window is in
            // front of it.
            model.windows = [window] + model.windows.filter { $0.id != window.id }
            let frame = layout.appKitRect(fromTopLeft: window.frame)
            model.clickWindow(at: CGPoint(x: frame.midX, y: frame.midY))
            return .window(window.id)
        }
    }

    /// Waits until the script's window is on screen as the picker offers windows, reading the
    /// screen as the picker does. Only that process's window counts: any other could be anything
    /// of the person's. `noSmokeWindow` means the screen was read without that window in it; when
    /// no read worked in time, the capture fails with the last read's own reason instead.
    private func waitForSmokeWindow() async throws {
        guard let processID = environment.windowProcessID else { throw ScreencastSmokeFailure.noSmokeWindow }
        let system = rig.pickerSystem
        let ownProcessID = rig.ownProcessID
        let deadline = ContinuousClock.now + .seconds(configuration.windowTimeout)
        var readFailure: Error?
        var readTheScreen = false
        while true {
            do {
                let content = try await Self.within(configuration.windowTimeout) { try await system.content() }
                readTheScreen = true
                if ScreencastWindowPicking.pickableWindows(in: content, ownProcessID: ownProcessID, transparent: system.transparentWindows())
                    .contains(where: { $0.processID == processID }) {
                    return
                }
            } catch {
                readFailure = error
            }
            guard ContinuousClock.now < deadline else {
                throw readTheScreen ? ScreencastSmokeFailure.noSmokeWindow : readFailure ?? ScreencastSmokeFailure.noSmokeWindow
            }
            try await Task.sleep(for: configuration.windowPollInterval)
        }
    }

    /// A fixed area in the middle of `frame` (AppKit's space): up to 640 × 360 points.
    static func area(in frame: CGRect) -> CGRect {
        let width = min(640, (frame.width / 2).rounded(.down))
        let height = min(360, (frame.height / 2).rounded(.down))
        return CGRect(x: (frame.midX - width / 2).rounded(), y: (frame.midY - height / 2).rounded(), width: width, height: height)
    }

    // MARK: Checking

    private func check(_ result: ScreencastCaptureResult) async throws {
        let fileManager = environment.fileManager
        switch result {
        case .video(let capture):
            guard capture.videos.count == 1, let video = capture.videos.first else { throw ScreencastSmokeFailure.wrongFileCount }
            report.captures[current].bytes = try ScreencastSmokeChecks.size(of: video.file, fileManager: fileManager)
            let inspector = inspector
            let facts: ScreencastSmokeVideoFacts
            do {
                facts = try await Self.within(configuration.checkTimeout) { try await inspector.video(video.file) }
            } catch let failure as ScreencastSmokeFailure where failure == .timeout {
                throw failure
            } catch {
                throw ScreencastSmokeFailure.unreadableVideo
            }
            report.captures[current].durationSeconds = (facts.duration * 1000).rounded() / 1000
            report.captures[current].pixelWidth = facts.pixelWidth
            report.captures[current].pixelHeight = facts.pixelHeight
            try ScreencastSmokeChecks.check(facts, durations: configuration.durations)
        }
    }

    // MARK: Winding down

    /// Brings the controller back to idle after a capture: a picker or a start is cancelled, a
    /// recording discarded, and a capture still being saved waited for. Then everything in the
    /// captures folder is deleted, whichever way the capture ended, so nothing it saved waits for
    /// the end. False when the controller doesn't get back in time.
    private func windDown() async -> Bool {
        let controller = rig.controller
        switch controller.phase {
        case .idle, .finishing:
            break
        case .picking, .countingDown, .starting:
            controller.cancel()
        case .recording, .paused:
            try? await Self.within(configuration.windDownTimeout) { await controller.discard() }
        }
        let settled: Bool
        do {
            try await waitUntil(configuration.windDownTimeout) {
                controller.phase == .idle && Self.isFree(controller.recorder.state)
            }
            settled = true
        } catch {
            settled = false
        }
        if let saved { try? environment.fileManager.removeItem(at: saved.folder) }
        saved = nil
        emptyCapturesFolder()
        return settled
    }

    private func emptyCapturesFolder() {
        let fileManager = environment.fileManager
        let items = (try? fileManager.contentsOfDirectory(at: rig.capturesFolder, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? fileManager.removeItem(at: item) }
    }

    private static func isFree(_ state: ScreencastRecorderState) -> Bool {
        switch state {
        case .idle, .failed: true
        case .starting, .recording, .paused, .stopping: false
        }
    }

    private func finish() -> ScreencastSmokeReport {
        try? environment.fileManager.removeItem(at: rig.capturesFolder)
        report.cleanedUp = !environment.fileManager.fileExists(atPath: rig.capturesFolder.path)
        report.passed = report.errorCategory == nil && report.cleanedUp && report.captures.allSatisfy(\.passed)
        report.complete = true
        write()
        return report
    }

    // MARK: Reporting

    private func enter(_ stage: ScreencastSmokeStage) {
        report.captures[current].stage = stage
        write()
    }

    private func write() {
        try? report.write(to: environment.resultURL, fileManager: environment.fileManager)
    }

    /// Why a capture ended without a file: the recorder's failure, else the failure whose message
    /// the controller showed, else `ended`.
    private func endReason() -> Error {
        if case .failed(let failure) = rig.controller.recorder.state { return failure }
        if let message = rig.presenter.lastMessage, let failure = Self.failure(shownAs: message) { return failure }
        return ScreencastSmokeFailure.ended
    }

    private static let failures: [ScreencastFailure] = [
        .screenRecordingDenied, .targetUnavailable, .captureFailed, .stoppedByMacOS, .writerFailed, .folderUnavailable, .noFootage,
    ]

    static func failure(shownAs message: String) -> ScreencastFailure? {
        failures.first { failure in
            message == ScreencastMessages.text(for: failure)
                || message == ScreencastMessages.endedEarly(failure, kept: false)
                || message == ScreencastMessages.endedEarly(failure, kept: true)
        }
    }

    static func category(of error: Error) -> String {
        if let failure = error as? ScreencastSmokeFailure { return failure.rawValue }
        if let failure = error as? ScreencastFailure { return failure.rawValue }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded())
    }

    // MARK: Time limits

    /// Polls `condition` until it holds, or throws `timeout` after `seconds`.
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ScreencastSmokeFailure.timeout }
            try await Task.sleep(for: configuration.pollInterval)
        }
    }

    /// Runs `operation`, or throws `timeout` once `seconds` pass first. An operation that hangs is
    /// cancelled and left behind rather than waited for, so it can't hold up the rest.
    static func within<T>(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = ScreencastSmokeRace<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            let work = Task { @MainActor in
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.setTimer(Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, race.finish(.failure(ScreencastSmokeFailure.timeout)) else { return }
                work.cancel()
            })
        }
    }
}

/// A step and its time limit: whichever finishes first resumes the caller, once.
private final class ScreencastSmokeRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var timer: Task<Void, Never>?

    func begin(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        let finished = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            self.timer = timer
            return false
        }
        if finished { timer.cancel() }
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<T, Error>?, Task<Void, Never>?) in
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer)
        }
        guard let continuation else { return false }
        timer?.cancel()
        continuation.resume(with: result)
        return true
    }
}
