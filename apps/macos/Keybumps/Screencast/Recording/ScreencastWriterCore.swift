import CoreMedia
import Foundation
import QuartzCore

/// A track in a screencast file.
enum ScreencastTrack: Hashable, Sendable {
    case video
    case audio(ScreencastAudioSource)
}

/// What a writer core appends to: an `AVAssetWriter` and its inputs in the app, a recording fake
/// in tests. Touched only on its writer's queue.
protocol ScreencastMovieSink: AnyObject {
    /// The audio tracks the file has.
    var audioSources: [ScreencastAudioSource] { get }
    /// The writer gave up: a full disk, a failed encoder, out-of-order timestamps.
    var hasFailed: Bool { get }
    /// Starts the file's timeline at zero, before the first append.
    func startSession()
    func isReady(for track: ScreencastTrack) -> Bool
    /// Whether the sample was taken.
    func append(_ sample: CMSampleBuffer, to track: ScreencastTrack) -> Bool
}

/// One file's per-sample logic, confined to its writer's serial queue: where each video frame and
/// audio buffer lands, what's dropped while paused, silence for a sound that's switched off or
/// late, and noticing once that the writer failed.
///
/// An input that isn't ready never costs real sound. While recording, a sound's buffers wait in
/// order behind the silence still owed to its track, and are written as the input takes more; the
/// capture queue is never held. Every track is kept within about a second of the recording as it
/// goes, by frames and by the recorder's clock (`keepUp(at:)`), even one that never hears a sound,
/// since encoding silence costs time the stop shouldn't have to spend. When the file ends, the
/// core waits for the inputs, so every track reaches the end.
///
/// Each track keeps one PCM format: its first buffer's, or the silence it was padded with before
/// any came. Buffers in another layout are converted (`ScreencastAudioConformer`).
///
/// Adapted from Shotnix's `RecordingWriterCore` (MIT, see LICENSE.shotnix), with the health check
/// from Screendrop's `ScreenRecordingWriter` (CC0-1.0, see LICENSE.screendrop).
final class ScreencastWriterCore {
    /// About three seconds of buffers per sound, kept while waiting for the first video frame or
    /// for the input to take more. Beyond it, the oldest go.
    static let maximumWaitingAudioBuffers = 150
    /// Silence is written this many seconds at a time.
    static let silenceChunkSeconds = 5

    private let sink: ScreencastMovieSink
    private let frameDuration: CMTime
    private let onFailure: () -> Void
    private let stallTimeout: TimeInterval
    private var timeline = ScreencastTimeline()
    private var switchedOff: [ScreencastAudioSource: ScreencastHostIntervals] = [:]
    private var lastVideoTime: Double?
    private var lastVideoSample: CMSampleBuffer?
    /// Before the first frame: everything heard. After it: what the input couldn't take yet.
    private var waitingAudio: [ScreencastAudioSource: [CMSampleBuffer]] = [:]
    private var audioWritten: [ScreencastAudioSource: Double] = [:]
    /// Each track's one format, once it has one.
    private var trackFormats: [ScreencastAudioSource: CMAudioFormatDescription] = [:]
    private var conformers: [ScreencastAudioSource: ScreencastAudioConformer] = [:]
    private var isActive = true
    private var didReportFailure = false

    /// Frames the encoder couldn't take in time.
    private(set) var droppedFrameCount = 0
    /// Audio buffers that waited too long and were dropped.
    private(set) var droppedAudioBufferCount = 0

    /// - Parameters:
    ///   - onFailure: Runs once, on the writer's queue, the first time the sink reports it failed.
    ///   - stallTimeout: When finishing, how long an input may stay not ready before the core gives
    ///     up on it.
    init(sink: ScreencastMovieSink, framesPerSecond: Int, stallTimeout: TimeInterval = 2, onFailure: @escaping () -> Void) {
        self.sink = sink
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        self.stallTimeout = stallTimeout
        self.onFailure = onFailure
    }

    var hasVideo: Bool { lastVideoTime != nil }
    /// The last frame's recording time.
    var videoDuration: Double { lastVideoTime ?? 0 }
    var hasFailed: Bool { didReportFailure }

    /// Seconds written to `source`'s track.
    func writtenAudio(for source: ScreencastAudioSource) -> Double {
        audioWritten[source] ?? 0
    }

    /// Stops taking samples. The queue is serial, so nothing appends after a caller sees this.
    func deactivate() {
        isActive = false
    }

    func pause(at host: Double) {
        timeline.pause(at: host)
    }

    func resume(at host: Double) {
        timeline.resume(at: host)
    }

    /// Switches a sound off or on from `host`: while off, its buffers become silence of the same
    /// length, so its track keeps time with the picture and the source keeps running.
    func setAudio(_ source: ScreencastAudioSource, on: Bool, at host: Double) {
        if on {
            switchedOff[source]?.close(at: host)
        } else {
            switchedOff[source, default: ScreencastHostIntervals()].open(at: host)
        }
    }

