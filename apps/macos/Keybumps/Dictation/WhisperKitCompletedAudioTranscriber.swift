import Foundation
import WhisperKit

@MainActor
final class WhisperKitCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    private let whisper: WhisperKit
    private var activeTask: Task<DictationTranscription, Error>?

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
        try await transcription(audioURL: audioURL, language: language, recordedDuration: recordedDuration).text
    }

    /// A chosen language is reported as given (`ja-JP`); one detected for Automatic as
    /// WhisperKit's code for it (`ja`), or as Automatic when it detected none.
    func transcription(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> DictationTranscription {
        partialTranscript = ""
        let options = Self.decodingOptions(language: language)
        let detects = options.detectLanguage
        let whisper = whisper

        let task = Task<DictationTranscription, Error> {
            try Task.checkCancellation()

            let results = try await whisper.transcribe(
                audioPath: audioURL.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: options
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
            let detected = detects ? Self.dominantLanguage(of: results.map { ($0.language, $0.text) }) : nil
            return DictationTranscription(text: transcript, language: detected ?? language)
        }

        activeTask = task
        defer { activeTask = nil }
        let transcription = try await task.value
        partialTranscript = transcription.text
        return transcription
    }

    /// Automatic leaves the language out and detects it (a multilingual model only; WhisperKit
    /// ignores it for an English one). A chosen language is set, and never detected.
    static func decodingOptions(language: String) -> DecodingOptions {
        let detects = DictationLanguage.isAutomatic(language)
        return DecodingOptions(
            task: .transcribe,
            language: detects ? nil : Locale(identifier: language).language.languageCode?.identifier,
            usePrefillPrompt: true,
            detectLanguage: detects,
            chunkingStrategy: .vad
        )
    }

    /// The language most of the transcript is in, by characters, from WhisperKit's language for
    /// each part it transcribed; nil when it reports none.
    static func dominantLanguage(of parts: [(language: String, text: String)]) -> String? {
        var characters: [String: Int] = [:]
        for part in parts where !part.language.isEmpty {
            characters[part.language, default: 0] += part.text.count
        }
        // Ties go to the code that sorts first, so the result never depends on dictionary order.
        return characters.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
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
