import Foundation
import NaturalLanguage

/// The two languages translation goes between (#322): text in mine goes to the other, and text in
/// any other language comes back to mine, as in Easydict and Pot. Languages are codes such as `en`.
struct TranslationLanguagePair: Equatable {
    let mine: String
    let other: String

    init(mine: String, other: String) {
        self.mine = Self.code(mine)
        self.other = Self.code(other)
    }

    /// What Dictation's Translate has always done: English text to Japanese, anything else to
    /// English. The Translation plugin's setting replaces it when that plugin is on.
    static let dictationDefault = TranslationLanguagePair(mine: "en", other: "ja")

    /// The Mac's first preferred language, with English, or with Japanese when that's English.
    static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguagePair {
        let mine = code(preferredLanguages.first ?? "en")
        return TranslationLanguagePair(mine: mine, other: mine == "en" ? "ja" : "en")
    }

    /// The language to translate text in `sourceIdentifier` into.
    func target(forSourceIdentifier sourceIdentifier: String) -> String {
        Self.code(sourceIdentifier) == mine ? other : mine
    }

    private static func code(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }
}

enum TranslationLanguagePolicy {
    static func canTranslate(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How sure `NLLanguageRecognizer` must be before its guess replaces the recorded language.
    /// Short words that several languages share score below it ("OK", "Hola", "Bonjour", and "Ciao"
    /// score 0.3 to 0.7), while a sentence, or a Chinese or Japanese word of two characters, scores
    /// 0.8 or more.
    static let sourceDetectionConfidence = 0.8
    /// The fewest characters worth a guess: one says too little. It stays low because two Japanese
    /// characters are already a certain guess; the confidence screens out the rest.
    static let sourceDetectionMinimumLength = 2

    /// The language to translate from: the one the text is written in. The fallback is the language
    /// the text was expected in, such as a recording's Dictation language, which is the setting it
    /// was recorded with, not what was spoken (#321). Keeps the fallback when the text is in it (so
    /// its region stays, as in `pt-BR`), or when the guess is unsure.
    static func sourceLanguageIdentifier(for text: String, fallbackLanguageIdentifier: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= sourceDetectionMinimumLength else { return fallbackLanguageIdentifier }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let guess = recognizer.languageHypotheses(withMaximum: 1).first
        return sourceLanguageIdentifier(
            guess: guess?.key,
            confidence: guess?.value ?? 0,
            fallbackLanguageIdentifier: fallbackLanguageIdentifier
        )
    }

    /// The recognizer's top guess, unless it's missing, undetermined, below
    /// `sourceDetectionConfidence`, or the fallback language in the same script; then the fallback.
    static func sourceLanguageIdentifier(
        guess: NLLanguage?,
        confidence: Double,
        fallbackLanguageIdentifier: String
    ) -> String {
        guard let guess, guess != .undetermined,
              confidence >= sourceDetectionConfidence else { return fallbackLanguageIdentifier }
        let detected = Locale.Language(identifier: guess.rawValue)
        let recorded = Locale.Language(identifier: fallbackLanguageIdentifier)
        let sameLanguage = detected.languageCode == recorded.languageCode
            && Locale.Language(identifier: detected.maximalIdentifier).script
                == Locale.Language(identifier: recorded.maximalIdentifier).script
        return sameLanguage ? fallbackLanguageIdentifier : guess.rawValue
    }

    /// The languages Translate offers: every supported one but the source's.
    static func targets(from supported: [Locale.Language], sourceIdentifier: String) -> [Locale.Language] {
        let source = Locale.Language(identifier: sourceIdentifier)
        return supported.filter { !$0.isEquivalent(to: source) }
    }

    /// Where Translate starts, and the targets it offers from there: the text's language, or the
    /// fallback language when Translation offers nothing from the text's. Translation knows fewer
    /// languages than the recognizer (not Swedish, Danish, or Greek, for example). Nil when neither
    /// offers a target.
    @MainActor
    static func translatableSource(
        for text: String,
        fallbackLanguageIdentifier: String,
        targets: (String) async -> [Locale.Language]
    ) async -> (source: String, targets: [Locale.Language])? {
        let detected = sourceLanguageIdentifier(for: text, fallbackLanguageIdentifier: fallbackLanguageIdentifier)
        let candidates = detected == fallbackLanguageIdentifier ? [detected] : [detected, fallbackLanguageIdentifier]
        for source in candidates {
            let offered = await targets(source)
            if !offered.isEmpty { return (source, offered) }
        }
        return nil
    }

    /// The pair's other language for text in mine, and mine for text in any other language (#322);
    /// the first language offered when Translation has neither.
    static func preferredTargetIdentifier(
        sourceIdentifier: String,
        supportedIdentifiers: [String],
        pair: TranslationLanguagePair
    ) -> String? {
        let preferred = pair.target(forSourceIdentifier: sourceIdentifier)
        return supportedIdentifiers.first(where: {
            Locale.Language(identifier: $0).languageCode?.identifier == preferred
        }) ?? supportedIdentifiers.first
    }
}
