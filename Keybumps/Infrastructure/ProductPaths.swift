import Foundation

struct ProductPaths: Equatable {
    let applicationSupport: URL
    let recordings: URL
    let dictationModels: URL
    let translatedSpeechTemporary: URL

    /// Set once at launch in UI test mode so every store reads and writes a disposable directory.
    nonisolated(unsafe) static var sandboxRoot: URL?

    static func keybumps(fileManager: FileManager = .default) -> ProductPaths {
        make(productDirectoryName: "Keybumps", fileManager: fileManager)
    }

    private static func make(
        productDirectoryName: String,
        fileManager: FileManager
    ) -> ProductPaths {
        let applicationSupportRoot = sandboxRoot?.appendingPathComponent("Application Support", isDirectory: true)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documentsRoot = sandboxRoot?.appendingPathComponent("Documents", isDirectory: true)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let temporaryRoot = sandboxRoot?.appendingPathComponent("tmp", isDirectory: true)
            ?? fileManager.temporaryDirectory
        return ProductPaths(
            applicationSupport: applicationSupportRoot.appendingPathComponent(
                productDirectoryName,
                isDirectory: true
            ),
            recordings: documentsRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("recordings", isDirectory: true),
            dictationModels: applicationSupportRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("DictationModels", isDirectory: true),
            translatedSpeechTemporary: temporaryRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("TranslatedAudio", isDirectory: true)
        )
    }
}
