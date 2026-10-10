import AVFoundation
import Foundation

/// After a recording stops: a copy of the file whose sounds are mixed into one stereo AAC track,
/// with the picture passed through untouched, as an MP4. Players and upload sites that pick only a
/// file's first audio track would otherwise play the microphone without the Mac's sound, or the
/// other way around. The full file, a track per sound, stays beside it.
///
/// Adapted from Snapzy's `RecordingAudioCompatibilityExporter`
/// (`Snapzy/Services/Capture/ScreenRecordingManager.swift`, BSD-3-Clause, see LICENSE.snapzy).
enum ScreencastAudioMixdown {
    enum MixdownError: Error, Equatable {
        case missingVideoTrack
        case cannotAddOutput
        case cannotAddInput
        case readerFailed
        case writerFailed
    }

    /// One track plays everywhere already; two or more need mixing.
    static func isNeeded(audioTrackCount: Int) -> Bool {
        audioTrackCount > 1
    }

    /// Each sound's volume in the mix: 1/N, so the voice and the Mac's sound at full scale together
    /// can't clip, as Snapzy's `mixdownInputVolume` does.
    static func inputVolume(audioTrackCount: Int) -> Float {
        audioTrackCount > 1 ? 1 / Float(audioTrackCount) : 1
    }

    static func write(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MixdownError.missingVideoTrack
        }
        let duration = try await asset.load(.duration)
        let transform = try await videoTrack.load(.preferredTransform)
        let formatHint = try await videoTrack.load(.formatDescriptions).first
        let inputs = MixdownInputs(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks)
        try? FileManager.default.removeItem(at: destination)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "com.serp.keybumps.screencast.mixdown", qos: .utility).async {
                    do {
                        try writeSynchronously(
                            inputs: inputs,
                            duration: duration,
                            transform: transform,
                            formatHint: formatHint,
                            to: destination
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// AVFoundation's asset objects, confined to the mixdown's own queue once handed over.
    private final class MixdownInputs: @unchecked Sendable {
        let asset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]

        init(asset: AVAsset, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack]) {
            self.asset = asset
            self.videoTrack = videoTrack
            self.audioTracks = audioTracks
        }
    }

    private static func writeSynchronously(
        inputs: MixdownInputs,
        duration: CMTime,
        transform: CGAffineTransform,
        formatHint: CMFormatDescription?,
        to destination: URL
    ) throws {
        let reader = try AVAssetReader(asset: inputs.asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: inputs.videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MixdownError.cannotAddOutput }
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw MixdownError.cannotAddInput }
        writer.add(videoInput)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        if !inputs.audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: inputs.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = inputs.audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(inputVolume(audioTrackCount: inputs.audioTracks.count), at: .zero)
                return parameters
            }
            audioOutput.audioMix = mix
            guard reader.canAdd(audioOutput) else { throw MixdownError.cannotAddOutput }
            reader.add(audioOutput)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            ])
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else { throw MixdownError.cannotAddInput }
            writer.add(audioInput)
            pairs.append((audioOutput, audioInput))
        }

        guard writer.startWriting() else { throw MixdownError.writerFailed }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MixdownError.readerFailed
        }
        writer.startSession(atSourceTime: .zero)
        try copySamples(reader: reader, writer: writer, pairs: pairs)
        guard reader.status == .completed else { throw MixdownError.readerFailed }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw MixdownError.writerFailed }
    }

    /// Pulls every output into its input, each on its own queue, until all are done or one fails.
    /// A failure cancels both sides and releases every copy still waiting, since a cancelled
    /// writer never asks its inputs for more.
    private static func copySamples(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
    ) throws {
        let group = DispatchGroup()
        let lock = NSLock()
        var finished = Array(repeating: false, count: pairs.count)
        var failed = false

        /// Leaves the group for `index`, once.
        func finish(_ index: Int) {
            lock.withLock {
                guard !finished[index] else { return }
                finished[index] = true
                group.leave()
            }
        }

        func fail() {
            let isFirst = lock.withLock {
                defer { failed = true }
                return !failed
            }
            guard isFirst else { return }
            reader.cancelReading()
            writer.cancelWriting()
            pairs.indices.forEach(finish)
        }

        for (index, (output, input)) in pairs.enumerated() {
            group.enter()
            let queue = DispatchQueue(label: "com.serp.keybumps.screencast.mixdown.\(index)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard !lock.withLock({ failed || finished[index] }) else { return }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finish(index)
                        return
                    }
                    guard input.append(sample) else {
                        fail()
                        return
                    }
                }
            }
        }
        group.wait()
        if lock.withLock({ failed }) { throw MixdownError.writerFailed }
    }
}
