import AVFoundation
import Foundation
import whisper

/// Transcribes with whisper.cpp on the GPU (ADR 0008). The model must have no Core ML encoder
/// (`*-encoder.mlmodelc`) beside it, so the Neural Engine is never used.
@MainActor
final class WhisperCppCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    typealias SampleLoader = @Sendable (URL) async throws -> [Float]

    private let runtime: any WhisperCppTranscribing
    private let loadSamples: SampleLoader
    /// The abort flag of the transcription in progress, so a cancel reaches only that call.
    private var activeCall: WhisperCppAbortFlag?
    private(set) var partialTranscript = ""

    init(
        runtime: any WhisperCppTranscribing,
        loadSamples: @escaping SampleLoader = { url in
            try await Task.detached(priority: .userInitiated) {
                try WhisperCppAudio.samples(from: url)
            }.value
        }
    ) {
        self.runtime = runtime
        self.loadSamples = loadSamples
    }

    static func load(modelFile: URL) async throws -> WhisperCppCompletedAudioTranscriber {
        let runtime = try await WhisperCppRuntime.load(modelFile: modelFile)
        // The first run sets up GPU buffers (about 0.5 s); do it here, during the load that starts
        // with the recording, rather than in the person's first transcription.
        _ = try? await runtime.transcribe(
            samples: [Float](repeating: 0, count: Int(WhisperCppAudio.sampleRate)),
            language: "en",
            abort: WhisperCppAbortFlag()
        )
        return WhisperCppCompletedAudioTranscriber(runtime: runtime)
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        partialTranscript = ""
        let call = WhisperCppAbortFlag()
        activeCall = call
        defer { if activeCall === call { activeCall = nil } }

        let samples = try await loadSamples(audioURL)
        if call.isSet { throw CancellationError() }
        // whisper.cpp keeps the previous call's audio features and decodes them again when it's
        // given no samples, so an empty recording must never reach it.
        guard !samples.isEmpty else { throw Self.noSpeech }
        let languageCode = Locale(identifier: language).language.languageCode?.identifier ?? "auto"
        let transcript = try await runtime.transcribe(samples: samples, language: languageCode, abort: call)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw Self.noSpeech }
        partialTranscript = transcript
        return transcript
    }

    func cancel() {
        activeCall?.isSet = true
    }

    func unload() -> Task<Void, Never> {
        cancel()
        let runtime = runtime
        return Task { await runtime.free() }
    }

    private static let noSpeech = NSError(
        domain: "Keybumps.Dictation",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]
    )
}

/// A loaded whisper.cpp model; a seam so tests can stand in for the real one.
protocol WhisperCppTranscribing: AnyObject, Sendable {
    func transcribe(samples: [Float], language: String, abort: WhisperCppAbortFlag) async throws -> String
    func free() async
}

/// Owns one whisper.cpp context. Every call into whisper.cpp runs on one serial queue, so a
/// transcription and an unload never overlap.
final class WhisperCppRuntime: WhisperCppTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.serp.keybumps.whisper-cpp", qos: .userInitiated)
    /// Touched only on `queue`.
    private var context: OpaquePointer?

    private static let silenceLogs: Void = {
        // whisper.cpp logs to stderr by default; Keybumps keeps its logs structural.
        whisper_log_set({ _, _, _ in }, nil)
    }()

    private init() {}

    private static let loadFailure = NSError(
        domain: "Keybumps.Dictation",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "The transcription model couldn't be loaded."]
    )

    static func load(modelFile: URL) async throws -> WhisperCppRuntime {
        _ = silenceLogs
        // A file that isn't a ggml model fails here, before whisper.cpp compiles its GPU shaders.
        guard WhisperCppModel.hasModelHeader(modelFile) else { throw loadFailure }
        let runtime = WhisperCppRuntime()
        try await runtime.run {
            var parameters = whisper_context_default_params()
            parameters.use_gpu = true
            parameters.flash_attn = true
            guard let context = whisper_init_from_file_with_params(modelFile.path, parameters) else {
                throw loadFailure
            }
            runtime.context = context
        }
        return runtime
    }

    /// Greedy decoding over full 30-second windows, without timestamps. Setting `abort` stops it
    /// with `CancellationError`.
    func transcribe(samples: [Float], language: String, abort abortFlag: WhisperCppAbortFlag) async throws -> String {
        try await run { [self] in
            guard let context, !abortFlag.isSet else { throw CancellationError() }
            guard !samples.isEmpty else { return "" }
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
            parameters.no_timestamps = true
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            parameters.print_special = false
            parameters.detect_language = false
            parameters.abort_callback = { data in
                guard let data else { return false }
                return Unmanaged<WhisperCppAbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
            }
            parameters.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()
            let status = language.withCString { languageCode in
                parameters.language = languageCode
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
                }
            }
            if abortFlag.isSet { throw CancellationError() }
            guard status == 0 else {
                throw NSError(
                    domain: "Keybumps.Dictation",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Transcription failed (whisper.cpp \(status))."]
                )
            }
            return (0..<whisper_full_n_segments(context))
                .map { String(cString: whisper_full_get_segment_text(context, $0)) }
                .joined()
        }
    }

    func free() async {
        try? await run { [self] in
            if let context { whisper_free(context) }
            context = nil
        }
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// Read by whisper.cpp's abort callback on its own thread.
final class WhisperCppAbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Reads a recording as the 16 kHz mono 32-bit float samples whisper.cpp expects.
enum WhisperCppAudio {
    static let sampleRate: Double = 16_000

    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        // Channels are summed into one before resampling, as WhisperKit does: Apple's converter
        // keeps only channel 0 of a stereo file, and outputs silence for 3 or more channels.
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: 1,
            interleaved: false
        ), let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: mono, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let inputCapacity: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * sampleRate / source.sampleRate) + 1_024
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: inputCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate) + 1)
        var reachedEnd = false
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if !reachedEnd {
                    // The end is known from the position: reading past it throws an end-of-file
                    // error, so any error from a read before the end is a real one.
                    let remaining = file.length - file.framePosition
                    if remaining <= 0 {
                        input.frameLength = 0
                    } else {
                        do {
                            try file.read(into: input, frameCount: min(inputCapacity, AVAudioFrameCount(remaining)))
                        } catch {
                            readError = error
                            input.frameLength = 0
                        }
                    }
                    reachedEnd = input.frameLength == 0
                }
                guard !reachedEnd else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                sumChannels(of: input, into: mixed)
                inputStatus.pointee = .haveData
                return mixed
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || (reachedEnd && output.frameLength == 0) {
                break
            }
        }
        // Summing can go past full scale when channels carry the same sound; scale it back.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1 {
            let scale = 1 / peak
            for index in samples.indices { samples[index] *= scale }
        }
        return samples
    }

    private static func sumChannels(of input: AVAudioPCMBuffer, into mixed: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        mixed.frameLength = input.frameLength
        guard let channels = input.floatChannelData, let destination = mixed.floatChannelData?[0] else { return }
        let channelCount = Int(input.format.channelCount)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            destination[frame] = sum
        }
    }
}
