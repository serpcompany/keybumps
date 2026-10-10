import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@testable import Keybumps

// Stand-ins for Screencast's recording seams: sample buffers made up in memory, a writer sink
// that records what it's given, and a capture system and writers that never touch
// ScreenCaptureKit, the microphone, or the screen.

enum ScreencastSamples {
    static let sampleRate = 48_000.0
    /// Frames in one made-up audio buffer: about 21 ms, as ScreenCaptureKit delivers.
    static let audioFrames = 1_024

    /// A small BGRA frame stamped `host` seconds on the host clock.
    static func video(at host: Double, width: Int = 64, height: Int = 36, shade: UInt8 = 0x80) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pixelBuffer)
        let pixels = pixelBuffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time(host),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    /// `frames` of float PCM in `channels`, every sample `value`, stamped `host`: non-interleaved
    /// at 48 kHz, as the writer pads with, unless `sampleRate` or `interleaved` say otherwise.
    static func audio(
        at host: Double,
        frames: Int = audioFrames,
        channels: Int = 2,
        value: Float = 0.5,
        sampleRate rate: Double = sampleRate,
        interleaved: Bool = false
    ) -> CMSampleBuffer {
        let format = pcmFormat(channels: channels, sampleRate: rate, interleaved: interleaved)
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: format), frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { samples[index] = value }
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: time(host),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        CMSampleBufferSetDataBufferFromAudioBufferList(
            sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList
        )
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }

    /// Non-interleaved float PCM with a value per channel, built without `AVAudioFormat`, so any
    /// channel count works, with or without a layout (`discreteLayout`).
    static func audio(at host: Double, frames: Int = audioFrames, channelValues: [Float], discreteLayout: Bool = false) -> CMSampleBuffer {
        let channels = channelValues.count
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        var format: CMAudioFormatDescription?
        if discreteLayout {
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
            )
        } else {
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
            )
        }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, value) in channelValues.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            samples.initialize(repeating: value, count: frames)
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: samples)
        }
        return ScreencastAudioBuffers.sampleBuffer(frames: frames, format: format!, at: time(host), list: list.unsafePointer)!
    }

    /// Float PCM in any layout.
    static func pcmFormat(channels: Int, sampleRate rate: Double, interleaved: Bool) -> CMAudioFormatDescription {
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format!
    }

    /// A 440 Hz sine of `amplitude` in every channel, continuous from one buffer to the next because
    /// each sample's value comes from its host time.
    static func tone(at host: Double, frames: Int = audioFrames, channels: Int, amplitude: Float) -> CMSampleBuffer {
        let format = ScreencastAudioBuffers.defaultFormat(channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: format), frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let first = (host * sampleRate).rounded()
        for channel in 0..<channels {
            let samples = pcm.floatChannelData![channel]
            for index in 0..<frames {
                samples[index] = amplitude * Float(sin(2 * Double.pi * 440 * (first + Double(index)) / sampleRate))
            }
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: time(host),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        CMSampleBufferSetDataBufferFromAudioBufferList(
            sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList
        )
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }

    static var audioBufferSeconds: Double { Double(audioFrames) / sampleRate }

    static func time(_ host: Double) -> CMTime {
        CMTime(seconds: host, preferredTimescale: 1_000_000_000)
    }

    /// The largest absolute sample in a float PCM buffer.
    static func peak(of sample: CMSampleBuffer) -> Float {
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        )
        return withExtendedLifetime(block) {
            UnsafeMutableAudioBufferListPointer(list).reduce(Float(0)) { peak, buffer in
                let samples = UnsafeBufferPointer(
                    start: buffer.mData!.assumingMemoryBound(to: Float.self),
                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                )
                return max(peak, samples.map(abs).max() ?? 0)
            }
        }
    }
}

/// A writer sink that keeps what it's given, in order.
final class RecordingSink: ScreencastMovieSink {
    struct Append: Equatable {
        let track: ScreencastTrack
        /// Recording seconds.
        let start: Double
        /// Seconds of audio; zero for video.
        let duration: Double
        let isSilent: Bool
        /// Audio only: its format's sample rate and channels.
        var sampleRate: Double = 0
        var channels = 0
    }

