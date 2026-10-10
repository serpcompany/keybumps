import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import OSLog
import QuartzCore

/// Records the screen and its sound to files: Screencast's recording engine, with no UI of its
/// own. The picker starts it, the control bar pauses, resumes, restarts, stops, or discards it and
/// switches the sounds, the overlays add their windows to the video, and the review panel takes
/// the capture `stop()` returns.
///
/// - Each display recorded gets its own `SCStream` and its own file; one display-wide sound stream
///   feeds every file (`ScreencastCaptureSystem.makeAudioStream`).
/// - Pausing keeps the streams running and drops what arrives while paused; the files and
///   `elapsed` leave the paused time out. Restarting keeps them running too, and starts new files.
/// - Switching a sound off keeps its source running and writes silence in its place. Without
///   Microphone access, or when the microphone fails, the Mac's sound records on alone.
/// - Keybumps's own windows stay out of the video, except the overlays added with
///   `includeOverlayWindow(_:)`.
/// - A recording ends once: by `stop()`, `discard()`, or the first stream or file that fails. A
///   recording that stops on its own (the display went away, the disk filled up) keeps what it
///   captured and reports it once through `onEndedEarly`; later reports are ignored.
///
/// Adapted from Screendrop's `ScreenRecordingManager` (CC0-1.0, see LICENSE.screendrop): footage
/// is never silently discarded, and App Nap and idle sleep wait while recording. Window following
/// and own-window filtering after Shotnix's `RecordingEngine` (MIT, see LICENSE.shotnix).
@available(macOS 15, *)
@MainActor
@Observable
final class ScreencastRecorder {
    private(set) var state: ScreencastRecorderState = .idle
    /// What's being recorded; nil while idle.
    private(set) var target: ScreencastTarget?
    private(set) var microphone: ScreencastAudioSourceState = .notRecorded
    private(set) var systemAudio: ScreencastAudioSourceState = .notRecorded
    /// How loud the microphone is, 0…1, for the control bar's meter: 0 while it's off, paused, or
    /// not recorded.
    private(set) var microphoneLevel: Float = 0
    /// Recorded seconds, paused time excluded. Updated a few times a second while recording.
    private(set) var elapsed: TimeInterval = 0
    /// Keybumps windows shown in the video (drawing, click rings, shortcuts). They stay until
    /// removed; a window that closed is skipped.
    private(set) var overlayWindows: Set<CGWindowID> = []

    /// Called once when a recording ends without `stop()` or `discard()`: a stream or a file
    /// failed. The capture is what was saved, nil if nothing was. The state is then `.failed(reason)`.
    @ObservationIgnored var onEndedEarly: ((ScreencastCapture?, ScreencastFailure) -> Void)?

    @ObservationIgnored private let system: any ScreencastCaptureSystem
    @ObservationIgnored private let writers: any ScreencastWriterFactory
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let hostClock: () -> Double
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let ownProcessID: pid_t
    @ObservationIgnored private let microphoneGranted: () -> Bool
    @ObservationIgnored private let tickInterval: TimeInterval?
    @ObservationIgnored private let followInterval: TimeInterval
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    @ObservationIgnored private var session: Session?
    /// Bumped by every start, and when a recording starts ending, so a superseded start or a late
    /// report does nothing.
    @ObservationIgnored private var generation = 0
    /// Fired once the start in progress is over, whichever way, so `discard()` can wait for it.
    @ObservationIgnored private var startFinished: Signal?

    /// - Parameters:
    ///   - system: ScreenCaptureKit; inert in the unit-test host unless a test passes a fake.
    ///   - hostClock: Host-clock seconds, the clock ScreenCaptureKit stamps samples with.
    ///   - microphoneGranted: Whether Keybumps has Microphone access, read silently as each
    ///     recording starts: the app passes its `PermissionCoordinator`'s. Without it, a recording
    ///     asks only for the Mac's sound. It never prompts.
    ///   - tickInterval: How often `elapsed` and Keybumps's own windows are checked while recording;
    ///     nil for no timers (tests call `tick()` and `followTick()`).
    ///   - followInterval: How often a window recording checks where its window is.
    init(
        system: (any ScreencastCaptureSystem)? = nil,
        writers: any ScreencastWriterFactory = AVAssetScreencastWriterFactory(),
        fileManager: FileManager = .default,
        hostClock: @escaping () -> Double = CACurrentMediaTime,
        now: @escaping () -> Date = Date.init,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        microphoneGranted: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        tickInterval: TimeInterval? = 0.25,
        followInterval: TimeInterval = 1.0 / 20
    ) {
        self.system = system ?? ScreenCaptureKitCaptureSystem.current
        self.writers = writers
        self.fileManager = fileManager
        self.hostClock = hostClock
        self.now = now
        self.ownProcessID = ownProcessID
        self.microphoneGranted = microphoneGranted
        self.tickInterval = tickInterval
        self.followInterval = followInterval
    }

