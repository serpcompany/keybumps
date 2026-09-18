import Foundation

struct ProductPaths: Equatable {
    let applicationSupport: URL
    let recordings: URL
    let translatedSpeechTemporary: URL

    static func keybumps(fileManager: FileManager = .default) -> ProductPaths {
        make(productDirectoryName: "Keybumps", fileManager: fileManager)
    }

    private static func make(
        productDirectoryName: String,
        fileManager: FileManager
    ) -> ProductPaths {
        let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let documentsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ProductPaths(
            applicationSupport: applicationSupportRoot.appendingPathComponent(
                productDirectoryName,
                isDirectory: true
            ),
            recordings: documentsRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("recordings", isDirectory: true),
            translatedSpeechTemporary: fileManager.temporaryDirectory
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("TranslatedAudio", isDirectory: true)
        )
    }
}