    let audioSources: [ScreencastAudioSource]
    var hasFailed = false
    var isReady = true
    /// Like a real encoder, an audio input that's taken this many buffers in a row isn't ready the
    /// next time it's asked, then is again. Nil: always ready.
    var audioNotReadyAfter: Int?
    private var appendsSinceNotReady: [ScreencastTrack: Int] = [:]
    private(set) var notReadyAnswers = 0
    private(set) var sessionStarted = false
    private(set) var appends: [Append] = []

    init(audio: [ScreencastAudioSource], audioNotReadyAfter: Int? = nil) {
        audioSources = audio
        self.audioNotReadyAfter = audioNotReadyAfter
    }

    func startSession() {
        sessionStarted = true
    }

    func isReady(for track: ScreencastTrack) -> Bool {
        guard isReady else { return false }
        if track != .video, let limit = audioNotReadyAfter, appendsSinceNotReady[track, default: 0] >= limit {
            appendsSinceNotReady[track] = 0
            notReadyAnswers += 1
            return false
        }
        return true
    }

    func append(_ sample: CMSampleBuffer, to track: ScreencastTrack) -> Bool {
        guard !hasFailed else { return false }
        appendsSinceNotReady[track, default: 0] += 1
        let start = sample.presentationTimeStamp.seconds
        switch track {
        case .video:
            appends.append(Append(track: track, start: start, duration: 0, isSilent: false))
        case .audio:
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample)!)!.pointee
            let duration = Double(CMSampleBufferGetNumSamples(sample)) / description.mSampleRate
            appends.append(Append(
                track: track, start: start, duration: duration, isSilent: ScreencastSamples.peak(of: sample) == 0,
                sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame)
            ))
        }
        return true
    }

    func audio(_ source: ScreencastAudioSource) -> [Append] {
        appends.filter { $0.track == .audio(source) }
    }

    var video: [Append] {
        appends.filter { $0.track == .video }
    }

    /// Seconds of real sound (not silence) on `source`'s track between `start` and `end`.
    func sound(_ source: ScreencastAudioSource, from start: Double, to end: Double) -> Double {
        audio(source).filter { !$0.isSilent }.reduce(0) { sum, append in
            sum + max(0, min(append.start + append.duration, end) - max(append.start, start))
        }
    }
}

// MARK: - The recorder's seams

/// A writer that keeps every call, and finishes as told.
final class FakeMovieWriter: ScreencastMovieWriting, @unchecked Sendable {
    enum Call: Equatable {
        case video(host: Double)
        case audio(ScreencastAudioSource, host: Double)
        case pause(Double)
        case resume(Double)
        case setAudio(ScreencastAudioSource, on: Bool, host: Double)
        case finish(Double)
        case cancel
    }

    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let audioSources: [ScreencastAudioSource]
    let onFailure: @Sendable () -> Void
    var finishDuration = 5.0
    var finishFailed = false
    /// Holds `cancel()` until `releaseCancel()`, and `finish(at:)` until `releaseFinish()`.
    var holdsCancel = false
    var holdsFinish = false
    private var heldFinish: CheckedContinuation<Void, Never>?
    private var heldCancel: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(url: URL, pixelWidth: Int, pixelHeight: Int, audio: [ScreencastAudioSource], onFailure: @escaping @Sendable () -> Void) {
        fileURL = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        audioSources = audio
        self.onFailure = onFailure
        FileManager.default.createFile(atPath: url.path, contents: Data("movie".utf8))
    }

