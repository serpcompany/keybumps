import Foundation
import Speech

@MainActor
protocol CompletedAudioTranscribing: AnyObject {
    var partialTranscript: String { get }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String

    func cancel()
}

@MainActor
final class AppleSpeechCompletedAudioTranscriber: CompletedAudioTranscribing {
    private var task: SFSpeechRecognitionTask?
    private var completion: CheckedContinuation<String, Error>?
    private var transcriptAssembler = DictationTranscriptAssembler()
    private var timeoutTask: Task<Void, Never>?

    var partialTranscript: String { transcriptAssembler.transcript }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            throw NSError(
                domain: "Keybumps.Dictation",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "On-device speech is unavailable for \(language)."]
            )
        }

        transcriptAssembler = DictationTranscriptAssembler()
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in self?.receive(result: result, error: error) }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(
                    DictationTranscriptionPlan.timeout(forRecordedDuration: recordedDuration)
                ))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(error: NSError(
                        domain: "Keybumps.Dictation",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Transcription took too long. The audio recording was preserved."]
                    ))
                }
            }
        }
    }

    func cancel() {
        completion?.resume(throwing: CancellationError())
        completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let segments = result.bestTranscription.segments
            transcriptAssembler.receive(DictationTranscriptUpdate(
                text: result.bestTranscription.formattedString,
                segmentStart: segments.first?.timestamp ?? 0,
                segmentEnd: segments.last.map { $0.timestamp + $0.duration } ?? 0,
                isFinal: result.isFinal
            ))
            if result.isFinal { finish() }
        } else if let error, completion != nil {
            finish(error: error)
        }
    }

    private func finish(error: Error? = nil) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        task = nil

        if let error {
            completion.resume(throwing: error)
            return
        }

        let transcript = transcriptAssembler.transcript
        guard !transcript.isEmpty else {
            completion.resume(throwing: NSError(
                domain: "Keybumps.Dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]
            ))
            return
        }
        completion.resume(returning: transcript)
    }
}

@MainActor
final class DictationTranscriptionCoordinator: CompletedAudioTranscribing {
    typealias WhisperFactory = @MainActor (URL) -> any CompletedAudioTranscribing

    private let selectedEngine: () -> DictationTranscriptionEngine
    private let modelManager: DictationModelManager
    private let appleTranscriber: any CompletedAudioTranscribing
    private let whisperFactory: WhisperFactory
    private var activeTranscriber: (any CompletedAudioTranscribing)?

    var partialTranscript: String { activeTranscriber?.partialTranscript ?? "" }

    init(
        selectedEngine: @escaping () -> DictationTranscriptionEngine,
        modelManager: DictationModelManager,
        appleTranscriber: (any CompletedAudioTranscribing)? = nil,
        whisperFactory: WhisperFactory? = nil
    ) {
        self.selectedEngine = selectedEngine
        self.modelManager = modelManager
        self.appleTranscriber = appleTranscriber ?? AppleSpeechCompletedAudioTranscriber()
        self.whisperFactory = whisperFactory ?? { WhisperKitCompletedAudioTranscriber(modelFolder: $0) }
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        let engine = selectedEngine()
        let transcriber: any CompletedAudioTranscribing

        if engine.requiresDownload,
           engine.supports(language: language),
           let modelFolder = modelManager.installedModelFolder(for: engine) {
            transcriber = whisperFactory(modelFolder)
        } else {
            transcriber = appleTranscriber
        }

        activeTranscriber = transcriber
        defer { activeTranscriber = nil }
        return try await transcriber.transcribe(
            audioURL: audioURL,
            language: language,
            recordedDuration: recordedDuration
        )
    }

    func cancel() {
        activeTranscriber?.cancel()
    }
}
