import Foundation

/// ScreenGrabs' two save folders (#504, ADR 0010 decision 5): the Screenshots folder, where the
/// screenshot hotkeys and the Screenshot Editor save, and the Recordings folder, where each recording
/// gets a folder of its own. Each is the folder chosen for it in Settings › ScreenGrabs while Keybumps
/// can save there, and otherwise the default: the folder macOS saves screenshots to
/// (`ScreenshotLocationResolver`: `com.apple.screencapture` `location`, else the Desktop), read each
/// time, so a kind with no choice follows macOS's setting. A chosen folder that's gone or can't be
/// written to stays chosen, and is used again once it's back; meanwhile its kind saves to the default.
/// Keybumps isn't sandboxed, so a choice is stored as its path (`AppPreferences.chosenScreengrabFolders`),
/// with no bookmark. Nothing here writes a file or a preference.
struct ScreengrabFolders {
    enum Kind: String, CaseIterable, Sendable {
        case screenshots, recordings
    }

    /// macOS's screenshot folder, each kind's default.
    var location: ScreenshotLocationResolver
    /// The folders chosen in Settings › ScreenGrabs, by kind.
    var chosen: [Kind: URL]
    /// Whether Keybumps can save in a folder: it's there, it's a folder, and it can be written to.
    var canSave: (URL) -> Bool = Self.canSaveOnDisk

    /// Where `kind` saves now.
    func folder(for kind: Kind) -> URL {
        usableChoice(for: kind) ?? defaultFolder
    }

    /// Each kind's default, the folder macOS saves screenshots to, read now.
    var defaultFolder: URL { location.resolve() }

    /// Where `kind` saves if its folder turns out not to take a file after all: the default, while a
    /// chosen folder is in use. Nil while it already saves to the default.
    func fallback(for kind: Kind) -> URL? {
        guard let choice = usableChoice(for: kind) else { return nil }
        let fallback = defaultFolder
        return fallback.standardizedFileURL == choice.standardizedFileURL ? nil : fallback
    }

    /// Whether `kind` has a chosen folder Keybumps can't save in now, so it saves to the default.
    func choiceIsUnavailable(for kind: Kind) -> Bool {
        chosen[kind] != nil && usableChoice(for: kind) == nil
    }

    private func usableChoice(for kind: Kind) -> URL? {
        chosen[kind].flatMap { canSave($0) ? $0 : nil }
    }

    static func canSaveOnDisk(_ folder: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }
}