    var calls: [Call] { lock.withLock { recorded } }
    var videoHosts: [Double] {
        calls.compactMap { if case .video(let host) = $0 { host } else { nil } }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    func appendVideo(_ sample: CMSampleBuffer) { record(.video(host: sample.presentationTimeStamp.seconds)) }
    func appendAudio(_ sample: CMSampleBuffer, from source: ScreencastAudioSource) {
        record(.audio(source, host: sample.presentationTimeStamp.seconds))
    }
    func pause(at host: Double) { record(.pause(host)) }
    func resume(at host: Double) { record(.resume(host)) }
    func setAudio(_ source: ScreencastAudioSource, on: Bool, at host: Double) { record(.setAudio(source, on: on, host: host)) }
    /// Kept apart from `calls`: the recorder's tick calls it.
    private(set) var keptUpAt: [Double] = []
    func keepUp(at host: Double) { lock.withLock { keptUpAt.append(host) } }

    func finish(at host: Double) async -> ScreencastWriterResult {
        record(.finish(host))
        if holdsFinish {
            await withCheckedContinuation { continuation in lock.withLock { heldFinish = continuation } }
        }
        return ScreencastWriterResult(fileURL: fileURL, duration: finishDuration, failed: finishFailed)
    }

    var isHoldingFinish: Bool { lock.withLock { heldFinish != nil } }

    func releaseFinish() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldFinish = nil }
            return heldFinish
        }
        held?.resume()
    }

    var isHoldingCancel: Bool { lock.withLock { heldCancel != nil } }

    func cancel() async {
        record(.cancel)
        if holdsCancel {
            await withCheckedContinuation { continuation in lock.withLock { heldCancel = continuation } }
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func releaseCancel() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldCancel = nil }
            return heldCancel
        }
        held?.resume()
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}

final class FakeWriterFactory: ScreencastWriterFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeMovieWriter] = []
    private var mixed: [(URL, URL)] = []
    var mixdownFails = false
    /// Applied to each writer as it's made.
    var configure: (FakeMovieWriter) -> Void = { _ in }

    var writers: [FakeMovieWriter] { lock.withLock { made } }
    var mixdowns: [(source: URL, destination: URL)] { lock.withLock { mixed } }

    func makeWriter(
        at url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        audio: [ScreencastAudioSource],
        options: ScreencastOptions,
        onFailure: @escaping @Sendable () -> Void
    ) throws -> any ScreencastMovieWriting {
        let writer = FakeMovieWriter(url: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight, audio: audio, onFailure: onFailure)
        configure(writer)
        lock.withLock { made.append(writer) }
        return writer
    }

    func writeMixdown(of source: URL, to destination: URL) async throws {
        if mixdownFails { throw ScreencastAudioMixdown.MixdownError.writerFailed }
        lock.withLock { mixed.append((source, destination)) }
        FileManager.default.createFile(atPath: destination.path, contents: Data("mixdown".utf8))
    }
}

@MainActor
final class FakeStream: ScreencastStream {
    enum Kind: Equatable {
        case video(ScreencastFilterPlan, ScreencastStreamConfiguration)
        case audio(ScreencastAudio)
    }

    let kind: Kind
    let handler: ScreencastSampleHandler
    var startError: ScreencastFailure?
    /// Holds `start()` until `releaseStart()`.
    var holdsStart = false
    private var heldStart: CheckedContinuation<Void, Never>?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var plans: [ScreencastFilterPlan] = []
    private(set) var sourceRects: [CGRect] = []
    /// Holds each update until `releaseUpdates()`, to see how many are in flight at once.
    var holdsUpdates = false
    private var heldUpdates: [CheckedContinuation<Void, Never>] = []
    private var updatesInFlight = 0
    private(set) var mostUpdatesInFlight = 0

    init(kind: Kind, handler: ScreencastSampleHandler) {
        self.kind = kind
        self.handler = handler
    }

    var isHoldingStart: Bool { heldStart != nil }

    func start() async throws {
        startCount += 1
        if holdsStart {
            await withCheckedContinuation { heldStart = $0 }
        }
        if let startError { throw startError }
        isRunning = true
    }

