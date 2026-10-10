import Foundation

struct ProductPaths: Equatable {
    let applicationSupport: URL
    let recordings: URL
    /// Screencast's captures, each in its own `<timestamp>/` folder (ADR 0009).
    let captures: URL
    let dictationModels: URL
    let translatedSpeechTemporary: URL

    /// Set once at launch in UI test mode so every store reads and writes a disposable directory.
    nonisolated(unsafe) static var sandboxRoot: URL?

    /// Keybumps's folders. In UI test mode they're in `sandboxRoot`. Under the unit-test host, the
    /// owner's real folders become folders in `UnitTestHost.dataDirectory`, this run's own
    /// temporary root, so a default Dictation History, Clipboard History, Shortcut Coach history,
    /// model folder, translated audio, or Screencast capture never reaches the installed app's data.
    static func keybumps(fileManager: FileManager = .default) -> ProductPaths {
        make(
            productDirectoryName: "Keybumps",
            fileManager: fileManager,
            sandboxRoot: sandboxRoot,
            unitTestRoot: UnitTestHost.isActive ? UnitTestHost.dataDirectory : nil
        )
    }

    /// Resolves each root folder: the sandbox's when there is one; otherwise the file manager's.
    /// With a `unitTestRoot`, a folder that is the user's real one (as `userFolders` resolves it) or
    /// inside it moves to the same place in `unitTestRoot`, however it's spelled (a trailing slash,
    /// `/var` or `/private/var`, a symlink). So a test's own rooted file manager keeps only the
    /// folders it overrides with ones elsewhere. Production passes no `unitTestRoot` and touches
    /// nothing here.
    static func make(
        productDirectoryName: String,
        fileManager: FileManager,
        sandboxRoot: URL?,
        unitTestRoot: URL?,
        userFolders: FileManager = .default
    ) -> ProductPaths {
        func root(_ name: String, _ resolve: (FileManager) -> URL) -> URL {
            if let sandboxRoot {
                return sandboxRoot.appendingPathComponent(name, isDirectory: true)
            }
            let folder = resolve(fileManager)
            guard let unitTestRoot else { return folder }
            let path = canonicalPath(folder)
            let userPath = canonicalPath(resolve(userFolders))
            guard path == userPath || path.hasPrefix(userPath + "/") else { return folder }
            return path.dropFirst(userPath.count).split(separator: "/").reduce(
                unitTestRoot.appendingPathComponent(name, isDirectory: true)
            ) { $0.appendingPathComponent(String($1), isDirectory: true) }
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
            captures: documentsRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("captures", isDirectory: true),
            dictationModels: applicationSupportRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("DictationModels", isDirectory: true),
            translatedSpeechTemporary: temporaryRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("TranslatedAudio", isDirectory: true)
        )
    }

    /// A folder's path with `..` removed, no trailing slash, and symlinks resolved, spelled the same
    /// for `/var/…` and `/private/var/…` even when the folder doesn't exist yet: the nearest folder
    /// that exists is resolved, and the rest is appended. It checks only whether folders exist and
    /// follows links; it never lists or opens one.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", (try? existing.checkResourceIsReachable()) != true {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let resolved = missing.reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return resolved.path
    }
}
