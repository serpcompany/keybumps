import AVFoundation
import CoreMedia

/// PCM sample buffers the writer makes for itself: silence to pad a track, a buffer with its start
/// cut off, and a default format for a track that never received audio. Works for interleaved and
/// planar layouts alike.
///
/// The silence is adapted from BetterCapture's `SilentAudioBuffer` (MIT, see LICENSE.bettercapture);
/// trimming and the default format from Shotnix's `RecordingAudioBuffers` (MIT, see LICENSE.shotnix).
enum ScreencastAudioBuffers {
    /// `frames` of silence in `format`, starting at `time`, so the writer appends it to the same
    /// track without a format change. Nil when the format isn't uncompressed PCM.
    static func silence(frames: Int, format: CMAudioFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        guard frames > 0, pcmDescription(format) != nil else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: format)
        guard audioFormat.sampleRate > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        // AVAudioPCMBuffer doesn't promise zeroed memory.
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return sampleBuffer(frames: frames, format: format, at: time, list: pcm.audioBufferList)
    }

    /// `buffer` without its first `frames` frames, starting at `time`.
    static func dropping(frames: Int, from buffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        let total = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, frames < total,
              let format = CMSampleBufferGetFormatDescription(buffer),
              let description = pcmDescription(format) else { return nil }
        return withAudioBufferList(of: buffer) { list in
            let offset = frames * Int(description.mBytesPerFrame)
            for index in 0..<list.count {
                guard let data = list[index].mData, Int(list[index].mDataByteSize) > offset else { return nil }
                list[index].mData = data + offset
                list[index].mDataByteSize -= UInt32(offset)
            }
            return sampleBuffer(frames: total - frames, format: format, at: time, list: UnsafePointer(list.unsafePointer))
        }
    }

    /// Float PCM at 48 kHz, for padding a track that never received audio.
    static func defaultFormat(channels: Int) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format
    }

    /// Whether two PCM formats lay out samples the same way: rate, channels, and sample format.
    static func samePCMLayout(_ first: CMAudioFormatDescription, _ second: CMAudioFormatDescription) -> Bool {
        guard let a = pcmDescription(first), let b = pcmDescription(second) else { return false }
        return a.mSampleRate == b.mSampleRate && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    static func sampleRate(of format: CMAudioFormatDescription) -> Double? {
        guard let rate = pcmDescription(format)?.mSampleRate, rate > 0 else { return nil }
        return rate
    }

    /// How loud `buffer` is, from 0 (silence or room hiss) to 1 (loud speech), for the control
    /// bar's microphone meter. Its RMS in decibels, mapped from a -54 dB to -6 dB window, after
    /// Snapzy's `RecordingAudioLevelMeter` (BSD-3-Clause, see LICENSE.snapzy). Float and 16-bit PCM.
    static func level(of buffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = pcmDescription(format) else { return 0 }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = description.mBitsPerChannel
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return 0 }
        let rms: Float = withAudioBufferList(of: buffer) { list in
            var sumOfSquares: Float = 0
            var count = 0
            for audioBuffer in list {
                guard let data = audioBuffer.mData else { continue }
                if isFloat {
                    let samples = UnsafeBufferPointer(
                        start: data.assumingMemoryBound(to: Float.self),
                        count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                    )
                    for sample in samples { sumOfSquares += sample * sample }
                    count += samples.count
                } else {
                    let samples = UnsafeBufferPointer(
                        start: data.assumingMemoryBound(to: Int16.self),
                        count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                    )
                    for sample in samples {
                        let value = Float(sample) / Float(Int16.max)
                        sumOfSquares += value * value
                    }
                    count += samples.count
                }
            }
            return count > 0 ? (sumOfSquares / Float(count)).squareRoot() : 0
        } ?? 0
        return normalizedLevel(rms: rms)
    }

    /// RMS 0…1 to the meter's 0…1: quieter than -54 dB is 0, louder than -6 dB is 1.
    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 54) / 48, 0), 1)
    }

    // MARK: Building buffers

    private static func pcmDescription(_ format: CMAudioFormatDescription) -> AudioStreamBasicDescription? {
        guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mBytesPerFrame > 0 else { return nil }
        return description
    }

    /// Runs `body` over `buffer`'s audio, which stays alive until it returns.
    private static func withAudioBufferList<Result>(
        of buffer: CMSampleBuffer,
        _ body: (UnsafeMutableAudioBufferListPointer) -> Result?
    ) -> Result? {
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        ) == noErr else { return nil }
        return withExtendedLifetime(block) {
            body(UnsafeMutableAudioBufferListPointer(listPointer))
        }
    }

    /// A ready sample buffer of `frames` from `list`, whose data is copied in.
    static func sampleBuffer(
        frames: Int,
        format: CMAudioFormatDescription,
        at time: CMTime,
        list: UnsafePointer<AudioBufferList>
    ) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: list
        ) == noErr else { return nil }
        CMSampleBufferSetDataReady(sample)
        return sample
    }
}

/// Converts one sound's PCM buffers into its track's format, so a track keeps the single format it
/// started with: the first buffer's, or the silence the writer padded it with before any came. A
/// microphone that starts late, or changes device mid-recording, then never changes the format an
/// `AVAssetWriterInput` was fed. Keeps its converter, so a resampled sound stays continuous.
final class ScreencastAudioConformer {
    private var converter: AVAudioConverter?
    private var converterInput: CMAudioFormatDescription?

    /// `sample` in `format`, stamped as it was; itself when it's already laid out that way. Nil when
    /// it can't be converted.
    func conform(_ sample: CMSampleBuffer, to format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let input = CMSampleBufferGetFormatDescription(sample) else { return nil }
        if ScreencastAudioBuffers.samePCMLayout(input, format) { return sample }
        let from = AVAudioFormat(cmAudioFormatDescription: input)
        let to = AVAudioFormat(cmAudioFormatDescription: format)
        if converter == nil || converterInput.map({ !ScreencastAudioBuffers.samePCMLayout($0, input) }) == true {
            converter = AVAudioConverter(from: from, to: to)
            converterInput = input
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard let converter, frames > 0, from.sampleRate > 0,
              let source = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        source.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList
        ) == noErr else { return nil }
        let capacity = AVAudioFrameCount((Double(frames) * to.sampleRate / from.sampleRate).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            guard !handedOver else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return ScreencastAudioBuffers.sampleBuffer(
            frames: Int(converted.frameLength),
            format: format,
            at: sample.presentationTimeStamp,
            list: converted.audioBufferList
        )
    }
}