    func releaseStart() {
        heldStart?.resume()
        heldStart = nil
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    func update(plan: ScreencastFilterPlan, content: ScreencastContent) async throws {
        await holdUpdate()
        plans.append(plan)
    }

    /// The next this many crop updates throw, as ScreenCaptureKit can.
    var sourceRectFailures = 0

    func update(sourceRect: CGRect) async throws {
        await holdUpdate()
        if sourceRectFailures > 0 {
            sourceRectFailures -= 1
            throw ScreencastFailure.captureFailed
        }
        sourceRects.append(sourceRect)
    }

    var heldUpdateCount: Int { heldUpdates.count }

    func releaseUpdates() {
        let held = heldUpdates
        heldUpdates = []
        held.forEach { $0.resume() }
    }

    private func holdUpdate() async {
        updatesInFlight += 1
        mostUpdatesInFlight = max(mostUpdatesInFlight, updatesInFlight)
        if holdsUpdates { await withCheckedContinuation { heldUpdates.append($0) } }
        updatesInFlight -= 1
    }

    /// Delivers a frame stamped `host`, as ScreenCaptureKit would on its queue.
    func deliverFrame(at host: Double) {
        handler.video(ScreencastSamples.video(at: host))
    }

    func deliverAudio(_ source: ScreencastAudioSource, at host: Double, value: Float = 0.5) {
        handler.audio(ScreencastSamples.audio(at: host, channels: source == .systemAudio ? 2 : 1, value: value), source)
    }
}

@MainActor
final class FakeCaptureSystem: ScreencastCaptureSystem {
    var screen: ScreencastContent
    var contentError: ScreencastFailure?
    var videoStartError: ScreencastFailure?
    var audioStartError: ScreencastFailure?
    /// Fails a sound stream only while it asks for the microphone, as when Microphone access is off.
    var microphoneStartError: ScreencastFailure?
    var windowFrames: [CGWindowID: CGRect] = [:]
    var ownWindows: Set<CGWindowID> = []
    /// Video streams made from now on hold their start until released.
    var holdsVideoStart = false
    private(set) var videoStreams: [FakeStream] = []
    private(set) var audioStreams: [FakeStream] = []
    private(set) var contentReads = 0

    init(content: ScreencastContent) {
        screen = content
    }

    /// Runs once, right after the next snapshot is taken: what changes on screen meanwhile.
    var afterContentRead: (() -> Void)?

    /// The next this many snapshots fail.
    var contentFailures = 0
    /// Each read's `onScreenOnly`, in order.
    private(set) var readKinds: [Bool] = []
    /// Holds each snapshot until `releaseContent()`.
    var holdsContent = false
    private var heldContent: [CheckedContinuation<Void, Never>] = []
    var heldContentCount: Int { heldContent.count }

    func releaseContent() {
        let held = heldContent
        heldContent = []
        held.forEach { $0.resume() }
    }

    func content() async throws -> ScreencastContent {
        try await content(onScreenOnly: false)
    }

    func content(onScreenOnly: Bool) async throws -> ScreencastContent {
        contentReads += 1
        readKinds.append(onScreenOnly)
        if holdsContent { await withCheckedContinuation { heldContent.append($0) } }
        if let contentError { throw contentError }
        if contentFailures > 0 {
            contentFailures -= 1
            throw ScreencastFailure.captureFailed
        }
        // An on-screen read leaves out what isn't: minimized, hidden, or on another Space.
        let snapshot = onScreenOnly
            ? ScreencastContent(displays: screen.displays, windows: screen.windows.filter(\.isOnScreen), applicationProcessIDs: screen.applicationProcessIDs)
            : screen
        let after = afterContentRead
        afterContentRead = nil
        after?()
        return snapshot
    }

