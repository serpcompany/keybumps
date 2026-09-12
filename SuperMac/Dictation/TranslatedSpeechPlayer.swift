import AVFoundation
import Foundation
import Observation

struct TranslationSpeechVoiceDescriptor: Equatable {
    let identifier: String
    let language: String
}

enum TranslationSpeechVoiceSelector {
    static func preferredVoiceIdentifier(
        targetLanguageIdentifier: String,
        supportedVoices: [TranslationSpeechVoiceDescriptor]
    ) -> String? {
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
}

@MainActor
@Observable
final class TranslatedSpeechPlayer {
    private(set) var isSpeaking = false
    private(set) var lastError: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var completionTimer: Timer?

    func toggle(text: String, languageIdentifier: String) {
        if isSpeaking {
            stop()
            return
        }

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

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        isSpeaking = true
        lastError = nil
        monitorCompletion()
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        completionTimer?.invalidate()
        completionTimer = nil
        isSpeaking = false
        lastError = nil
    }

    private func monitorCompletion() {
        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.synthesizer.isSpeaking {
                    self.completionTimer?.invalidate()
                    self.completionTimer = nil
                    self.isSpeaking = false
                }
            }
        }
    }
}
