import Foundation

struct ProductPaths: Equatable {
    let applicationSupport: URL
    let recordings: URL
    let dictationModels: URL
    let translatedSpeechTemporary: URL

    /// Set once at launch in UI test mode so every store reads and writes a disposable directory.
    nonisolated(unsafe) static var sandboxRoot: URL?

    /// Keybumps's folders. In UI test mode they're in `sandboxRoot`. Under the unit-test host, the
    /// owner's real folders become folders in `UnitTestHost.dataDirectory`, this run's own
    /// temporary root, so a default Dictation History, Clipboard History, Shortcut Coach history,
    /// model folder, or translated audio never reaches the installed app's data.
    static func keybumps(fileManager: FileManager = .default) -> ProductPaths {
        make(
            productDirectoryName: "Keybumps",
            fileManager: fileManager,
            sandboxRoot: sandboxRoot,
            unitTestRoot: UnitTestHost.isActive ? UnitTestHost.dataDirectory : nil
        )
    }

    /// Resolves each root folder: the sandbox's when there is one; otherwise the file manager's,
    /// except that with a `unitTestRoot` a folder that is the user's real one (as
    /// `FileManager.default` resolves it) moves into `unitTestRoot`. A test's own rooted file
    /// manager already points elsewhere, so it's kept.
    static func make(
        productDirectoryName: String,
        fileManager: FileManager,
        sandboxRoot: URL?,
        unitTestRoot: URL?
    ) -> ProductPaths {
        func root(_ name: String, _ resolve: (FileManager) -> URL) -> URL {
            if let sandboxRoot {
                return sandboxRoot.appendingPathComponent(name, isDirectory: true)
            }
            let folder = resolve(fileManager)
            guard let unitTestRoot,
                  folder.standardizedFileURL == resolve(.default).standardizedFileURL
            else { return folder }
            return unitTestRoot.appendingPathComponent(name, isDirectory: true)
        }
        let applicationSupportRoot = root("Application Support") {
            $0.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        let documentsRoot = root("Documents") { $0.urls(for: .documentDirectory, in: .userDomainMask)[0] }
        let temporaryRoot = root("tmp") { $0.temporaryDirectory }
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
