import Foundation

/// Where Keybumps keeps its files (ADR 0013). Every plugin that saves files keeps them in its own
/// folder in the Keybumps folder, `~/Library/Application Support/Keybumps`, which never syncs.
struct ProductPaths: Equatable {
    /// The Keybumps folder, `~/Library/Application Support/Keybumps`: a folder for each plugin that
    /// saves files, and nothing else at its top level.
    let keybumpsFolder: URL
    /// `~/Documents/Keybumps`, where Dictation History (`recordings/`) and ScreenGrabs' recordings
    /// before #504 (`captures/`) were kept until #602. Nothing writes there now: the one-time move
    /// (`KeybumpsFolderMove`) empties it, and removes it once it's empty.
    let oldDocumentsFolder: URL
    let translatedSpeechTemporary: URL
    /// Keybumps's caches, such as recordings' poster frames: `~/Library/Caches/Keybumps`.
    let caches: URL
    /// What this launch's one-time move left in its old place, where its store reads it
    /// (`inUse(_:)`). Empty under the unit-test host and in UI test mode.
    var leftInOldPlace: Set<KeybumpsFolderItem> = []

    /// Dictation's folder: `recordings/`, `models/`, and `last-dictation.txt`.
    var dictation: URL { folder("dictation") }
    /// Dictation History, one folder per dictation.
    var dictationRecordings: URL { dictation.appendingPathComponent("recordings", isDirectory: true) }
    /// Dictation's downloaded models, a folder per engine (`DictationModelManager`).
    var dictationModels: URL { dictation.appendingPathComponent("models", isDirectory: true) }
    /// `clipboard-history.json`, and each image's copy in `media/`.
    var clipboardHistory: URL { folder("clipboard_history") }
    /// Emoji Picker's recent emoji, `emoji-recent.json`.
    var emojiPicker: URL { folder("emoji_picker") }
    /// Quick Search's Recent Items and learned usage, `recent-items.json` and `application-usage.json`.
    var quickSearch: URL { folder("quick_search") }
    /// The Timers tab's countdowns, `timers.json`.
    var timers: URL { folder("timers") }
    var translations: URL { folder("translations") }
    var snippets: URL { folder("snippets") }
    /// Shortcut Coach's history, `coaching-events.json`.
    var shortcutCoach: URL { folder("shortcut_coach") }
    /// ScreenGrabs' recordings index and repository memory, and `recordings/` and `screenshots/`.
    var screengrabs: URL { folder("screengrabs") }
    /// ScreenGrabs' history of recordings, each in its own `<timestamp>/` folder (ADR 0009, ADR 0013):
    /// every recording is saved here (#605), and the recordings index points here.
    var screengrabsRecordings: URL { screengrabs.appendingPathComponent("recordings", isDirectory: true) }
    /// ScreenGrabs' history of screenshots (#605): every screenshot's file, which its Clipboard
    /// History item names. The hotkeys save here, and one macOS saves is copied here.
    var screengrabsScreenshots: URL { screengrabs.appendingPathComponent("screenshots", isDirectory: true) }

    private func folder(_ name: String) -> URL {
        keybumpsFolder.appendingPathComponent(name, isDirectory: true)
    }

    /// Set once at launch in UI test mode so every store reads and writes a disposable directory.
    nonisolated(unsafe) static var sandboxRoot: URL?

    /// Keybumps's folders. In UI test mode they're in `sandboxRoot`. Under the unit-test host, the
    /// owner's real folders become folders in `UnitTestHost.dataDirectory`, this run's own
    /// temporary root, so a default Dictation History, Clipboard History, Shortcut Coach history,
    /// model folder, translated audio, recording, or the old Documents folder never reaches the
    /// installed app's data.
    static func keybumps(fileManager: FileManager = .default) -> ProductPaths {
        var paths = make(
            productDirectoryName: "Keybumps",
            fileManager: fileManager,
            sandboxRoot: sandboxRoot,
            unitTestRoot: UnitTestHost.isActive ? UnitTestHost.dataDirectory : nil
        )
        paths.leftInOldPlace = KeybumpsFolderMove.leftInOldPlace
        return paths
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
        let cachesRoot = root("Caches") { $0.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
        let keybumpsFolder = applicationSupportRoot.appendingPathComponent(productDirectoryName, isDirectory: true)
        return ProductPaths(
            keybumpsFolder: keybumpsFolder,
            oldDocumentsFolder: documentsRoot.appendingPathComponent(productDirectoryName, isDirectory: true),
            translatedSpeechTemporary: temporaryRoot
                .appendingPathComponent(productDirectoryName, isDirectory: true)
                .appendingPathComponent("TranslatedAudio", isDirectory: true),
            caches: cachesRoot.appendingPathComponent(productDirectoryName, isDirectory: true)
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
