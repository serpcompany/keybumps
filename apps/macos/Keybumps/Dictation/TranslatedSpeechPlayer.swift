import AVFoundation
import Foundation
import Observation

struct TranslationSpeechVoiceDescriptor: Equatable {
    let identifier: String
    let language: String
}

enum TranslationSpeechVoiceSelector {
    /// An installed voice for the language: one for exactly that language and region, or else any
    /// in the same language. Nil when none is installed, so nothing is read in another language's
    /// voice.
    static func preferredVoiceIdentifier(
        targetLanguageIdentifier: String,
        supportedVoices: [TranslationSpeechVoiceDescriptor]
    ) -> String? {
        let targetLanguageIdentifier = voiceLanguage(for: targetLanguageIdentifier)
        if let exactMatch = supportedVoices.first(where: {
            $0.language.caseInsensitiveCompare(targetLanguageIdentifier) == .orderedSame
        }) {
            return exactMatch.identifier
        }

        let targetLanguageCode = Locale.Language(identifier: targetLanguageIdentifier)
            .languageCode?.identifier
        return supportedVoices.first(where: {
            Locale.Language(identifier: $0.language).languageCode?.identifier == targetLanguageCode
        })?.identifier
    }

    /// Voices are listed by region, so Chinese named by its script, as the Translate tab saves it,
    /// asks first for its script's main region: Simplified for mainland China, Traditional for
    /// Taiwan.
    static func voiceLanguage(for identifier: String) -> String {
        switch identifier {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        default: identifier
        }
    }
}

/// Reads a saved translation aloud on this Mac (#362), in an installed voice for its language.
/// `TranslatedSpeechPlayer` does it in the app; unit tests and the UI-test composition use a
/// stand-in, so no test makes a sound. Nothing leaves the Mac.
@MainActor
protocol TranslationSpeaking: AnyObject {
    /// Reads `text` aloud in an installed voice for `language` (a code such as `ja` or `zh-Hant`),
    /// stopping anything it was reading. Returns once reading has started: nil, or why it can't,
    /// such as no installed voice for the language.
    func speak(_ text: String, language: String) async -> String?
    /// Whether it's getting ready to read, or reading.
    var isSpeaking: Bool { get }
    /// Stops at once.
    func stop()
}

/// Reads nothing: under unit tests and in the UI-test composition.
@MainActor
final class InertTranslationSpeaker: TranslationSpeaking {
    func speak(_ text: String, language: String) async -> String? { nil }
    var isSpeaking: Bool { false }
    func stop() {}
}

@MainActor
@Observable
final class TranslatedSpeechPlayer {
    let playback = DictationAudioPlayer()
    private(set) var audioURL: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var isPreparing = false
    private(set) var lastError: String?

    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var generation = 0

    func prepare(text: String, languageIdentifier: String) async {
        clear()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let descriptors = voices.map {
            TranslationSpeechVoiceDescriptor(identifier: $0.identifier, language: $0.language)
        }
        guard let voiceIdentifier = TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
            targetLanguageIdentifier: languageIdentifier,
            supportedVoices: descriptors
        ), let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
            lastError = "No installed voice is available for this language."
            return
        }

        generation += 1
        let currentGeneration = generation
        isPreparing = true
        lastError = nil
        let directory = ProductPaths.keybumps().translatedSpeechTemporary
        let outputURL = directory.appendingPathComponent("\(UUID().uuidString).wav")

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let duration = try await render(utterance, to: outputURL)
            guard generation == currentGeneration else {
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            audioURL = outputURL
            self.duration = duration
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if generation == currentGeneration {
                lastError = "Audio could not be generated for this translation."
            }
        }
        if generation == currentGeneration {
            isPreparing = false
            synthesizer = nil
        }
    }

    func clear() {
        generation += 1
        playback.stop()
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        duration = 0
        isPreparing = false
        lastError = nil
    }

    private func render(_ utterance: AVSpeechUtterance, to outputURL: URL) async throws -> TimeInterval {
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer

        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile?
            var finished = false
            var renderedFrames: AVAudioFramePosition = 0
            var sampleRate: Double = 0

            func finish(_ result: Result<TimeInterval, Error>) {
                guard !finished else { return }
                finished = true
                audioFile = nil
                continuation.resume(with: result)
            }

            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    finish(.failure(NSError(
                        domain: "Keybumps.TranslatedSpeech",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The speech voice returned unsupported audio."]
                    )))
                    return
                }

                let audioByteSize = pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize
                if pcmBuffer.frameLength == 0 || audioByteSize == 0 {
                    guard renderedFrames > 0, sampleRate > 0 else {
                        finish(.failure(CocoaError(.fileReadCorruptFile)))
                        return
                    }
                    finish(.success(Double(renderedFrames) / sampleRate))
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: outputURL,
                            settings: pcmBuffer.format.settings
                        )
                        sampleRate = pcmBuffer.format.sampleRate
                    }
                    try audioFile?.write(from: pcmBuffer)
                    renderedFrames += AVAudioFramePosition(pcmBuffer.frameLength)
                } catch {
                    synthesizer.stopSpeaking(at: .immediate)
                    finish(.failure(error))
                }
            }
        }
    }
}

/// The Translate tab reads a saved translation aloud the way Dictation's Translate plays one: the
/// speech is rendered to a temporary file, then played.
extension TranslatedSpeechPlayer: TranslationSpeaking {
    func speak(_ text: String, language: String) async -> String? {
        await prepare(text: text, languageIdentifier: language)
        // No voice, or stopped meanwhile (`clear()` leaves no file and no error).
        guard let audioURL else { return lastError }
        playback.toggle(id: audioURL.lastPathComponent, audioURL: audioURL)
        return playback.isPlaying ? nil : "This translation couldn’t be played."
    }

    var isSpeaking: Bool { isPreparing || playback.isPlaying }

    func stop() { clear() }
}
