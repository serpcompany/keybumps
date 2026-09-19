import Foundation

enum DictationTranscriptionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech
    case whisperMediumEnglish
    case whisperMediumMultilingual
    case whisperTurboCompressed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisperMediumEnglish: "Whisper Medium English"
        case .whisperMediumMultilingual: "Whisper Medium Multilingual"
        case .whisperTurboCompressed: "Whisper Large v3 Turbo"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech: "Built in · No model download"
        case .whisperMediumEnglish: "English only · About 1.5 GB"
        case .whisperMediumMultilingual: "English and Japanese · About 1.5 GB"
        case .whisperTurboCompressed: "English and Japanese · About 627 MB"
        }
    }

    var modelIdentifier: String? {
        switch self {
        case .appleSpeech: nil
        case .whisperMediumEnglish: "medium.en"
        case .whisperMediumMultilingual: "medium"
        case .whisperTurboCompressed: "large-v3-v20240930_626MB"
        }
    }

    var requiresDownload: Bool { modelIdentifier != nil }

    func supports(language identifier: String) -> Bool {
        guard self == .whisperMediumEnglish else { return true }
        return identifier.lowercased().hasPrefix("en")
    }
}