    func makeVideoStream(
        plan: ScreencastFilterPlan,
        configuration: ScreencastStreamConfiguration,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream {
        let stream = FakeStream(kind: .video(plan, configuration), handler: handler)
        stream.startError = videoStartError
        stream.holdsStart = holdsVideoStart
        videoStreams.append(stream)
        return stream
    }

    func makeAudioStream(audio: ScreencastAudio, content: ScreencastContent, handler: ScreencastSampleHandler) throws -> any ScreencastStream {
        let stream = FakeStream(kind: .audio(audio), handler: handler)
        stream.startError = audio.microphone ? (microphoneStartError ?? audioStartError) : audioStartError
        audioStreams.append(stream)
        return stream
    }

    func windowFrame(_ id: CGWindowID) -> CGRect? {
        windowFrames[id]
    }

    func ownVisibleWindows() -> Set<CGWindowID> {
        ownWindows
    }

    /// From the screen as it is, like `CGWindowList`.
    func onScreenWindows(of processID: pid_t) -> Set<CGWindowID>? {
        Set(screen.windows.filter { $0.processID == processID && $0.isOnScreen }.map(\.id))
    }

    /// On screen or not; only a window gone from the screen's list is closed.
    func windowExists(_ id: CGWindowID) -> Bool? {
        screen.windows.contains { $0.id == id }
    }
}

/// A host clock tests move by hand.
@MainActor
final class FakeHostClock {
    var now = 1_000.0

    func advance(_ seconds: Double) {
        now += seconds
    }
}

/// Made-up screens: two displays side by side, a browser window with a sheet and another
/// window, and Keybumps with a control bar and an overlay.
enum ScreencastScreens {
    static let ownProcess: pid_t = 900
    static let browser: pid_t = 501
    static let otherApp: pid_t = 502

    static let leftDisplay = ScreencastContent.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let rightDisplay = ScreencastContent.Display(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)

    static let browserWindow = ScreencastContent.Window(
        id: 10, frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0, processID: browser, isUntitled: false, isOnScreen: true
    )
    static let browserSheet = ScreencastContent.Window(
        id: 11, frame: CGRect(x: 300, y: 130, width: 400, height: 200), layer: 0, processID: browser, isUntitled: true, isOnScreen: true
    )
    static let browserOtherWindow = ScreencastContent.Window(
        id: 12, frame: CGRect(x: 200, y: 200, width: 800, height: 600), layer: 0, processID: browser, isUntitled: false, isOnScreen: true
    )
    static let browserMenu = ScreencastContent.Window(
        id: 13, frame: CGRect(x: 120, y: 120, width: 200, height: 300), layer: 101, processID: browser, isUntitled: true, isOnScreen: true
    )
    static let otherAppWindow = ScreencastContent.Window(
        id: 20, frame: CGRect(x: 1600, y: 100, width: 800, height: 600), layer: 0, processID: otherApp, isUntitled: false, isOnScreen: true
    )
    static let controlBar = ScreencastContent.Window(
        id: 30, frame: CGRect(x: 600, y: 900, width: 300, height: 44), layer: 3, processID: ownProcess, isUntitled: true, isOnScreen: true
    )
    static let drawingLayer = ScreencastContent.Window(
        id: 31, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 3, processID: ownProcess, isUntitled: true, isOnScreen: true
    )

    /// `window` with its on-screen state, frame, or place front to back changed.
    static func with(_ window: ScreencastContent.Window, onScreen: Bool? = nil, frame: CGRect? = nil, order: Int?? = nil) -> ScreencastContent.Window {
        var changed = ScreencastContent.Window(
            id: window.id, frame: frame ?? window.frame, layer: window.layer, processID: window.processID,
            isUntitled: window.isUntitled, isOnScreen: onScreen ?? window.isOnScreen, order: window.order
        )
        if let order { changed.order = order }
        return changed
    }

    static func content(windows: [ScreencastContent.Window]? = nil, includesOwnApp: Bool = true) -> ScreencastContent {
        ScreencastContent(
            displays: [rightDisplay, leftDisplay],
            windows: windows ?? [browserWindow, browserSheet, browserOtherWindow, browserMenu, otherAppWindow, controlBar, drawingLayer],
            applicationProcessIDs: includesOwnApp ? [browser, otherApp, ownProcess] : [browser, otherApp]
        )
    }
}

/// A temporary captures folder, removed by `remove()`.
struct TemporaryCapturesFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreencastTests-\(UUID().uuidString)", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func captureFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
