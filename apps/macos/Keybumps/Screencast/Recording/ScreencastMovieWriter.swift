import AVFoundation
import CoreMedia
import Foundation

/// One display's file, as the recorder drives it. Samples arrive on ScreenCaptureKit's queues and
/// the controls on the main actor; an implementation serializes them.
protocol ScreencastMovieWriting: AnyObject, Sendable {
    var fileURL: URL { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var audioSources: [ScreencastAudioSource] { get }
    /// Blocks the capture queue until the frame is handled, so a slow encoder costs dropped frames
    /// rather than memory.
    func appendVideo(_ sample: CMSampleBuffer)
    func appendAudio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource)
    func pause(at host: Double)
    func resume(at host: Double)
    func setAudio(_ source: ScreencastAudioSource, on: Bool, at host: Double)
    /// Ends the file at `host` (host clock) and closes it.
    func finish(at host: Double) async -> ScreencastWriterResult
    /// Stops writing and deletes the file.
    func cancel() async
}

/// How a file ended.
struct ScreencastWriterResult: Equatable, Sendable {
    let fileURL: URL
    /// Recorded seconds in the file.
    let duration: Double
    /// The writer failed before it finished. Its movie fragments still play up to the last one
    /// written, so the file is kept when there's footage in it.
    let failed: Bool

    /// A file worth keeping: at least a frame of picture.
    var hasFootage: Bool { duration > 0.1 }
}

/// Makes the files: a writer per display, and the stereo mixdown after stopping. Tests pass a fake.
protocol ScreencastWriterFactory: Sendable {
    /// `onFailure` runs once, on the writer's queue, if the writer fails mid-recording.
    func makeWriter(
        at url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        audio: [ScreencastAudioSource],
        options: ScreencastOptions,
        onFailure: @escaping @Sendable () -> Void
    ) throws -> any ScreencastMovieWriting

    /// Writes `source`'s picture and every audio track mixed into one stereo track to `destination`.
    func writeMixdown(of source: URL, to destination: URL) async throws
}

/// The app's writer factory: `AVAssetWriter` files and `ScreencastAudioMixdown`.
struct AVAssetScreencastWriterFactory: ScreencastWriterFactory {
    func makeWriter(
        at url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        audio: [ScreencastAudioSource],
        options: ScreencastOptions,
        onFailure: @escaping @Sendable () -> Void
    ) throws -> any ScreencastMovieWriting {
        try ScreencastMovieWriter(
            url: url,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            audio: audio,
            options: options,
            onFailure: onFailure
        )
    }

    func writeMixdown(of source: URL, to destination: URL) async throws {
        try await ScreencastAudioMixdown.write(from: source, to: destination)
    }
}

/// How a file is encoded. H.264 plays everywhere, in every browser and on every upload site, but
/// stops at level 5.2 (and Apple's hardware encoder at 4096 pixels a side), so 5K and larger
/// displays switch to HEVC. Adapted from Shotnix's `RecordingVideoFormat` (MIT, see LICENSE.shotnix).
struct ScreencastVideoFormat: Equatable, Sendable {
    let codec: AVVideoCodecType
    let averageBitRate: Int

    static func plan(pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int) -> ScreencastVideoFormat {
        let hevc = !fitsH264(pixelWidth: pixelWidth, pixelHeight: pixelHeight, framesPerSecond: framesPerSecond)
        return ScreencastVideoFormat(
            codec: hevc ? .hevc : .h264,
            averageBitRate: bitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight, framesPerSecond: framesPerSecond, hevc: hevc)
        )
    }

    /// Level 5.2: at most 4096 pixels a side, 36,864 macroblocks a frame, and 2,073,600 a second.
    static func fitsH264(pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int) -> Bool {
        let macroblocks = ((pixelWidth + 15) / 16) * ((pixelHeight + 15) / 16)
        return pixelWidth <= 4096 && pixelHeight <= 4096
            && macroblocks <= 36_864
            && macroblocks * max(framesPerSecond, 1) <= 2_073_600
    }

    /// About 0.08 bits a pixel a frame, which keeps text sharp; HEVC needs about 70% of that.
    /// Screen content usually comes in well under it.
    static func bitRate(pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int, hevc: Bool) -> Int {
        let raw = Double(max(pixelWidth, 1) * max(pixelHeight, 1) * max(framesPerSecond, 1)) * 0.08 * (hevc ? 0.7 : 1)
        return Int(min(max(raw, 2_000_000), 40_000_000))
    }
}

/// One display's QuickTime movie: the picture plus a track for each recorded sound, written by
/// `AVAssetWriter` rather than `SCRecordingOutput`, which can't pause.
///
/// Adapted from Screendrop's `ScreenRecordingWriter` (`Screendrop/ScreenRecordingManager.swift`,
/// CC0-1.0, see LICENSE.screendrop):
/// - Movie fragments every two seconds, so a crash, a force quit, or a writer that fails mid-way
///   still leaves a file that plays up to the last fragment.
/// - Separate microphone and system-audio tracks.
/// - Every sample is handled synchronously on one serial queue. An unbounded hop would retain
///   full-resolution surfaces whenever the encoder fell behind; this way ScreenCaptureKit drops a
///   frame instead.
/// - The writer's health is checked on the write path, so a failure (a full disk, a dead encoder)
///   surfaces at once instead of passing for a live recording.
final class ScreencastMovieWriter: ScreencastMovieWriting, @unchecked Sendable {
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let audioSources: [ScreencastAudioSource]

