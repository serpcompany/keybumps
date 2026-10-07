import AVFoundation

/// Reads text aloud on this Mac (#362): a macOS voice through `AVSpeechSynthesizer` in the app
/// (`SystemTextSpeaker`), and a stand-in under unit and UI tests (`InertTextSpeaker`), so no test
/// makes a sound. Nothing leaves the Mac.
@MainActor
protocol TextSpeaking: AnyObject {
    /// Reads `text` in a voice for `language` (an identifier such as `ja` or `zh-Hant`), stopping
    /// anything it was reading. `finished` runs once, when it's done or stopped.
    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void)
    /// Stops reading at once.
    func stop()
}

/// Reads nothing: under unit tests and in the UI-test composition, each reading ends at once.
@MainActor
final class InertTextSpeaker: TextSpeaking {
    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) {
        finished()
    }

    func stop() {}
}

enum TextSpeakerFactory {
    /// A macOS voice, or the inert speaker under the unit-test host.
    @MainActor
    static func makeDefault() -> any TextSpeaking {
        UnitTestHost.isActive ? InertTextSpeaker() : SystemTextSpeaker()
    }
}

enum TextSpeakerVoices {
    /// The language to ask for a voice in. Voices are listed by region, so Chinese goes by its
    /// script's main one: Simplified to `zh-CN`, Traditional to `zh-TW`.
    static func voiceLanguage(for identifier: String) -> String {
        switch TranslationLanguagePair.code(identifier) {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        default: identifier
        }
    }

    /// A voice for `identifier`: the system's for that language, or else an installed one in the
    /// same language. Nil leaves the utterance to the system's default voice.
    static func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
        let language = voiceLanguage(for: identifier)
        if let voice = AVSpeechSynthesisVoice(language: language) { return voice }
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            TranslationSpeechVoiceDescriptor(identifier: $0.identifier, language: $0.language)
        }
        return TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
            targetLanguageIdentifier: language,
            supportedVoices: installed
        ).flatMap(AVSpeechSynthesisVoice.init(identifier:))
    }
}

/// Reads aloud with `AVSpeechSynthesizer` through the Mac's speakers, one text at a time.
@MainActor
final class SystemTextSpeaker: NSObject, TextSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being read and what runs when it ends.
    private var current: (utterance: AVSpeechUtterance, finished: @MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = TextSpeakerVoices.voice(for: language)
        current = (utterance, finished)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard let current else { return }
        self.current = nil
        synthesizer.stopSpeaking(at: .immediate)
        current.finished()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didEnd(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didEnd(utterance) }
    }

    /// An utterance ended by itself; one already replaced or stopped is ignored.
    private func didEnd(_ utterance: AVSpeechUtterance) {
        guard let current, current.utterance === utterance else { return }
        self.current = nil
        current.finished()
    }
}
