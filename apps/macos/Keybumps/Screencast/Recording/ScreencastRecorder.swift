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
/// - Switching a sound off keeps its source running and writes silence in its place.
/// - Keybumps's own windows stay out of the video, except the overlays added with
///   `includeOverlayWindow(_:)`.
/// - A recording that stops on its own (the display went away, the disk filled up) keeps what it
///   captured and reports it through `onEndedEarly`.
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

    /// Called when a recording ends without `stop()` or `discard()`: a stream or a file failed.
    /// The capture is what was saved, nil if nothing was. The state is then `.failed(reason)`.
    @ObservationIgnored var onEndedEarly: ((ScreencastCapture?, ScreencastFailure) -> Void)?

    @ObservationIgnored private let system: any ScreencastCaptureSystem
    @ObservationIgnored private let writers: any ScreencastWriterFactory
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let hostClock: () -> Double
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let ownProcessID: pid_t
    @ObservationIgnored private let tickInterval: TimeInterval?
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    @ObservationIgnored private var session: Session?
    /// Bumped by every start and discard, so a superseded start or a late callback does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var updates: Task<Void, Never>?

    /// - Parameters:
    ///   - system: ScreenCaptureKit; inert in the unit-test host unless a test passes a fake.
    ///   - hostClock: Host-clock seconds, the clock ScreenCaptureKit stamps samples with.
    ///   - tickInterval: How often `elapsed`, the followed window, and Keybumps's own windows are
    ///     checked while recording; nil for no timer (tests call `tick()`).
    init(
        system: (any ScreencastCaptureSystem)? = nil,
        writers: any ScreencastWriterFactory = AVAssetScreencastWriterFactory(),
        fileManager: FileManager = .default,
        hostClock: @escaping () -> Double = CACurrentMediaTime,
        now: @escaping () -> Date = Date.init,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        tickInterval: TimeInterval? = 0.25
    ) {
        self.system = system ?? ScreenCaptureKitCaptureSystem.current
        self.writers = writers
        self.fileManager = fileManager
        self.hostClock = hostClock
        self.now = now
        self.ownProcessID = ownProcessID
        self.tickInterval = tickInterval
    }

    // MARK: Starting

    /// Starts recording `target` with `audio` into a new `<timestamp>` folder in `capturesFolder`,
    /// once every stream is running. Throws a `ScreencastFailure` (and the state becomes
    /// `.failed`), `ScreencastRecorderError.alreadyRecording`, or `CancellationError` when
    /// `discard()` cancelled it.
    func start(
        target: ScreencastTarget,
        audio: ScreencastAudio,
        capturesFolder: URL,
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
        var started: Session?
        do {
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
            started = session
            try openFiles(for: session, switchedOffAt: nil)

            if !audio.sources.isEmpty {
                // Started before the picture, so a microphone that's slow to start has warmed up by
                // the first frame; anything it hears before that is trimmed.
                do {
                    let audioStream = try system.makeAudioStream(audio: audio, content: content, handler: audioHandler(session: session))
                    session.audioStream = audioStream
                    try await audioStream.start()
                } catch {
                    // The video matters more than the sound: record on without it.
                    session.audioFailed = true
                    logger.error("screencast audio stream failed category=\(Self.category(of: error), privacy: .public)")
                }
                try ensureCurrent(generation)
            }
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

            session.ownWindows = system.ownVisibleWindows()
            if case .window(let id) = target { session.followedFrame = content.window(id)?.frame }
            self.session = session
            session.timeline.start(at: hostClock())
            session.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording a screencast"
            )
            microphone = audio.microphone ? (session.audioFailed ? .failed : .on) : .notRecorded
            systemAudio = audio.systemAudio ? (session.audioFailed ? .failed : .on) : .notRecorded
            session.router.setMetering(microphone == .on)
            state = .recording
            startTicking()
            if overlayWindows != overlays {
                // An overlay was added or removed while the streams were starting.
                Task { await rebuildFilters() }
            }
            logger.info("screencast started target=\(target.kind, privacy: .public) displays=\(session.streams.count, privacy: .public) microphone=\(audio.microphone, privacy: .public) systemAudio=\(audio.systemAudio, privacy: .public)")
        } catch {
            if let started { await tearDown(started, deletingFolder: true) }
            guard !(error is CancellationError) else { throw error }
            let failure = (error as? ScreencastFailure) ?? .captureFailed
            if generation == self.generation {
                self.target = nil
                state = .failed(failure)
            }
            logger.error("screencast start failed category=\(failure.rawValue, privacy: .public)")
            throw failure
        }
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

    /// A new folder and a writer per stream, attached to the router. On a restart, the sounds
    /// switched off are off in the new files from `switchedOffAt`, before any sample reaches them.
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
        var files: [any ScreencastMovieWriting] = []
        do {
            for (index, stream) in session.streams.enumerated() {
                files.append(try writers.makeWriter(
                    at: folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index)),
                    pixelWidth: stream.configuration.pixelWidth,
                    pixelHeight: stream.configuration.pixelHeight,
                    audio: session.audio.sources,
                    options: session.options,
                    onFailure: { [weak self] in
                        Task { @MainActor in self?.endEarly(.writerFailed, generation: generation) }
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
        guard state == .recording, let session else { return }
        let host = hostClock()
        session.timeline.pause(at: host)
        session.router.writers.forEach { $0.pause(at: host) }
        session.router.setMetering(false)
        microphoneLevel = 0
        state = .paused
        refreshElapsed()
    }

    func resume() {
        guard state == .paused, let session else { return }
        let host = hostClock()
        session.timeline.resume(at: host)
        session.router.writers.forEach { $0.resume(at: host) }
        session.router.setMetering(microphone == .on)
        state = .recording
        refreshElapsed()
    }

    /// Switches a recorded sound off (its track gets silence) or back on. Does nothing for a sound
    /// the recording started without, or one that failed.
    func setAudio(_ source: ScreencastAudioSource, on: Bool) {
        guard state.isActive, let session else { return }
        let current = source == .microphone ? microphone : systemAudio
        guard current == .on || current == .off else { return }
        let host = hostClock()
        session.router.writers.forEach { $0.setAudio(source, on: on, at: host) }
        session.switchedOff[source] = !on
        if source == .microphone {
            microphone = on ? .on : .off
            session.router.setMetering(on && state == .recording)
            if !on { microphoneLevel = 0 }
        } else {
            systemAudio = on ? .on : .off
        }
    }

    // MARK: Overlays

    /// Shows one of Keybumps's windows in the video, such as the drawing layer. The control bar,
    /// the picker's dimming, and every other Keybumps window stay out. Returns once the running
    /// streams show it.
    func includeOverlayWindow(_ id: CGWindowID) async {
        guard overlayWindows.insert(id).inserted else { return }
        await rebuildFilters()
    }

    func removeOverlayWindow(_ id: CGWindowID) async {
        guard overlayWindows.remove(id) != nil else { return }
        await rebuildFilters()
    }

    /// Re-reads what's on screen and gives every stream its filter again, if it changed. Updates
    /// run one at a time, in order.
    private func rebuildFilters() async {
        guard let session, state.isActive else { return }
        let previous = updates
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyFilters(to: session)
        }
        updates = task
        await task.value
    }

    private func applyFilters(to session: Session) async {
        guard session === self.session, state.isActive else { return }
        guard let content = try? await system.content(), session === self.session, state.isActive else { return }
        session.content = content
        session.ownWindows = system.ownVisibleWindows()
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
                logger.error("screencast filter update failed category=\(Self.category(of: error), privacy: .public)")
            }
        }
    }

    // MARK: While recording

    private func startTicking() {
        guard let tickInterval, let session else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        session.timer = timer
    }

    /// Updates `elapsed`, follows a recorded window that moved, and rebuilds the filters when
    /// Keybumps opened or closed a window that a filter names one by one.
    func tick() {
        guard let session, state.isActive else { return }
        refreshElapsed()
        if case .window(let id) = session.target, let frame = system.windowFrame(id),
           frame != session.followedFrame, frame.width >= 2, frame.height >= 2 {
            session.followedFrame = frame
            Task { await follow(windowFrame: frame, in: session) }
        }
        if session.streams.contains(where: { $0.plan.dependsOnOwnWindows }) {
            let ownWindows = system.ownVisibleWindows()
            if ownWindows != session.ownWindows {
                session.ownWindows = ownWindows
                Task { await rebuildFilters() }
            }
        }
    }

    /// Moves a window recording's crop with its window. A resized window scales into the video; a
    /// window dragged to another display moves the stream there.
    private func follow(windowFrame frame: CGRect, in session: Session) async {
        guard session === self.session, let stream = session.streams.first, let running = stream.stream else { return }
        guard let display = session.content.display(mostOverlapping: frame), display.id == stream.plan.displayID else {
            await rebuildFilters()
            return
        }
        let geometry = ScreencastCaptureGeometry.window(frame: frame, displayFrame: display.frame, scale: display.scale)
        do {
            try await running.update(sourceRect: geometry.sourceRect)
        } catch {
            logger.error("screencast window follow failed category=\(Self.category(of: error), privacy: .public)")
        }
    }

    func refreshElapsed() {
        guard let session else { return }
        elapsed = session.timeline.duration(at: hostClock())
    }

    // MARK: Restarting

    /// Throws away what's recorded so far and starts again on the same target and sounds, with the
    /// sounds switched as they are now. The streams keep running, so it starts at once.
    func restart() async throws {
        guard state.isActive, let session else { throw ScreencastRecorderError.notRecording }
        let previousFiles = session.router.detach()
        let previousFolder = session.folder
        for file in previousFiles { await file.cancel() }
        if let previousFolder { try? fileManager.removeItem(at: previousFolder) }
        guard session === self.session else { return }
        let host = hostClock()
        do {
            try openFiles(for: session, switchedOffAt: host)
        } catch {
            let failure = (error as? ScreencastFailure) ?? .writerFailed
            await tearDown(session, deletingFolder: true)
            self.session = nil
            resetPresentation()
            state = .failed(failure)
            throw failure
        }
        // ScreenCaptureKit sends a frame only when the screen changes: give the new files the last
        // one now, so they start here even on a still screen.
        session.router.reseed(at: host)
        session.timeline = ScreencastTimeline()
        session.timeline.start(at: host)
        session.router.setMetering(microphone == .on)
        elapsed = 0
        state = .recording
        logger.info("screencast restarted")
    }

    // MARK: Stopping

    /// Stops and keeps the recording: closes every file, writes a stereo mixdown beside each file
    /// with two sounds, and writes `meta.json`. Throws `ScreencastFailure.noFootage` (and deletes
    /// the folder) when nothing was recorded, or `ScreencastRecorderError.notRecording`.
    func stop() async throws -> ScreencastCapture {
        guard state.isActive, let session else { throw ScreencastRecorderError.notRecording }
        return try await finish(session, endedEarly: nil)
    }

    /// Stops and deletes everything recorded. Cancels a start still in progress.
    func discard() async {
        switch state {
        case .starting:
            generation += 1
            target = nil
            state = .idle
        case .recording, .paused:
            guard let session else { return }
            state = .stopping
            generation += 1
            await tearDown(session, deletingFolder: true)
            self.session = nil
            resetPresentation()
            state = .idle
            logger.info("screencast discarded")
        default:
            return
        }
    }

    private func finish(_ session: Session, endedEarly: ScreencastFailure?) async throws -> ScreencastCapture {
        state = .stopping
        let end = hostClock()
        session.timer?.invalidate()
        session.router.setMetering(false)
        microphoneLevel = 0
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

    /// A video stream or a file failed: stop, keep what was captured, and say so.
    private func endEarly(_ failure: ScreencastFailure, generation: Int) {
        guard generation == self.generation, state.isActive, let session else { return }
        logger.error("screencast ended early category=\(failure.rawValue, privacy: .public)")
        Task {
            let capture = try? await finish(session, endedEarly: failure)
            state = .failed(failure)
            onEndedEarly?(capture, failure)
        }
    }

    /// The sound stream stopped: the recording goes on, its tracks silent from here.
    private func audioStreamStopped(generation: Int) {
        guard generation == self.generation, let session, state.isActive else { return }
        session.audioFailed = true
        if microphone != .notRecorded { microphone = .failed }
        if systemAudio != .notRecorded { systemAudio = .failed }
        session.router.setMetering(false)
        microphoneLevel = 0
        logger.error("screencast audio stream stopped")
    }

    private func stopStreams(of session: Session) async {
        for stream in session.streams { await stream.stream?.stop() }
        await session.audioStream?.stop()
    }

    private func tearDown(_ session: Session, deletingFolder: Bool) async {
        session.timer?.invalidate()
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
                Task { @MainActor in self?.endEarly(failure, generation: generation) }
            }
        )
    }

    private func audioHandler(session: Session) -> ScreencastSampleHandler {
        let router = session.router
        let generation = session.generation
        return ScreencastSampleHandler(
            audio: { router.audio($0, from: $1) },
            stopped: { [weak self] _ in
                Task { @MainActor in self?.audioStreamStopped(generation: generation) }
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
        let generation: Int
        let target: ScreencastTarget
        let audio: ScreencastAudio
        let options: ScreencastOptions
        let capturesFolder: URL
        let router: ScreencastSampleRouter
        var streams: [StreamPlan]
        var content: ScreencastContent
        var audioStream: (any ScreencastStream)?
        var audioFailed = false
        var folder: URL?
        var startedAt: Date?
        var timeline = ScreencastTimeline()
        var switchedOff: [ScreencastAudioSource: Bool] = [:]
        var followedFrame: CGRect?
        var ownWindows: Set<CGWindowID> = []
        var timer: Timer?
        var activity: NSObjectProtocol?

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