    // Touched only on `queue`, after `init`.
    private let writer: AVAssetWriter
    private let sink: AssetWriterSink
    private let core: ScreencastWriterCore
    private let queue = DispatchQueue(label: "com.serp.keybumps.screencast.writer", qos: .userInitiated)
    private var isClosed = false

    init(
        url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        audio: [ScreencastAudioSource],
        options: ScreencastOptions,
        fragmentInterval: CMTime = ScreencastMovieWriter.fragmentInterval,
        onFailure: @escaping @Sendable () -> Void
    ) throws {
        fileURL = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        audioSources = audio
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = fragmentInterval

        let format = ScreencastVideoFormat.plan(pixelWidth: pixelWidth, pixelHeight: pixelHeight, framesPerSecond: options.framesPerSecond)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: format.averageBitRate,
                AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond,
                AVVideoAllowFrameReorderingKey: false
            ] as [String: Any],
            // ScreenCaptureKit is asked for sRGB frames; tag the file to match.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw ScreencastFailure.writerFailed }
        writer.add(video)

        var audioInputs: [ScreencastAudioSource: AVAssetWriterInput] = [:]
        for source in audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(for: source))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreencastFailure.writerFailed }
            writer.add(input)
            audioInputs[source] = input
        }

        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw ScreencastFailure.writerFailed
        }
        self.writer = writer
        sink = AssetWriterSink(writer: writer, video: video, audio: audioInputs, audioSources: audio)
        core = ScreencastWriterCore(sink: sink, framesPerSecond: options.framesPerSecond, onFailure: onFailure)
    }

    /// AAC at 48 kHz: the microphone in mono, system audio in stereo.
    static func audioSettings(for source: ScreencastAudioSource) -> [String: Any] {
        let channels = source == .systemAudio ? 2 : 1
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 128_000
        ]
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        let sample = SendableSample(sample)
        queue.sync {
            autoreleasepool { core.appendVideo(sample.buffer) }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        let sample = SendableSample(sample)
        queue.sync {
            autoreleasepool { core.appendAudio(sample.buffer, from: source) }
        }
    }

    func pause(at host: Double) {
        queue.async { self.core.pause(at: host) }
    }

    func resume(at host: Double) {
        queue.async { self.core.resume(at: host) }
    }

    func setAudio(_ source: ScreencastAudioSource, on: Bool, at host: Double) {
        queue.async { self.core.setAudio(source, on: on, at: host) }
    }

    func finish(at host: Double) async -> ScreencastWriterResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                core.deactivate()
                let duration = core.finish(at: host)
                guard !isClosed, writer.status == .writing else {
                    // Failed already: finishing would throw. The fragments on disk are what's left.
                    isClosed = true
                    continuation.resume(returning: ScreencastWriterResult(fileURL: fileURL, duration: duration, failed: true))
                    return
                }
                isClosed = true
                guard core.hasVideo else {
                    // No frame arrived, so no session started: there's nothing to finish.
                    writer.cancelWriting()
                    continuation.resume(returning: ScreencastWriterResult(fileURL: fileURL, duration: 0, failed: false))
                    return
                }
                sink.markAsFinished()
                let writer = writer
                let fileURL = fileURL
                let failedBefore = core.hasFailed
                writer.finishWriting {
                    continuation.resume(returning: ScreencastWriterResult(
                        fileURL: fileURL,
                        duration: duration,
                        failed: failedBefore || writer.status != .completed
                    ))
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                core.deactivate()
                if !isClosed, writer.status == .writing { writer.cancelWriting() }
                isClosed = true
                try? FileManager.default.removeItem(at: fileURL)
                continuation.resume()
            }
        }
    }
}

/// An `AVAssetWriter` and its inputs as a writer core's sink.
private final class AssetWriterSink: ScreencastMovieSink {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: [ScreencastAudioSource: AVAssetWriterInput]
    let audioSources: [ScreencastAudioSource]

    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: [ScreencastAudioSource: AVAssetWriterInput], audioSources: [ScreencastAudioSource]) {
        self.writer = writer
        self.video = video
        self.audio = audio
        self.audioSources = audioSources
    }

    var hasFailed: Bool { writer.status == .failed }

    func startSession() {
        writer.startSession(atSourceTime: .zero)
    }

    func isReady(for track: ScreencastTrack) -> Bool {
        input(for: track)?.isReadyForMoreMediaData ?? false
    }

    func append(_ sample: CMSampleBuffer, to track: ScreencastTrack) -> Bool {
        guard writer.status == .writing, let input = input(for: track) else { return false }
        return input.append(sample)
    }

    func markAsFinished() {
        video.markAsFinished()
        audio.values.forEach { $0.markAsFinished() }
    }

    private func input(for track: ScreencastTrack) -> AVAssetWriterInput? {
        switch track {
        case .video: video
        case .audio(let source): audio[source]
        }
    }
}

/// Carries a sample buffer across the writer queue's `sync`, which it never outlives.
struct SendableSample: @unchecked Sendable {
    let buffer: CMSampleBuffer

    init(_ buffer: CMSampleBuffer) {
        self.buffer = buffer
    }
}