    // MARK: Starting

    /// Starts recording `target` with `audio` into a new `<timestamp>` folder in `capturesFolder`
    /// (`~/Documents/Keybumps/captures/` by default), once every stream is running. Throws a
    /// `ScreencastFailure` (and the state becomes `.failed`), `ScreencastRecorderError.alreadyRecording`,
    /// or `CancellationError` when `discard()` cancelled it.
    func start(
        target: ScreencastTarget,
        audio: ScreencastAudio,
        capturesFolder: URL = ProductPaths.keybumps().captures,
        options: ScreencastOptions = ScreencastOptions()
    ) async throws {
        switch state {
        case .idle, .failed: break
        default: throw ScreencastRecorderError.alreadyRecording
        }
        generation += 1
        let generation = generation
        state = .starting
        self.target = target
        elapsed = 0
        let finished = Signal()
        startFinished = finished
        defer {
            finished.fire()
            if startFinished === finished { startFinished = nil }
        }
        var started: Session?
        do {
            // Keybumps's windows before the snapshot, never after: one that opens in between is in
            // the snapshot's filter already, or missing from this list, so the next tick rebuilds.
            let ownWindows = system.ownVisibleWindows()
            let content = try await system.content()
            try ensureCurrent(generation)
            let overlays = overlayWindows
            let streams = try Self.streamPlans(for: target, content: content, ownProcessID: ownProcessID, overlays: overlays, options: options)
            let session = Session(
                generation: generation,
                target: target,
                audio: audio,
                options: options,
                capturesFolder: capturesFolder,
                streams: streams,
                content: content,
                router: makeRouter(generation: generation)
            )
            session.ownWindows = ownWindows
            started = session

            var asked = audio
            if audio.microphone, !microphoneGranted() {
                // No Microphone access: asking for it would cost the Mac's sound too.
                asked.microphone = false
                session.failedAudio.insert(.microphone)
            }
            if !asked.sources.isEmpty {
                // Started before the picture, so a microphone that's slow to start has warmed up by
                // the first frame; anything it hears before that is trimmed. The files get a track
                // for each sound that started.
                await startAudio(asked, for: session)
                try ensureCurrent(generation)
            }
            try openFiles(for: session, switchedOffAt: nil)
            for (index, stream) in session.streams.enumerated() {
                let videoStream = try system.makeVideoStream(
                    plan: stream.plan,
                    configuration: stream.configuration,
                    content: content,
                    handler: videoHandler(session: session, index: index)
                )
                session.streams[index].stream = videoStream
                try await videoStream.start()
                try ensureCurrent(generation)
            }

            if case .window(let id) = target { session.followedFrame = content.window(id)?.frame }
            self.session = session
            session.timeline.start(at: hostClock())
            session.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording a screencast"
            )
            state = .recording
            publishAudioStates(of: session)
            startTicking(session)
            if overlayWindows != overlays {
                // An overlay was added or removed while the streams were starting.
                scheduleFilterRebuild(for: session)
            }
            logger.info("screencast started target=\(target.kind, privacy: .public) displays=\(session.streams.count, privacy: .public) microphone=\(self.microphone == .on, privacy: .public) systemAudio=\(self.systemAudio == .on, privacy: .public)")
        } catch {
            if let started { await tearDown(started, deletingFolder: true) }
            guard !(error is CancellationError) else { throw error }
            let failure = (error as? ScreencastFailure) ?? .captureFailed
            if generation == self.generation {
                resetPresentation()
                state = .failed(failure)
            }
            logger.error("screencast start failed category=\(failure.rawValue, privacy: .public)")
            throw failure
        }
    }

    /// Starts the sound stream for `audio`. A microphone that can't start (no device, or access
    /// gone) costs only the microphone: the Mac's sound is tried again on its own. The video
    /// matters more than either, so it records on without them.
    private func startAudio(_ audio: ScreencastAudio, for session: Session) async {
        var attempt = audio
        while !attempt.sources.isEmpty {
            session.audioStreamToken += 1
            let stream: any ScreencastStream
            do {
                stream = try system.makeAudioStream(
                    audio: attempt,
                    content: session.content,
                    handler: audioHandler(session: session, token: session.audioStreamToken)
                )
            } catch {
                logger.error("screencast audio stream not made microphone=\(attempt.microphone, privacy: .public) category=\(Self.category(of: error), privacy: .public)")
                break
            }
            session.audioStream = stream
            session.audioStreamSources = attempt
            do {
                try await stream.start()
                return
            } catch {
                session.audioStream = nil
                logger.error("screencast audio stream failed microphone=\(attempt.microphone, privacy: .public) category=\(Self.category(of: error), privacy: .public)")
                guard attempt.microphone, attempt.systemAudio else { break }
                session.failedAudio.insert(.microphone)
                attempt.microphone = false
            }
        }
        session.audioStreamSources = .none
        session.failedAudio.formUnion(attempt.sources)
    }

    /// The streams a target needs, one per display, with what each shows and reads.
    static func streamPlans(
        for target: ScreencastTarget,
        content: ScreencastContent,
        ownProcessID: pid_t,
        overlays: Set<CGWindowID>,
        options: ScreencastOptions
    ) throws -> [StreamPlan] {
        func displayStream(_ display: ScreencastContent.Display, area: CGRect?) -> StreamPlan {
            let geometry = area.map { ScreencastCaptureGeometry.area($0, displaySize: display.frame.size, scale: display.scale) }
                ?? .display(size: display.frame.size, scale: display.scale)
            return StreamPlan(
                source: area.map { .area(display.id, $0) } ?? .display(display.id),
                plan: ScreencastCaptureFilter.displayPlan(display: display.id, ownProcessID: ownProcessID, overlays: overlays, content: content),
                configuration: configuration(geometry, options: options, scalesToFit: false)
            )
        }

        switch target {
        case .display(let id):
            guard let display = content.display(id) else { throw ScreencastFailure.targetUnavailable }
            return [displayStream(display, area: nil)]
        case .everyDisplay:
            guard !content.displays.isEmpty else { throw ScreencastFailure.targetUnavailable }
            // Left to right, then top to bottom: video-1 is the leftmost display.
            let displays = content.displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            return displays.map { displayStream($0, area: nil) }
        case .area(let id, let rect):
            guard let display = content.display(id) else { throw ScreencastFailure.targetUnavailable }
            return [displayStream(display, area: rect)]
        case .window(let id):
            guard let window = content.window(id),
                  let plan = ScreencastCaptureFilter.windowPlan(window: id, ownProcessID: ownProcessID, overlays: overlays, content: content),
                  let display = content.display(plan.displayID) else { throw ScreencastFailure.targetUnavailable }
            let geometry = ScreencastCaptureGeometry.window(frame: window.frame, displayFrame: display.frame, scale: display.scale)
            return [StreamPlan(source: .window(id), plan: plan, configuration: configuration(geometry, options: options, scalesToFit: true))]
        }
    }

    private static func configuration(_ geometry: ScreencastCaptureGeometry, options: ScreencastOptions, scalesToFit: Bool) -> ScreencastStreamConfiguration {
        ScreencastStreamConfiguration(
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            sourceRect: geometry.sourceRect,
            framesPerSecond: options.framesPerSecond,
            showsCursor: options.showsCursor,
            showsMouseClicks: options.showsMouseClicks,
            scalesToFit: scalesToFit
        )
    }

    /// A new folder and a writer per stream, with a track for each sound still recording,
    /// attached to the router. On a restart, the sounds switched off are off in the new files from
    /// `switchedOffAt`, before any sample reaches them.
    private func openFiles(for session: Session, switchedOffAt host: Double?) throws {
        let startedAt = now()
        let folder: URL
        do {
            folder = try ScreencastCaptureFolder.create(in: session.capturesFolder, startedAt: startedAt, fileManager: fileManager)
        } catch {
            throw ScreencastFailure.folderUnavailable
        }
        session.folder = folder
        session.startedAt = startedAt
        let generation = session.generation
        let take = session.take
        let sources = session.audio.sources.filter { !session.failedAudio.contains($0) }
        var files: [any ScreencastMovieWriting] = []
        do {
            for (index, stream) in session.streams.enumerated() {
                files.append(try writers.makeWriter(
                    at: folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index)),
                    pixelWidth: stream.configuration.pixelWidth,
                    pixelHeight: stream.configuration.pixelHeight,
                    audio: sources,
                    options: session.options,
                    onFailure: { [weak self] in
                        Task { @MainActor in self?.endEarly(.writerFailed, generation: generation, take: take) }
                    }
                ))
            }
        } catch {
            for file in files { Task { await file.cancel() } }
            throw ScreencastFailure.writerFailed
        }
        if let host {
            for (source, isOff) in session.switchedOff where isOff {
                files.forEach { $0.setAudio(source, on: false, at: host) }
            }
        }
        session.router.attach(files)
    }

    private func ensureCurrent(_ generation: Int) throws {
        guard generation == self.generation, state == .starting else { throw CancellationError() }
    }

    // MARK: Pausing and sound

    func pause() {
        guard state == .recording, let session, session.phase == .live else { return }
        let host = hostClock()
        session.timeline.pause(at: host)
        session.router.writers.forEach { $0.pause(at: host) }
        state = .paused
        publishAudioStates(of: session)
        refreshElapsed()
    }

    func resume() {
        guard state == .paused, let session, session.phase == .live else { return }
        let host = hostClock()
        session.timeline.resume(at: host)
        session.router.writers.forEach { $0.resume(at: host) }
        state = .recording
        publishAudioStates(of: session)
        refreshElapsed()
    }

    /// Switches a recorded sound off (its track gets silence) or back on. Does nothing for a sound
    /// the recording started without, or one that failed.
    func setAudio(_ source: ScreencastAudioSource, on: Bool) {
        guard state.isActive, let session, session.phase == .live,
              session.audio.contains(source), !session.failedAudio.contains(source) else { return }
        let host = hostClock()
        session.router.writers.forEach { $0.setAudio(source, on: on, at: host) }
        session.switchedOff[source] = !on
        publishAudioStates(of: session)
    }

    /// `microphone`, `systemAudio`, and the meter, from the session's sounds.
    private func publishAudioStates(of session: Session) {
        func current(_ source: ScreencastAudioSource) -> ScreencastAudioSourceState {
            guard session.audio.contains(source) else { return .notRecorded }
            if session.failedAudio.contains(source) { return .failed }
            return session.switchedOff[source] == true ? .off : .on
        }
        microphone = current(.microphone)
        systemAudio = current(.systemAudio)
        let meters = microphone == .on && state == .recording
        session.router.setMetering(meters)
        if !meters { microphoneLevel = 0 }
    }

    /// The sound stream stopped mid-recording. The microphone shares it, so it's the likelier cause:
    /// the Mac's sound, if it was recording, gets a stream of its own, and the video goes on. A
    /// stream that carried only the Mac's sound isn't tried again; its track is silent from here.
    private func audioStreamStopped(generation: Int, token: Int) {
        guard generation == self.generation, let session, session.phase == .live, state.isActive,
              token == session.audioStreamToken else { return }
        let carried = session.audioStreamSources
        session.audioStream = nil
        session.audioStreamSources = .none
        logger.error("screencast audio stream stopped microphone=\(carried.microphone, privacy: .public) systemAudio=\(carried.systemAudio, privacy: .public)")
        if carried.microphone, carried.systemAudio {
            session.failedAudio.insert(.microphone)
            publishAudioStates(of: session)
            Task { await restartSystemAudio(for: session) }
        } else {
            session.failedAudio.formUnion(carried.sources)
            publishAudioStates(of: session)
        }
    }

    private func restartSystemAudio(for session: Session) async {
        await startAudio(ScreencastAudio(microphone: false, systemAudio: true), for: session)
        guard session === self.session, session.phase == .live else {
            // The recording ended while the stream started: it's no one's now.
            await session.audioStream?.stop()
            return
        }
        publishAudioStates(of: session)
    }

    // MARK: Overlays

    /// Shows one of Keybumps's windows in the video, such as the drawing layer. The control bar,
    /// the picker's dimming, and every other Keybumps window stay out. Returns once the running
    /// streams show it.
    func includeOverlayWindow(_ id: CGWindowID) async {
        guard overlayWindows.insert(id).inserted, let session else { return }
        await rebuildFilters(for: session)
    }

    func removeOverlayWindow(_ id: CGWindowID) async {
        guard overlayWindows.remove(id) != nil, let session else { return }
        await rebuildFilters(for: session)
    }

    // MARK: Updating the streams

    // Every change to a running stream (a rebuilt filter, a followed window's crop) goes through
    // one queue per recording, so at most one `updateContentFilter` or `updateConfiguration` is in
    // flight. Requests made meanwhile are coalesced: one rebuild for all of them, and only the
    // window's latest frame.

    /// Rebuilds the filters, returning once a rebuild that began after this call is done.
    private func rebuildFilters(for session: Session) async {
        guard session.phase == .live else { return }
        await withCheckedContinuation { continuation in
            session.rebuildWaiters.append(continuation)
            scheduleFilterRebuild(for: session)
        }
    }

    private func scheduleFilterRebuild(for session: Session) {
        session.needsFilterRebuild = true
        runUpdates(for: session)
    }

    private func runUpdates(for session: Session) {
        guard !session.isUpdating else { return }
        session.isUpdating = true
        Task { await drainUpdates(for: session) }
    }

    private func drainUpdates(for session: Session) async {
        while session === self.session, session.phase == .live {
            if session.needsFilterRebuild {
                session.needsFilterRebuild = false
                let waiters = session.rebuildWaiters
                session.rebuildWaiters = []
                await applyFilters(to: session)
                waiters.forEach { $0.resume() }
            } else if let frame = session.pendingWindowFrame {
                session.pendingWindowFrame = nil
                await follow(windowFrame: frame, in: session)
            } else {
                break
            }
        }
        session.isUpdating = false
        // The recording ended meanwhile: nothing more will be rebuilt.
        if session !== self.session || session.phase != .live {
            session.rebuildWaiters.forEach { $0.resume() }
            session.rebuildWaiters = []
        }
    }

    /// Re-reads what's on screen and gives every stream its filter again, if it changed.
    private func applyFilters(to session: Session) async {
        let ownWindows = system.ownVisibleWindows()
        guard let content = try? await system.content(), session === self.session, session.phase == .live else { return }
        session.content = content
        session.ownWindows = ownWindows
        for index in session.streams.indices {
            let stream = session.streams[index]
            let plan: ScreencastFilterPlan?
            switch stream.source {
            case .display(let id), .area(let id, _):
                plan = ScreencastCaptureFilter.displayPlan(display: id, ownProcessID: ownProcessID, overlays: overlayWindows, content: content)
            case .window(let id):
                plan = ScreencastCaptureFilter.windowPlan(window: id, ownProcessID: ownProcessID, overlays: overlayWindows, content: content)
            }
            guard let plan, plan != stream.plan, let running = stream.stream else { continue }
            do {
                try await running.update(plan: plan, content: content)
                session.streams[index].plan = plan
                if plan.displayID != stream.plan.displayID, case .window(let id) = stream.source,
                   let frame = content.window(id)?.frame, let display = content.display(plan.displayID) {
                    // The window moved to another display: read it there.
                    let geometry = ScreencastCaptureGeometry.window(frame: frame, displayFrame: display.frame, scale: display.scale)
                    try await running.update(sourceRect: geometry.sourceRect)
                }
            } catch {
                // Try again at the next change of Keybumps's windows.
                session.ownWindows = []
                logger.error("screencast filter update failed category=\(Self.category(of: error), privacy: .public)")
            }
        }
    }

    /// Moves a window recording's crop with its window. A resized window scales into the video; a
    /// window dragged to another display moves the stream there.
    private func follow(windowFrame frame: CGRect, in session: Session) async {
        guard let stream = session.streams.first, let running = stream.stream else { return }
        guard let display = session.content.display(mostOverlapping: frame), display.id == stream.plan.displayID else {
            await applyFilters(to: session)
            return
        }
        let geometry = ScreencastCaptureGeometry.window(frame: frame, displayFrame: display.frame, scale: display.scale)
        do {
            try await running.update(sourceRect: geometry.sourceRect)
        } catch {
            logger.error("screencast window follow failed category=\(Self.category(of: error), privacy: .public)")
        }
    }

    // MARK: While recording

    private func startTicking(_ session: Session) {
        guard let tickInterval else { return }
        session.timers.append(repeatingTimer(every: tickInterval) { $0.tick() })
        if case .window = session.target {
            session.timers.append(repeatingTimer(every: followInterval) { $0.followTick() })
        }
    }

    private func repeatingTimer(every interval: TimeInterval, _ action: @escaping (ScreencastRecorder) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Updates `elapsed`, and rebuilds the filters when Keybumps opened or closed a window while a
    /// filter names its windows one by one, or while overlays are registered (one may have just
    /// appeared).
    func tick() {
        guard let session, state.isActive, session.phase == .live else { return }
        refreshElapsed()
        let watches = !overlayWindows.isEmpty || session.streams.contains { $0.plan.dependsOnWindows(of: ownProcessID) }
        // Compared with the list the last rebuild read, which only a rebuild updates, so a rebuild
        // that failed is tried again.
        if watches, system.ownVisibleWindows() != session.ownWindows {
            scheduleFilterRebuild(for: session)
        }
    }

    /// A window recording: notices where its window is now, and moves the crop there.
    func followTick() {
        guard let session, state.isActive, session.phase == .live, case .window(let id) = session.target,
              let frame = system.windowFrame(id), frame != session.followedFrame,
              frame.width >= 2, frame.height >= 2 else { return }
        session.followedFrame = frame
        session.pendingWindowFrame = frame
        runUpdates(for: session)
    }

    func refreshElapsed() {
        guard let session else { return }
        elapsed = session.timeline.duration(at: hostClock())
    }

    // MARK: Restarting

    /// Throws away what's recorded so far and starts again on the same target and sounds, with the
    /// sounds switched as they are now. The streams keep running, so it starts at once.
    ///
    /// The old files are swapped for new ones with no suspension in between, so a second restart
    /// (or a `stop()`) that comes while this one is still deleting the old take acts on the new
    /// take: restarts are queued, each starting afresh, and nothing is left behind.
    func restart() async throws {
        guard state.isActive, let session, session.phase == .live else { throw ScreencastRecorderError.notRecording }
        let previousFiles = session.router.detach()
        let previousFolder = session.folder
        let host = hostClock()
        session.take += 1
        do {
            try openFiles(for: session, switchedOffAt: host)
        } catch {
            let failure = (error as? ScreencastFailure) ?? .writerFailed
            _ = claimEnding(session)
            for file in previousFiles { await file.cancel() }
            if let previousFolder { try? fileManager.removeItem(at: previousFolder) }
            await tearDown(session, deletingFolder: session.folder != previousFolder)
            if session === self.session { self.session = nil }
            resetPresentation()
            state = .failed(failure)
            throw failure
        }
        // ScreenCaptureKit sends a frame only when the screen changes: give the new files the last
        // one now, so they start here even on a still screen.
        session.router.reseed(at: host)
        session.timeline = ScreencastTimeline()
        session.timeline.start(at: host)
        elapsed = 0
        state = .recording
        publishAudioStates(of: session)
        logger.info("screencast restarted")
        for file in previousFiles { await file.cancel() }
        if let previousFolder { try? fileManager.removeItem(at: previousFolder) }
    }

    // MARK: Stopping

    /// Stops and keeps the recording: closes every file, writes a stereo mixdown beside each file
    /// with two sounds, and writes `meta.json`. Throws `ScreencastFailure.noFootage` (and deletes
    /// the folder) when nothing was recorded, or `ScreencastRecorderError.notRecording`.
    func stop() async throws -> ScreencastCapture {
        guard state.isActive, let session, claimEnding(session) else { throw ScreencastRecorderError.notRecording }
        return try await finish(session, endedEarly: nil)
    }

    /// Stops and deletes everything recorded. Cancels a start still in progress, and returns once
    /// its streams have stopped.
    func discard() async {
        switch state {
        case .starting:
            generation += 1
            state = .stopping
            await startFinished?.wait()
            resetPresentation()
            state = .idle
        case .recording, .paused:
            guard let session, claimEnding(session) else { return }
            await tearDown(session, deletingFolder: true)
            if session === self.session { self.session = nil }
            resetPresentation()
            state = .idle
            logger.info("screencast discarded")
        default:
            return
        }
    }

    /// Makes `session`'s end this caller's: true for the first of `stop()`, `discard()`, and the
    /// failures reported early, which all end a recording; false for every one after it. Decided
    /// before any suspension, so only one of them ever finishes or deletes the files.
    private func claimEnding(_ session: Session) -> Bool {
        guard session === self.session, session.phase == .live else { return false }
        session.phase = .ending
        generation += 1
        state = .stopping
        session.timers.forEach { $0.invalidate() }
        return true
    }

    private func finish(_ session: Session, endedEarly: ScreencastFailure?) async throws -> ScreencastCapture {
        let end = hostClock()
        microphoneLevel = 0
        session.router.setMetering(false)
        let files = session.router.detach()
        await stopStreams(of: session)

        var results: [ScreencastWriterResult] = []
        for file in files { results.append(await file.finish(at: end)) }
        var videos: [ScreencastVideo] = []
        for (index, (file, result)) in zip(files, results).enumerated() {
            guard result.hasFootage else {
                try? fileManager.removeItem(at: result.fileURL)
                continue
            }
            var mixdown: URL?
            if ScreencastAudioMixdown.isNeeded(audioTrackCount: file.audioSources.count), let folder = session.folder {
                let url = folder.appendingPathComponent(ScreencastCaptureFolder.mixdownName(index: index))
                do {
                    try await writers.writeMixdown(of: result.fileURL, to: url)
                    mixdown = url
                } catch {
                    // The full file still has every sound.
                    logger.error("screencast mixdown failed category=\(Self.category(of: error), privacy: .public)")
                }
            }
            videos.append(ScreencastVideo(
                file: result.fileURL,
                mixdown: mixdown,
                pixelWidth: file.pixelWidth,
                pixelHeight: file.pixelHeight,
                audioTracks: file.audioSources,
                duration: result.duration
            ))
        }
        endActivity(of: session)
        if session === self.session { self.session = nil }
        resetPresentation()

        let writerFailed = results.contains { $0.failed }
        guard let folder = session.folder, !videos.isEmpty else {
            if let folder = session.folder { try? fileManager.removeItem(at: folder) }
            let failure = endedEarly ?? (writerFailed ? .writerFailed : .noFootage)
            state = .failed(failure)
            logger.error("screencast stop kept nothing category=\(failure.rawValue, privacy: .public)")
            throw failure
        }
        let capture = ScreencastCapture(
            folder: folder,
            videos: videos,
            duration: videos.map(\.duration).max() ?? 0,
            endedEarly: endedEarly ?? (writerFailed ? .writerFailed : nil)
        )
        do {
            try ScreencastMetadata(capture: capture, target: session.target, startedAt: session.startedAt ?? now())
                .write(to: capture.metadataURL)
        } catch {
            logger.error("screencast meta.json not written category=\(Self.category(of: error), privacy: .public)")
        }
        state = endedEarly.map { .failed($0) } ?? .idle
        logger.info("screencast stopped displays=\(videos.count, privacy: .public) duration_ms=\(Int(capture.duration * 1000), privacy: .public) ended_early=\(capture.endedEarly?.rawValue ?? "none", privacy: .public)")
        return capture
    }

    /// A video stream or a file failed: stop, keep what was captured, and say so, once. A report
    /// from a take a restart threw away (`take`), from a recording already ending, or from one
    /// that's over is ignored.
    private func endEarly(_ failure: ScreencastFailure, generation: Int, take: Int?) {
        guard generation == self.generation, let session, take == nil || take == session.take,
              state.isActive, claimEnding(session) else { return }
        logger.error("screencast ended early category=\(failure.rawValue, privacy: .public)")
        Task {
            let capture = try? await finish(session, endedEarly: failure)
            onEndedEarly?(capture, failure)
        }
    }

    private func stopStreams(of session: Session) async {
        for stream in session.streams { await stream.stream?.stop() }
        await session.audioStream?.stop()
    }

    private func tearDown(_ session: Session, deletingFolder: Bool) async {
        session.timers.forEach { $0.invalidate() }
        let files = session.router.detach()
        await stopStreams(of: session)
        for file in files { await file.cancel() }
        if deletingFolder, let folder = session.folder { try? fileManager.removeItem(at: folder) }
        endActivity(of: session)
    }

    private func endActivity(of session: Session) {
        if let activity = session.activity { ProcessInfo.processInfo.endActivity(activity) }
        session.activity = nil
    }

    private func resetPresentation() {
        target = nil
        microphone = .notRecorded
        systemAudio = .notRecorded
        microphoneLevel = 0
    }

    // MARK: Samples

    private func makeRouter(generation: Int) -> ScreencastSampleRouter {
        ScreencastSampleRouter { [weak self] level in
            Task { @MainActor in
                guard let self, self.generation == generation, self.state == .recording, self.microphone == .on else { return }
                self.microphoneLevel = level
            }
        }
    }

    private func videoHandler(session: Session, index: Int) -> ScreencastSampleHandler {
        let router = session.router
        let generation = session.generation
        return ScreencastSampleHandler(
            video: { router.video($0, display: index) },
            stopped: { [weak self] failure in
                Task { @MainActor in self?.endEarly(failure, generation: generation, take: nil) }
            }
        )
    }

    private func audioHandler(session: Session, token: Int) -> ScreencastSampleHandler {
        let router = session.router
        let generation = session.generation
        return ScreencastSampleHandler(
            audio: { router.audio($0, from: $1) },
            stopped: { [weak self] _ in
                Task { @MainActor in self?.audioStreamStopped(generation: generation, token: token) }
            }
        )
    }

    private static func category(of error: Error) -> String {
        (error as? ScreencastFailure)?.rawValue ?? String(describing: type(of: error))
    }
}

