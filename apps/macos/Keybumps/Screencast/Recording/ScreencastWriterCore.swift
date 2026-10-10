import CoreMedia
import Foundation

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
/// Adapted from Shotnix's `RecordingWriterCore` (MIT, see LICENSE.shotnix), with the health check
/// from Screendrop's `ScreenRecordingWriter` (CC0-1.0, see LICENSE.screendrop).
final class ScreencastWriterCore {
    /// About three seconds of buffers per sound, kept while waiting for the first video frame.
    static let maximumPendingAudioBuffers = 150

    private let sink: ScreencastMovieSink
    private let frameDuration: CMTime
    private let onFailure: () -> Void
    private var timeline = ScreencastTimeline()
    private var switchedOff: [ScreencastAudioSource: ScreencastHostIntervals] = [:]
    private var lastVideoTime: Double?
    private var lastVideoSample: CMSampleBuffer?
    private var pendingAudio: [ScreencastAudioSource: [CMSampleBuffer]] = [:]
    private var audioWritten: [ScreencastAudioSource: Double] = [:]
    private var audioFormats: [ScreencastAudioSource: CMAudioFormatDescription] = [:]
    private var isActive = true
    private var didReportFailure = false

    /// Frames the encoder couldn't take in time.
    private(set) var droppedFrameCount = 0

    /// `onFailure` runs once, on the writer's queue, the first time the sink reports it failed.
    init(sink: ScreencastMovieSink, framesPerSecond: Int, onFailure: @escaping () -> Void) {
        self.sink = sink
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
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
            flushPendingAudio()
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
        guard isActive, sink.audioSources.contains(source), checkHealth() else { return }
        guard timeline.hasStarted else {
            var pending = pendingAudio[source, default: []]
            pending.append(sample)
            if pending.count > Self.maximumPendingAudioBuffers { pending.removeFirst() }
            pendingAudio[source] = pending
            return
        }
        appendReadyAudio(sample, from: source)
    }

    /// Anything captured before t=0 is trimmed away by the placement.
    private func flushPendingAudio() {
        for source in sink.audioSources {
            pendingAudio[source]?.forEach { appendReadyAudio($0, from: source) }
        }
        pendingAudio.removeAll()
    }

    private func appendReadyAudio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        let host = sample.presentationTimeStamp.seconds
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let rate = ScreencastAudioBuffers.sampleRate(of: format),
              // Captured while paused: not part of the recording.
              let start = timeline.time(at: host) else { return }
        audioFormats[source] = format
        let frames = CMSampleBufferGetNumSamples(sample)
        let duration = Double(frames) / rate
        guard var placement = ScreencastAudioPlacement.place(start: start, duration: duration, written: writtenAudio(for: source)),
              sink.isReady(for: .audio(source)) else { return }
        if placement.silence > 0 {
            writeSilence(placement.silence, format: format, to: source)
            // The encoder filled up before the gap closed: skip this buffer, the next one
            // continues the silence.
            guard let caughtUp = ScreencastAudioPlacement.place(start: start, duration: duration, written: writtenAudio(for: source)),
                  caughtUp.silence == 0 else { return }
            placement = caughtUp
        }
        let trimFrames = Int((placement.trim * rate).rounded())
        guard trimFrames < frames else { return }
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
        guard let kept, sink.isReady(for: .audio(source)) else { return }
        if sink.append(kept, to: .audio(source)) {
            audioWritten[source] = position + Double(frames - trimFrames) / rate
        } else {
            _ = checkHealth()
        }
    }

    /// A sound that goes quiet (a microphone unplugged, no system sound being sent) is padded
    /// with silence as the video moves on, so its track never falls far behind and there's no
    /// minutes-long gap to fill at once when it comes back. Half a second of slack leaves room for
    /// buffers still on their way.
    private func keepAudioUp(with videoTime: Double) {
        for source in sink.audioSources {
            guard let format = audioFormats[source] else { continue }
            let written = writtenAudio(for: source)
            guard videoTime - written > 1 else { continue }
            writeSilence(videoTime - 0.5 - written, format: format, to: source)
        }
    }

    private func writeSilence(_ seconds: Double, format: CMAudioFormatDescription, to source: ScreencastAudioSource) {
        guard let rate = ScreencastAudioBuffers.sampleRate(of: format) else { return }
        var remaining = Int((seconds * rate).rounded())
        while remaining > 0, sink.isReady(for: .audio(source)) {
            // A second at a time keeps a long dropout from allocating minutes of zeros.
            let frames = min(remaining, Int(rate))
            let position = writtenAudio(for: source)
            let time = CMTime(value: CMTimeValue((position * rate).rounded()), timescale: CMTimeScale(rate))
            guard let silence = ScreencastAudioBuffers.silence(frames: frames, format: format, at: time),
                  sink.append(silence, to: .audio(source)) else { return }
            audioWritten[source] = position + Double(frames) / rate
            remaining -= frames
        }
    }

    // MARK: Finishing

    /// Ends the file at `host`: the last frame is repeated so the video runs to the moment the
    /// person stopped (or paused, if it ended paused), and every audio track is filled with silence
    /// to the same point, so a sound that went quiet or never started still spans the recording.
    /// Works after `deactivate()`. Returns the end, in recording seconds.
    @discardableResult
    func finish(at host: Double) -> Double {
        let end = timeline.duration(at: host)
        guard !didReportFailure, !sink.hasFailed, let lastVideoTime, let lastVideoSample else { return videoDuration }
        if end > lastVideoTime + frameDuration.seconds, sink.isReady(for: .video),
           let retimed = Self.copy(lastVideoSample, at: CMTime(seconds: end, preferredTimescale: 60_000), duration: frameDuration),
           sink.append(retimed, to: .video) {
            self.lastVideoTime = end
        }
        for source in sink.audioSources {
            let written = writtenAudio(for: source)
            guard end - written > ScreencastAudioPlacement.tolerance,
                  let format = audioFormats[source]
                    ?? ScreencastAudioBuffers.defaultFormat(channels: source == .systemAudio ? 2 : 1) else { continue }
            writeSilence(end - written, format: format, to: source)
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
