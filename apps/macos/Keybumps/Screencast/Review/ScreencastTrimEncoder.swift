import AVFoundation

/// Re-encodes the part of a recording that a trim keeps, for a trim that cuts the start. A
/// passthrough cut can only start at a keyframe (one a second in a recording), so it keeps up to a
/// second from before the trim in the file, hidden only by an edit list; a player that ignores edit
/// lists shows it. Here every track is decoded over the kept range, timed from zero, and written
/// again with the recorder's settings (`ScreencastMovieWriter.videoSettings`, `audioSettings`), so
/// the file holds nothing from before the trim:
/// - the picture: frames from the trim on, plus the one frame on screen at the trim point, which
///   starts at zero;
/// - each sound: cut to the sample at the trim, and at its end.
enum ScreencastTrimEncoder {
    /// The picture the trimmed file starts with, and its tracks' encoders.
    struct Plan: Sendable {
        let range: ScreencastTrimRange
        let pixelWidth: Int
        let pixelHeight: Int
        let framesPerSecond: Int
        let transform: CGAffineTransform
        /// Each audio track's channels, in track order.
        let audioChannels: [Int]
    }

    static func encode(_ source: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScreencastReviewFailure.trimFailed
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let transform = try await videoTrack.load(.preferredTransform)
        var channels: [Int] = []
        for track in audioTracks {
            let format = try await track.load(.formatDescriptions).first
            let description = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            channels.append(Int(description?.mChannelsPerFrame ?? 2))
        }
        let plan = Plan(
            range: range,
            pixelWidth: Int(size.width.rounded()),
            pixelHeight: Int(size.height.rounded()),
            framesPerSecond: frameRate > 0 ? Int(frameRate.rounded()) : 30,
            transform: transform,
            audioChannels: channels
        )
        let inputs = Inputs(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks)
        try? FileManager.default.removeItem(at: destination)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "com.serp.keybumps.screencast.trim", qos: .utility).async {
                    do {
                        try write(inputs, plan: plan, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ScreencastReviewFailure.trimFailed
        }
    }

    /// AVFoundation's asset objects, confined to the encoder's own queue once handed over.
    private final class Inputs: @unchecked Sendable {
        let asset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]

        init(asset: AVAsset, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack]) {
            self.asset = asset
            self.videoTrack = videoTrack
            self.audioTracks = audioTracks
        }
    }

    /// One track's way from the reader to the writer, and what's waiting to be appended.
    private final class Lane {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let cut: TrackCut
        var queued: [CMSampleBuffer] = []
        var isDrained = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, cut: TrackCut) {
            self.output = output
            self.input = input
            self.cut = cut
        }
    }

    private static func write(_ inputs: Inputs, plan: Plan, to destination: URL) throws {
        let start = CMTime(seconds: plan.range.start, preferredTimescale: 48_000)
        let end = CMTime(seconds: plan.range.end, preferredTimescale: 48_000)
        let reader = try AVAssetReader(asset: inputs.asset)
        reader.timeRange = CMTimeRange(start: start, end: end)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var lanes: [Lane] = []

        let videoOutput = AVAssetReaderTrackOutput(track: inputs.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: ScreencastMovieWriter.videoSettings(
                pixelWidth: plan.pixelWidth, pixelHeight: plan.pixelHeight, framesPerSecond: plan.framesPerSecond
            )
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = plan.transform
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw ScreencastReviewFailure.trimFailed }
        reader.add(videoOutput)
        writer.add(videoInput)
        lanes.append(Lane(output: videoOutput, input: videoInput, cut: VideoCut(start: start, end: end)))

        for (track, channels) in zip(inputs.audioTracks, plan.audioChannels) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ScreencastMovieWriter.audioSettings(channels: channels))
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw ScreencastReviewFailure.trimFailed }
            reader.add(output)
            writer.add(input)
            lanes.append(Lane(output: output, input: input, cut: AudioCut(start: start, end: end)))
        }

        guard writer.startWriting() else { throw ScreencastReviewFailure.trimFailed }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ScreencastReviewFailure.trimFailed
        }
        writer.startSession(atSourceTime: .zero)
        try pump(lanes, reader: reader, writer: writer)
        guard reader.status == .completed else { throw ScreencastReviewFailure.trimFailed }
        writer.endSession(atSourceTime: CMTime(seconds: plan.range.duration, preferredTimescale: 48_000))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw ScreencastReviewFailure.trimFailed }
    }

    /// Pulls each track through its cut into its input, each on its own queue, until all are done
    /// or one fails, as `ScreencastAudioMixdown` does.
    private static func pump(_ lanes: [Lane], reader: AVAssetReader, writer: AVAssetWriter) throws {
        let group = DispatchGroup()
        let lock = NSLock()
        var finished = Array(repeating: false, count: lanes.count)
        var failed = false

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
            lanes.indices.forEach(finish)
        }

        for (index, lane) in lanes.enumerated() {
            group.enter()
            let queue = DispatchQueue(label: "com.serp.keybumps.screencast.trim.\(index)")
            lane.input.requestMediaDataWhenReady(on: queue) {
                while lane.input.isReadyForMoreMediaData {
                    guard !lock.withLock({ failed || finished[index] }) else { return }
                    if !lane.queued.isEmpty {
                        guard lane.input.append(lane.queued.removeFirst()) else { return fail() }
                        continue
                    }
                    if lane.isDrained {
                        lane.input.markAsFinished()
                        return finish(index)
                    }
                    if let sample = lane.output.copyNextSampleBuffer() {
                        lane.queued += lane.cut.take(sample)
                    } else {
                        lane.queued += lane.cut.rest()
                        lane.isDrained = true
                    }
                }
            }
        }
        group.wait()
        if lock.withLock({ failed }) { throw ScreencastReviewFailure.trimFailed }
    }
}