// MARK: - Session

@available(macOS 15, *)
extension ScreencastRecorder {
    /// Where one stream reads from.
    enum StreamSource: Equatable {
        case display(CGDirectDisplayID)
        case area(CGDirectDisplayID, CGRect)
        case window(CGWindowID)
    }

    /// One display's stream: what it shows and reads, and the stream once it exists.
    struct StreamPlan {
        let source: StreamSource
        var plan: ScreencastFilterPlan
        let configuration: ScreencastStreamConfiguration
        var stream: (any ScreencastStream)?

        init(source: StreamSource, plan: ScreencastFilterPlan, configuration: ScreencastStreamConfiguration) {
            self.source = source
            self.plan = plan
            self.configuration = configuration
        }
    }

    /// One recording, from start to stop, restarts included.
    @MainActor
    final class Session {
        enum Phase {
            case live
            /// Stopping, discarding, or ending early: whichever came first owns it.
            case ending
        }

        let generation: Int
        let target: ScreencastTarget
        /// The sounds asked for at the start.
        let audio: ScreencastAudio
        let options: ScreencastOptions
        let capturesFolder: URL
        let router: ScreencastSampleRouter
        var phase = Phase.live
        /// Counts restarts, so a failure from a take thrown away is ignored.
        var take = 0
        var streams: [StreamPlan]
        var content: ScreencastContent
        var audioStream: (any ScreencastStream)?
        /// What the running sound stream carries.
        var audioStreamSources = ScreencastAudio.none
        /// Counts sound streams, so a report from a replaced one is ignored.
        var audioStreamToken = 0
        /// Sounds asked for that couldn't start, or stopped.
        var failedAudio: Set<ScreencastAudioSource> = []
        var switchedOff: [ScreencastAudioSource: Bool] = [:]
        var folder: URL?
        var startedAt: Date?
        var timeline = ScreencastTimeline()
        var followedFrame: CGRect?
        /// Keybumps's visible windows when the filters were last built.
        var ownWindows: Set<CGWindowID> = []
        var timers: [Timer] = []
        var activity: NSObjectProtocol?
        // The stream update queue.
        var isUpdating = false
        var needsFilterRebuild = false
        var pendingWindowFrame: CGRect?
        var rebuildWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            generation: Int,
            target: ScreencastTarget,
            audio: ScreencastAudio,
            options: ScreencastOptions,
            capturesFolder: URL,
            streams: [StreamPlan],
            content: ScreencastContent,
            router: ScreencastSampleRouter
        ) {
            self.generation = generation
            self.target = target
            self.audio = audio
            self.options = options
            self.capturesFolder = capturesFolder
            self.streams = streams
            self.content = content
            self.router = router
        }
    }

    /// Fires once; everyone waiting, before or after, goes on.
    @MainActor
    final class Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            fired = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func wait() async {
            guard !fired else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

// MARK: - Routing samples

/// Hands each stream's samples to the current files, on the capture queues: a display's frames to
/// its own file, and the sound to every file. Restarting swaps the files and stopping detaches
/// them, under the lock; a sample already on its way to a detached file is dropped by it.
final class ScreencastSampleRouter: @unchecked Sendable {
    /// How often the microphone meter updates.
    static let meteringInterval = 1.0 / 15

    private let lock = NSLock()
    private var files: [any ScreencastMovieWriting] = []
    private var lastFrames: [Int: CMSampleBuffer] = [:]
    private var isMetering = false
    private var lastMeteredAt = -Double.infinity
    private let onMicrophoneLevel: @Sendable (Float) -> Void

    init(onMicrophoneLevel: @escaping @Sendable (Float) -> Void) {
        self.onMicrophoneLevel = onMicrophoneLevel
    }

    var writers: [any ScreencastMovieWriting] {
        lock.withLock { files }
    }

    func attach(_ files: [any ScreencastMovieWriting]) {
        lock.withLock { self.files = files }
    }

    /// Takes the files away from the streams and returns them.
    func detach() -> [any ScreencastMovieWriting] {
        lock.withLock {
            defer { files = [] }
            return files
        }
    }

    /// Gives each file the last frame its stream delivered, stamped `host`.
    func reseed(at host: Double) {
        let (files, frames) = lock.withLock { (self.files, lastFrames) }
        for (index, frame) in frames where files.indices.contains(index) {
            guard let restamped = ScreencastWriterCore.copy(
                frame,
                at: CMTime(seconds: host, preferredTimescale: 1_000_000_000),
                duration: .invalid
            ) else { continue }
            files[index].appendVideo(restamped)
        }
    }

    func setMetering(_ on: Bool) {
        lock.withLock { isMetering = on }
    }

    func video(_ sample: CMSampleBuffer, display index: Int) {
        let file: (any ScreencastMovieWriting)? = lock.withLock {
            lastFrames[index] = sample
            return files.indices.contains(index) ? files[index] : nil
        }
        file?.appendVideo(sample)
    }

    func audio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        let host = sample.presentationTimeStamp.seconds
        let (files, meters): ([any ScreencastMovieWriting], Bool) = lock.withLock {
            let meters = source == .microphone && isMetering && host - lastMeteredAt >= Self.meteringInterval
            if meters { lastMeteredAt = host }
            return (self.files, meters)
        }
        for file in files { file.appendAudio(sample, from: source) }
        if meters { onMicrophoneLevel(ScreencastAudioBuffers.level(of: sample)) }
    }
}
