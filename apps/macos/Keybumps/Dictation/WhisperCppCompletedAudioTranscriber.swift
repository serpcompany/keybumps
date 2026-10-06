import AVFoundation
import Foundation
import whisper

/// Transcribes with whisper.cpp on the GPU (ADR 0008). The model must have no Core ML encoder
/// (`*-encoder.mlmodelc`) beside it, so the Neural Engine is never used.
@MainActor
final class WhisperCppCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    private let runtime: WhisperCppRuntime
    private(set) var partialTranscript = ""

    private init(runtime: WhisperCppRuntime) {
        self.runtime = runtime
    }

    static func load(modelFile: URL) async throws -> WhisperCppCompletedAudioTranscriber {
        let runtime = try await WhisperCppRuntime.load(modelFile: modelFile)
        // The first run sets up GPU buffers (about 0.5 s); do it here, during the load that starts
        // with the recording, rather than in the person's first transcription.
        _ = try? await runtime.transcribe(
            samples: [Float](repeating: 0, count: Int(WhisperCppAudio.sampleRate)),
            language: "en"
        )
        return WhisperCppCompletedAudioTranscriber(runtime: runtime)
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        partialTranscript = ""
        let samples = try await Task.detached(priority: .userInitiated) {
            try WhisperCppAudio.samples(from: audioURL)
        }.value
        let languageCode = Locale(identifier: language).language.languageCode?.identifier ?? "auto"
        let transcript = try await runtime.transcribe(samples: samples, language: languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw NSError(
                domain: "Keybumps.Dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]
            )
        }
        partialTranscript = transcript
        return transcript
    }

    func cancel() {
        runtime.abort()
    }

    func unload() -> Task<Void, Never> {
        cancel()
        let runtime = runtime
        return Task { await runtime.free() }
    }
}

/// Owns one whisper.cpp context. Every call into whisper.cpp runs on one serial queue, so a
/// transcription and an unload never overlap.
final class WhisperCppRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.serp.keybumps.whisper-cpp", qos: .userInitiated)
    /// Touched only on `queue`.
    private var context: OpaquePointer?
    private let abortFlag = WhisperCppAbortFlag()

    private static let silenceLogs: Void = {
        // whisper.cpp logs to stderr by default; Keybumps keeps its logs structural.
        whisper_log_set({ _, _, _ in }, nil)
    }()

    private init() {}

    static func load(modelFile: URL) async throws -> WhisperCppRuntime {
        _ = silenceLogs
        let runtime = WhisperCppRuntime()
        try await runtime.run {
            var parameters = whisper_context_default_params()
            parameters.use_gpu = true
            parameters.flash_attn = true
            guard let context = whisper_init_from_file_with_params(modelFile.path, parameters) else {
                throw NSError(
                    domain: "Keybumps.Dictation",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The transcription model couldn't be loaded."]
                )
            }
            runtime.context = context
        }
        return runtime
    }

    /// Greedy decoding over full 30-second windows, without timestamps.
    func transcribe(samples: [Float], language: String) async throws -> String {
        abortFlag.isSet = false
        return try await run { [self] in
            guard let context else { throw CancellationError() }
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

    /// Stops a transcription that's running; it ends with `CancellationError`.
    func abort() {
        abortFlag.isSet = true
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
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let inputCapacity: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * sampleRate / source.sampleRate) + 1_024
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate) + 1)
        var reachedEnd = false
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if !reachedEnd {
                    do {
                        try file.read(into: input, frameCount: inputCapacity)
                    } catch {
                        input.frameLength = 0
                    }
                    reachedEnd = input.frameLength == 0
                }
                guard !reachedEnd else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || (reachedEnd && output.frameLength == 0) {
                break
            }
        }
        return samples
    }
}
