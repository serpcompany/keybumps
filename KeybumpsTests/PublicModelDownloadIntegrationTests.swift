import ArgmaxCore
import WhisperKit
import XCTest
@testable import Keybumps

final class PublicModelDownloadIntegrationTests: XCTestCase {
    private func requireNetworkTests() throws {
        guard ProcessInfo.processInfo.environment["KEYBUMPS_RUN_MODEL_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set KEYBUMPS_RUN_MODEL_NETWORK_TESTS=1 to exercise public model downloads.")
        }
    }

    func testPublicTurboModelAllowsAnonymousDownload() async throws {
        try requireNetworkTests()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPublicModelIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let download = Task {
            try await WhisperKit.download(
                variant: "large-v3-v20240930_626MB",
                downloadBase: root,
                token: PublicModelDownloadPolicy.anonymousToken
            )
        }
        try await Task.sleep(for: .seconds(2))
        download.cancel()

        do {
            _ = try await download.value
        } catch {
            XCTAssertFalse(
                error.localizedDescription.contains("Authentication required"),
                "Public downloads must not inherit stale Hugging Face credentials."
            )
        }
    }

    func testPublicTokenizerAllowsAnonymousDownload() async throws {
        try requireNetworkTests()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPublicTokenizerIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = HubApiWrapper(
            downloadBase: root,
            hfToken: PublicModelDownloadPolicy.anonymousToken,
            endpoint: "https://huggingface.co"
        )

        let snapshot = try await client.snapshot(
            from: .init(id: "openai/whisper-large-v3"),
            matching: ["config.json", "tokenizer.json", "tokenizer_config.json"]
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: snapshot.appendingPathComponent("tokenizer.json").path
        ))
    }
}
