import Foundation
import WhisperKit

@MainActor
final class WhisperKitCompletedAudioTranscriber: CompletedAudioTranscribing {
    private let modelFolder: URL
    private var activeTask: Task<String, Error>?

    private(set) var partialTranscript = ""

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        partialTranscript = ""
        let modelFolder = modelFolder
        let languageCode = Locale(identifier: language).language.languageCode?.identifier

        let task = Task<String, Error> {
            let configuration = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
            let whisper = try await WhisperKit(configuration)
            defer { Task { await whisper.unloadModels() } }
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
}
