import Foundation
import WhisperKit

@MainActor
final class WhisperKitCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    private let whisper: WhisperKit
    private var activeTask: Task<DictationTranscription, Error>?

    private(set) var partialTranscript = ""

    /// Internal so tests can pass a WhisperKit that loads no model; the app uses `load`.
    init(whisper: WhisperKit) {
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
        let detects = DictationLanguage.isAutomatic(language)
        let whisper = whisper

        let task = Task<DictationTranscription, Error> {
            try Task.checkCancellation()

            // Automatic detects once per recording, from its first 30 seconds as whisper.cpp
            // does, and transcribes every chunk in that language; left to itself, WhisperKit
            // would detect again in each 30-second window. If that fails, each window detects.
            var once: String?
            if detects, let code = try? await whisper.detectLanguage(audioPath: audioURL.path).language, !code.isEmpty {
                once = code
            }
            try Task.checkCancellation()
            let options = Self.decodingOptions(language: language, detected: once)

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
            let detected = detects ? once ?? Self.dominantLanguage(of: results.map { ($0.language, $0.text) }) : nil
            return DictationTranscription(text: transcript, language: detected ?? language)
        }

        activeTask = task
        defer { activeTask = nil }
        let transcription = try await task.value
        partialTranscript = transcription.text
        return transcription
    }

    /// Automatic sets the language detected once for the recording (`detected`, WhisperKit's
    /// code such as `ja`), or leaves it out and detects it in each window when none was (a
    /// multilingual model only; WhisperKit ignores it for an English one). A chosen language is
    /// set, and never detected.
    static func decodingOptions(language: String, detected: String? = nil) -> DecodingOptions {
        let automatic = DictationLanguage.isAutomatic(language)
        let code = automatic ? detected : Locale(identifier: language).language.languageCode?.identifier
        return DecodingOptions(
            task: .transcribe,
            language: code,
            usePrefillPrompt: true,
            detectLanguage: automatic && code == nil,
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