    // MARK: Video

    func appendVideo(_ sample: CMSampleBuffer) {
        guard isActive, checkHealth() else { return }
        let host = sample.presentationTimeStamp.seconds
        if !timeline.hasStarted {
            // Paused before the first frame arrived: t=0 waits for the resume.
            guard !timeline.isPaused(at: host) else { return }
            timeline.start(at: host)
            sink.startSession()
        }
        guard let time = timeline.time(at: host), time >= 0 else { return }
        if let lastVideoTime, time <= lastVideoTime { return }
        guard sink.isReady(for: .video) else {
            // Dropping a frame beats holding ScreenCaptureKit's surfaces until memory runs out.
            droppedFrameCount += 1
            return
        }
        guard let retimed = Self.copy(sample, at: CMTime(seconds: time, preferredTimescale: 60_000), duration: frameDuration) else { return }
        if sink.append(retimed, to: .video) {
            lastVideoTime = time
            lastVideoSample = sample
            keepAudioUp(with: time)
        } else {
            _ = checkHealth()
        }
    }

    // MARK: Audio

    func appendAudio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        guard isActive, sink.audioSources.contains(source), checkHealth(),
              let sample = conformed(sample, from: source) else { return }
        enqueue(sample, from: source)
        // Before the first frame there's nowhere to put it yet; anything heard before t=0 is
        // trimmed away by the placement once there is.
        guard timeline.hasStarted else { return }
        writeWaitingAudio(from: source, waits: false)
    }

    /// `sample` in its track's format, which the first buffer sets when nothing else has.
    private func conformed(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) -> CMSampleBuffer? {
        // A format no converter could take (the recorder's router drops these first) never
        // becomes a track's format.
        guard let format = CMSampleBufferGetFormatDescription(sample),
              ScreencastAudioBuffers.canConvert(format) else { return nil }
        guard let trackFormat = trackFormats[source] else {
            trackFormats[source] = format
            return sample
        }
        // Kept, so a resampled sound stays continuous from one buffer to the next.
        let conformer = conformers[source] ?? ScreencastAudioConformer()
        conformers[source] = conformer
        return conformer.conform(sample, to: trackFormat)
    }

    /// The format a track has, or the default it takes on now, for padding before any sound came.
    private func trackFormat(of source: ScreencastAudioSource) -> CMAudioFormatDescription? {
        if let format = trackFormats[source] { return format }
        let format = ScreencastAudioBuffers.defaultFormat(channels: source == .systemAudio ? 2 : 1)
        trackFormats[source] = format
        return format
    }

    private func enqueue(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        var waiting = waitingAudio[source, default: []]
        waiting.append(sample)
        if waiting.count > Self.maximumWaitingAudioBuffers {
            waiting.removeFirst()
            droppedAudioBufferCount += 1
        }
        waitingAudio[source] = waiting
    }

    /// Writes `source`'s waiting buffers in order, stopping where its input isn't ready unless
    /// `waits`. Returns whether none are left.
    @discardableResult
    private func writeWaitingAudio(from source: ScreencastAudioSource, waits: Bool) -> Bool {
        while let next = waitingAudio[source]?.first {
            if place(next, from: source) {
                waitingAudio[source]?.removeFirst()
            } else if !waits || !waitUntilReady(.audio(source)) {
                return false
            }
        }
        return true
    }

    /// Writes one buffer where it belongs, after any silence its track is owed. False when the input
    /// wasn't ready to take it all yet; true once it's written, or dropped because it was captured
    /// while paused or lies before what's written.
    private func place(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) -> Bool {
        let host = sample.presentationTimeStamp.seconds
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let rate = ScreencastAudioBuffers.sampleRate(of: format),
              // Captured while paused: not part of the recording.
              let start = timeline.time(at: host) else { return true }
        let frames = CMSampleBufferGetNumSamples(sample)
        let duration = Double(frames) / rate
        guard var placement = ScreencastAudioPlacement.place(start: start, duration: duration, written: writtenAudio(for: source)) else {
            return true
        }
        if placement.silence > 0 {
            guard writeSilence(placement.silence, format: format, to: source) else { return false }
            guard let caughtUp = ScreencastAudioPlacement.place(start: start, duration: duration, written: writtenAudio(for: source)) else {
                return true
            }
            placement = caughtUp
        }
        let trimFrames = Int((placement.trim * rate).rounded())
        guard trimFrames < frames else { return true }
        let position = writtenAudio(for: source)
        let time = CMTime(value: CMTimeValue((position * rate).rounded()), timescale: CMTimeScale(rate))
        let kept: CMSampleBuffer?
        if switchedOff[source]?.contains(host) == true {
            kept = ScreencastAudioBuffers.silence(frames: frames - trimFrames, format: format, at: time)
        } else if trimFrames > 0 {
            kept = ScreencastAudioBuffers.dropping(frames: trimFrames, from: sample, at: time)
        } else {
            kept = Self.copy(sample, at: time, duration: CMTime(value: 1, timescale: CMTimeScale(rate)))
        }
        guard let kept else { return true }
        guard sink.isReady(for: .audio(source)) else { return false }
        if sink.append(kept, to: .audio(source)) {
            audioWritten[source] = position + Double(frames - trimFrames) / rate
        } else {
            _ = checkHealth()
        }
        return true
    }

    /// Pads the tracks up to the recording's time at `host`, as frames do, for a still screen that
    /// sends none. The recorder calls it a few times a second; it never waits.
    func keepUp(at host: Double) {
        guard isActive, timeline.hasStarted, !timeline.isPaused(at: host), checkHealth() else { return }
        keepAudioUp(with: timeline.duration(at: host))
    }

    /// A sound that goes quiet (a microphone unplugged, no system sound being sent), or hasn't
    /// been heard yet, is padded with silence as the recording moves on, so its track never falls
    /// far behind and there's no long gap to fill at once when it comes back or the file ends. Half
    /// a second of slack leaves room for buffers still on their way. Buffers left waiting for the
    /// input go first.
    private func keepAudioUp(with time: Double) {
        for source in sink.audioSources {
            guard writeWaitingAudio(from: source, waits: false) else { continue }
            let written = writtenAudio(for: source)
            guard time - written > 1, let format = trackFormat(of: source) else { continue }
            writeSilence(time - 0.5 - written, format: format, to: source)
        }
    }

    /// Appends `seconds` of silence, a few seconds at a time so a long gap never allocates minutes
    /// of zeros. Stops where the input isn't ready; returns whether it wrote it all.
    @discardableResult
    private func writeSilence(_ seconds: Double, format: CMAudioFormatDescription, to source: ScreencastAudioSource) -> Bool {
        guard let rate = ScreencastAudioBuffers.sampleRate(of: format) else { return true }
        var remaining = Int((seconds * rate).rounded())
        while remaining > 0 {
            guard sink.isReady(for: .audio(source)) else { return false }
            let frames = min(remaining, Int(rate) * Self.silenceChunkSeconds)
            let position = writtenAudio(for: source)
            let time = CMTime(value: CMTimeValue((position * rate).rounded()), timescale: CMTimeScale(rate))
            guard let silence = ScreencastAudioBuffers.silence(frames: frames, format: format, at: time) else { return true }
            guard sink.append(silence, to: .audio(source)) else {
                _ = checkHealth()
                return true
            }
            audioWritten[source] = position + Double(frames) / rate
            remaining -= frames
        }
        return true
    }

    /// Waits for `track`'s input to take more, for as long as it keeps stalling under the timeout.
    /// Only when the file ends: never on a capture queue.
    private func waitUntilReady(_ track: ScreencastTrack) -> Bool {
        let started = CACurrentMediaTime()
        while !sink.isReady(for: track) {
            guard !sink.hasFailed, CACurrentMediaTime() - started < stallTimeout else { return false }
            usleep(2_000)
        }
        return true
    }

    // MARK: Finishing

    /// Ends the file at `host`: the last frame is repeated so the video runs to the moment the
    /// person stopped (or paused, if it ended paused), the sound still waiting is written, and every
    /// audio track is filled with silence to the same point, so a sound that went quiet or never
    /// started still spans the recording. Waits for the inputs as it goes. Works after
    /// `deactivate()`. Returns the end, in recording seconds.
    @discardableResult
    func finish(at host: Double) -> Double {
        let end = timeline.duration(at: host)
        guard !didReportFailure, !sink.hasFailed, let lastVideoTime, let lastVideoSample else { return videoDuration }
        if end > lastVideoTime + frameDuration.seconds, waitUntilReady(.video),
           let retimed = Self.copy(lastVideoSample, at: CMTime(seconds: end, preferredTimescale: 60_000), duration: frameDuration),
           sink.append(retimed, to: .video) {
            self.lastVideoTime = end
        }
        for source in sink.audioSources {
            writeWaitingAudio(from: source, waits: true)
            guard let format = trackFormat(of: source) else { continue }
            while end - writtenAudio(for: source) > ScreencastAudioPlacement.tolerance,
                  !writeSilence(end - writtenAudio(for: source), format: format, to: source) {
                guard waitUntilReady(.audio(source)) else { break }
            }
        }
        return videoDuration
    }

    /// False, and `onFailure` once, when the writer has gone into its failed state; it then takes
    /// nothing more.
    private func checkHealth() -> Bool {
        guard !didReportFailure else { return false }
        guard sink.hasFailed else { return true }
        didReportFailure = true
        onFailure()
        return false
    }

    static func copy(_ sample: CMSampleBuffer, at presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration.isValid ? duration : .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copied: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        ) == noErr else { return nil }
        return copied
    }
}