/// What one track keeps of the samples a reader gives it for the kept range, timed from zero.
private protocol TrackCut: AnyObject {
    func take(_ sample: CMSampleBuffer) -> [CMSampleBuffer]
    /// Whatever it held back, once the reader has no more.
    func rest() -> [CMSampleBuffer]
}

/// The picture: frames from the trim point on, and the latest frame before it, which is the one on
/// screen at the trim point, moved to zero. Nothing earlier.
private final class VideoCut: TrackCut {
    private let start: CMTime
    private let end: CMTime
    /// The latest frame before the trim point, until a frame after it shows whether it's needed.
    private var onScreenAtStart: CMSampleBuffer?
    private var hasStarted = false

    init(start: CMTime, end: CMTime) {
        self.start = start
        self.end = end
    }

    func take(_ sample: CMSampleBuffer) -> [CMSampleBuffer] {
        let time = sample.presentationTimeStamp
        guard time.isNumeric, time < end else { return [] }
        if time < start, !hasStarted {
            onScreenAtStart = sample
            return []
        }
        var kept: [CMSampleBuffer] = []
        if !hasStarted {
            hasStarted = true
            if time > start, let frame = onScreenAtStart, let moved = ScreencastSampleTiming.retimed(frame, to: .zero) {
                kept.append(moved)
            }
            onScreenAtStart = nil
        }
        if let moved = ScreencastSampleTiming.retimed(sample, to: time - start) { kept.append(moved) }
        return kept
    }

    func rest() -> [CMSampleBuffer] {
        // A still screen may have no frame after the trim point: the one on screen then is the picture.
        guard !hasStarted, let frame = onScreenAtStart, let moved = ScreencastSampleTiming.retimed(frame, to: .zero) else { return [] }
        onScreenAtStart = nil
        return [moved]
    }
}

/// A sound: the samples from the trim point to the end, cut inside a buffer that crosses either.
private final class AudioCut: TrackCut {
    private let start: CMTime
    private let end: CMTime

    init(start: CMTime, end: CMTime) {
        self.start = start
        self.end = end
    }

    func take(_ sample: CMSampleBuffer) -> [CMSampleBuffer] {
        let time = sample.presentationTimeStamp
        let count = CMSampleBufferGetNumSamples(sample)
        guard time.isNumeric, count > 0,
              let format = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate > 0 else { return [] }
        let rate = description.mSampleRate
        let first = max(0, Int(((start - time).seconds * rate).rounded()))
        let last = min(count, Int(((end - time).seconds * rate).rounded()))
        guard last > first else { return [] }
        var kept = sample
        if first > 0 || last < count {
            var range: CMSampleBuffer?
            guard CMSampleBufferCopySampleBufferForRange(
                allocator: nil, sampleBuffer: sample, sampleRange: CFRange(location: first, length: last - first), sampleBufferOut: &range
            ) == noErr, let range else { return [] }
            kept = range
        }
        let keptTime = time + CMTime(value: CMTimeValue(first), timescale: CMTimeScale(rate))
        return ScreencastSampleTiming.retimed(kept, to: max(.zero, keptTime - start)).map { [$0] } ?? []
    }

    func rest() -> [CMSampleBuffer] { [] }
}

enum ScreencastSampleTiming {
    /// A copy of `sample` starting at `time`, every sample in it moved by the same amount.
    static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
            return nil
        }
        let shift = time - sample.presentationTimeStamp
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
            timing[index].decodeTimeStamp = .invalid
        }
        var moved: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &moved
        ) == noErr else { return nil }
        return moved
    }
}
