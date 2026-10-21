import Darwin
import Foundation

/// How ScreenGrabs copies its files (#605, ADR 0013): a screenshot into its history,
/// `screengrabs/screenshots/` in the Keybumps folder, and each screenshot and recording to where macOS
/// saves screenshots (`ScreengrabCopies`). A copy never replaces anything: it takes the first free
/// name, so a name already there, the person's or an earlier screengrab's, is left as it is.
enum ScreengrabFiles {
    enum Result: Equatable {
        /// Copied to this URL.
        case copied(URL)
        /// Something is already at the name.
        case exists
        /// The copy failed, with the error code.
        case failed(Int)
    }

    /// Copies `source`, a file or a folder, to `destination`, which must not exist yet: an APFS clone
    /// (`clonefile`), which shares the original's storage on the same volume, so it takes no more
    /// space; else, such as to another volume, a plain copy written beside it under a hidden name
    /// (`KeybumpsFolderMove.partialCopy(of:)`), checked against the original, and renamed into place
    /// without replacing anything (`KeybumpsFolderMove.renameExclusively`). So a name never shows a
    /// half-written copy.
    static func copy(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager = .default,
        clone: (URL, URL) -> Int32 = cloneExclusively
    ) -> Result {
        let code = clone(source, destination)
        // A clone shares the original's storage, so it isn't read back; only a plain copy is checked.
        if code == 0 { return .copied(destination) }
        if code == EEXIST { return .exists }
        if code == ENOENT, !exists(source) { return .failed(Int(code)) }
        let partial = KeybumpsFolderMove.partialCopy(of: destination)
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.copyItem(at: source, to: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            return .failed((error as NSError).code)
        }
        guard fileManager.contentsEqual(atPath: source.path, andPath: partial.path) else {
            try? fileManager.removeItem(at: partial)
            return .failed(Int(EIO))
        }
        let placed = KeybumpsFolderMove.renameExclusively(partial, to: destination)
        guard placed == 0 else {
            try? fileManager.removeItem(at: partial)
            return placed == EEXIST ? .exists : .failed(Int(placed))
        }
        return .copied(destination)
    }

    /// Copies `source` into `folder` under the first free name `name(n)` gives, from 1 (`copy`). Makes
    /// the folder first. With `reusingIdentical`, a name already holding the same contents is the
    /// copy, and nothing is written. Nil when it can't.
    static func copy(
        _ source: URL,
        into folder: URL,
        naming name: (Int) -> String,
        reusingIdentical: Bool = false,
        fileManager: FileManager = .default,
        clone: (URL, URL) -> Int32 = cloneExclusively
    ) -> URL? {
        guard (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        for attempt in 1...maximumAttempts {
            let destination = folder.appendingPathComponent(name(attempt))
            switch copy(source, to: destination, fileManager: fileManager, clone: clone) {
            case .copied(let url): return url
            case .exists:
                if reusingIdentical, fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
                    return destination
                }
            case .failed: return nil
            }
        }
        return nil
    }

    /// How many names `copy(_:into:naming:)` tries before it gives up.
    static let maximumAttempts = 1_000

    /// A file's names, as Finder names a copy: `Screenshot 2026-10-21 at 10.00.00.png`, then
    /// `Screenshot 2026-10-21 at 10.00.00 2.png`, …
    static func fileNames(like file: URL) -> (Int) -> String {
        let base = file.deletingPathExtension().lastPathComponent
        let suffix = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
        return { $0 == 1 ? "\(base)\(suffix)" : "\(base) \($0)\(suffix)" }
    }

    /// A recording folder's names, as the recorder names them (`ScreencastCaptureFolder`): `1790000000`,
    /// then `1790000000-2`, …, so the recordings index still finds it.
    static func recordingFolderNames(like folder: URL) -> (Int) -> String {
        let name = folder.lastPathComponent
        let seconds = ScreencastCaptureFolder.isFolderName(name) ? String(name.split(separator: "-")[0]) : name
        return { $0 == 1 ? name : "\(seconds)-\($0)" }
    }

    /// Whether `url` is directly in `folder`, however either is spelled (`ProductPaths.canonicalPath`).
    static func isDirectly(_ url: URL, in folder: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path == folder.standardizedFileURL.path { return true }
        return ProductPaths.canonicalPath(parent) == ProductPaths.canonicalPath(folder)
    }

    /// Removes the partial copies Keybumps left directly in `folder` when it quit mid-copy:
    /// `.<name>.keybumps-moving` (`KeybumpsFolderMove.partialCopy(of:)`), and nothing else, so no
    /// file of the person's is touched. Returns how many it removed.
    @discardableResult
    static func removePartialCopies(in folder: URL, fileManager: FileManager = .default) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.filter(isPartialCopyName).reduce(0) { removed, name in
            (try? fileManager.removeItem(at: folder.appendingPathComponent(name))) == nil ? removed : removed + 1
        }
    }

    /// Whether `name` is a partial copy's, `.<name>.keybumps-moving`, with a name of at least one character.
    static func isPartialCopyName(_ name: String) -> Bool {
        let prefix = ".", suffix = ".keybumps-moving"
        return name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count > prefix.count + suffix.count
    }

    /// `clonefile`, which never replaces what's at `destination`: 0, or the error code.
    static func cloneExclusively(_ source: URL, _ destination: URL) -> Int32 {
        clonefile(source.path, destination.path, 0) == 0 ? 0 : errno
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

/// Where each screengrab's own copy goes, apart from its history (#605): where macOS saves
/// screenshots, `com.apple.screencapture` `location`, else the Desktop (`ScreenshotLocationResolver`),
/// read as each one is copied. It's the person's: deleting or moving it, such as by clearing the
/// Desktop, never touches the history, and nothing Keybumps keeps points to it. A screenshot's file
/// keeps its name; a recording's folder (`<timestamp>/`) is copied whole, as it was saved there
/// before #605. A partial copy Keybumps left there when it quit mid-copy is removed just before the
/// next copy, not at launch, so the launch's moves never read that folder, and a Mac that doesn't
/// use ScreenGrabs is never asked for it (#611).
struct ScreengrabCopies {
    var folder: () -> URL
    var fileManager: FileManager = .default

    /// Copies `screengrab`, a screenshot's file or a recording's folder, there (`ScreengrabFiles`).
    /// Nil when it's in that folder already (macOS saving screenshots in the history folder) or
    /// can't be copied. Main actor only, so no other copy is under way during the sweep below.
    @MainActor
    func put(_ screengrab: URL) -> URL? {
        let folder = folder()
        guard !ScreengrabFiles.isDirectly(screengrab, in: folder) else { return nil }
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: screengrab.path, isDirectory: &isFolder) else { return nil }
        let names = isFolder.boolValue ? ScreengrabFiles.recordingFolderNames(like: screengrab) : ScreengrabFiles.fileNames(like: screengrab)
        // Every copy is made on the main actor, start to finish, so none is under way here now.
        ScreengrabFiles.removePartialCopies(in: folder, fileManager: fileManager)
        return ScreengrabFiles.copy(screengrab, into: folder, naming: names, fileManager: fileManager)
    }
}
