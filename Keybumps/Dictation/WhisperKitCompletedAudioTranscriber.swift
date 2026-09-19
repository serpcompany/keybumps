import Foundation
import WhisperKit

@MainActor
final class WhisperKitCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    private let whisper: WhisperKit
    private var activeTask: Task<String, Error>?

    private(set) var partialTranscript = ""

    private init(whisper: WhisperKit) {
        self.whisper = whisper
    }

    static func load(modelFolder: URL) async throws -> WhisperKitCompletedAudioTranscriber {
        let configuration = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        return WhisperKitCompletedAudioTranscriber(whisper: try await WhisperKit(configuration))
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        partialTranscript = ""
        let languageCode = Locale(identifier: language).language.languageCode?.identifier
        let whisper = whisper

        let task = Task<String, Error> {
            try Task.checkCancellation()

            let results = try await whisper.transcribe(
                audioPath: audioURL.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: DecodingOptions(
                    task: .transcribe,
                    language: languageCode,
                    usePrefillPrompt: true,
                    detectLanguage: false,
                    chunkingStrategy: .vad
                )
            )
            try Task.checkCancellation()
            let transcript = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw NSError(
                    domain: "Keybumps.Dictation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]
                )
            }
            return transcript
        }

        activeTask = task
        defer { activeTask = nil }
        let transcript = try await task.value
        partialTranscript = transcript
        return transcript
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    func unload() -> Task<Void, Never> {
        cancel()
        let whisper = whisper
        return Task { await whisper.unloadModels() }
    }
}
