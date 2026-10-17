import Foundation

enum DictationTranscriptionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case whisperMediumEnglish
    case whisperMediumMultilingual
    case whisperTurboCompressed
    /// Turbo on whisper.cpp, which runs on the GPU (ADR 0008).
    case whisperCppTurbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisperMediumEnglish: "Whisper Medium English"
        case .whisperMediumMultilingual: "Whisper Medium Multilingual"
        case .whisperTurboCompressed: "Whisper Large v3 Turbo"
        case .whisperCppTurbo: "Whisper Large v3 Turbo (Fast)"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech: "Built in · No model download"
        case .whisperMediumEnglish: "English only · About 1.5 GB"
        case .whisperMediumMultilingual: "English and Japanese · About 1.5 GB"
        case .whisperTurboCompressed: "English and Japanese · About 627 MB"
        case .whisperCppTurbo: "English and Japanese · About 574 MB"
        }
    }

    var modelIdentifier: String? {
        switch self {
        case .appleSpeech: nil
        case .whisperMediumEnglish: "medium.en"
        case .whisperMediumMultilingual: "medium"
        case .whisperTurboCompressed: "large-v3-v20240930_626MB"
        case .whisperCppTurbo: WhisperCppModel.turbo.identifier
        }
    }

    /// The model files an installed model's folder must contain.
    var requiredModelFiles: [String] {
        switch self {
        case .appleSpeech: []
        case .whisperCppTurbo: [WhisperCppModel.turbo.fileName]
        case .whisperMediumEnglish, .whisperMediumMultilingual, .whisperTurboCompressed:
            ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        }
    }

    var requiresDownload: Bool { modelIdentifier != nil }

    /// The model Settings marks Recommended: the fastest, and as accurate as any (ADR 0008).
    var isRecommended: Bool { self == .whisperCppTurbo }

    /// Whether the model detects the spoken language, so Automatic is detected per recording
    /// (#530). Apple Speech needs one language, and Medium English knows only English.
    var detectsLanguage: Bool {
        switch self {
        case .appleSpeech, .whisperMediumEnglish: false
        case .whisperMediumMultilingual, .whisperTurboCompressed, .whisperCppTurbo: true
        }
    }

    /// Every model takes Automatic: one that can't detect falls back (`DictationLanguage.resolved`).
    func supports(language identifier: String) -> Bool {
        guard self == .whisperMediumEnglish else { return true }
        return DictationLanguage.isAutomatic(identifier) || identifier.lowercased().hasPrefix("en")
    }
}

