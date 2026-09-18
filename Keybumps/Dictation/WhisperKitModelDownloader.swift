import ArgmaxCore
import Foundation
import WhisperKit

enum PublicModelDownloadPolicy {
    // Argmax treats nil as "discover credentials from the environment and disk".
    // These are public repositories, so explicitly disable ambient credentials.
    static let anonymousToken = ""
}

struct WhisperKitModelDownloader: DictationModelDownloading {
    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let folder = try await WhisperKit.download(
            variant: identifier,
            downloadBase: downloadBase,
            token: PublicModelDownloadPolicy.anonymousToken,
            progressCallback: { update in
                progress(update.fractionCompleted * 0.96)
            }
        )
        let tokenizerClient = HubApiWrapper(
            downloadBase: folder,
            hfToken: PublicModelDownloadPolicy.anonymousToken,
            endpoint: "https://huggingface.co"
        )
        _ = try await tokenizerClient.snapshot(
            from: .init(id: tokenizerRepository(for: identifier)),
            matching: [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "added_tokens.json",
                "normalizer.json",
                "vocab.json",
                "merges.txt"
            ],
            progressHandler: { update in
                progress(0.96 + update.fractionCompleted * 0.03)
            }
        )
        let whisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: folder,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        ))
        await whisper.unloadModels()
        progress(1)
        return folder
    }

    private func tokenizerRepository(for identifier: String) -> String {
        switch identifier {
        case "medium.en": "openai/whisper-medium.en"
        case "medium": "openai/whisper-medium"
        default: "openai/whisper-large-v3"
        }
    }
}
