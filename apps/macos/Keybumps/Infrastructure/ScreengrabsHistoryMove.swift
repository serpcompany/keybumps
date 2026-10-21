import Darwin
import Foundation
import OSLog

/// Brings every screengrab kept before #605 into ScreenGrabs' history in the Keybumps folder,
/// `screengrabs/screenshots/` and `screengrabs/recordings/`, so none disappears from the ScreenGrabs
/// tab now that it lists only the history. It runs at launch, after `KeybumpsFolderMove` and before
/// any store loads, by ADR 0013's rules:
/// - **Screenshots** (each launch): a Clipboard History screenshot item whose file isn't in the
///   history gets a copy there, from its copy in `clipboard_history/media/`, or from its own file
///   when that copy is gone. The copy keeps the screenshot's own name (`ScreengrabFiles.fileNames`),
///   and the item then names it. Its copy in `media/` is removed once the item names the new file;
///   its own file, such as one macOS saved on the Desktop, is the person's and stays.
/// - **Recordings** (each launch): a recording the index lists outside the history, such as one
///   saved on the Desktop from #504 until #605, gets a copy of its folder there
///   (`ScreengrabFiles.recordingFolderNames`), and the index then names it. The folder it was in
///   stays, as the person's copy.
/// - **Recordings the index lacks** (once, `doneKey`): a recording in a folder ScreenGrabs
///   recorded into (`RecordingFolderMemory`), such as one kept while Keybumps locked, gets a copy in
///   the history, where the recordings index finds it (`RecordingLibrary.launchCheck`).
/// - **How it copies:** an APFS clone, else a copy checked against the original, put in place
///   without replacing anything (`ScreengrabFiles.copy`). A name already in the history with the
///   same contents is that copy, as after a launch cut short; a different one is left as it is, and
///   the next free name is used.
/// - **A failure** leaves the item as it was, read where it was, and is tried again at the next
///   launch. A store's file is written once, after its copies are in place; a file that can't be
///   read, or a later build's index, is left as it is.
/// - **Not after a failed move:** while a failed `KeybumpsFolderMove` left the recordings or the
///   index in their old place, recordings wait for a launch that finds them in the Keybumps folder.
///   One it holds there for a folder chosen before #605 doesn't wait: nothing is saved there now,
///   and the copy leaves the folder as it is.
/// - **Partial copies** Keybumps left when it quit mid-copy (`.<name>.keybumps-moving`) are removed
///   first, each launch, in the history's two folders (`ScreengrabFiles.removePartialCopies`).
///   Nothing else there is touched. The launch's moves never read where convenience copies go: a
///   partial copy there is removed just before the next copy (`ScreengrabCopies.put`), so a Mac
///   that never used ScreenGrabs isn't asked for its Desktop (#611).
/// - **Logs** say only counts, the stage, an error code, and how long it took: never a path, a
///   name, or content.
struct ScreengrabsHistoryMove {
    struct Report: Equatable {
        /// Screenshot items that now name a file in the history.
        var screenshots = 0
        /// Recordings copied into the history, listed or not.
        var recordings = 0
        /// Index entries dropped because another already names the same recording in the history.
        var duplicates = 0
        /// Partial copies removed (`ScreengrabFiles.removePartialCopies`).
        var partials = 0
        var failures = 0
    }

    /// When the recordings the index lacked were brought into the history.
    static let doneKey = "screengrabs.historyMoved"

    /// The Keybumps folder's paths, with what `KeybumpsFolderMove` left in its old place.
    let paths: ProductPaths
    var fileManager: FileManager = .default
    var defaults: UserDefaults = .standard
    /// `ScreengrabFiles.cloneExclusively`. Tests make it fail with `ENOTSUP` so the checked copy runs.
    var clone: (URL, URL) -> Int32 = ScreengrabFiles.cloneExclusively
    private let logger = Logger(subsystem: "com.serp.keybumps", category: "screengrabs-history")

    init(paths: ProductPaths, fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.fileManager = fileManager
        self.defaults = defaults
    }

    /// The app's launch, after `KeybumpsFolderMove.runAtLaunch()`. Never under the unit-test host or
    /// in UI test mode, whose folders start empty.
    static func runAtLaunch() {
        guard !UnitTestHost.isActive, ProductPaths.sandboxRoot == nil else { return }
        ScreengrabsHistoryMove(paths: .keybumps()).run()
    }

    @discardableResult
    func run() -> Report {
        let started = ContinuousClock.now
        var report = Report()
        for folder in [paths.screengrabsScreenshots, paths.screengrabsRecordings] {
            report.partials += ScreengrabFiles.removePartialCopies(in: folder, fileManager: fileManager)
        }
        moveScreenshots(&report)
        if !recordingsWait {
            let indexed = moveIndexedRecordings(&report)
            if defaults.object(forKey: Self.doneKey) == nil {
                let failuresBefore = report.failures
                moveUnindexedRecordings(skipping: indexed, &report)
                if report.failures == failuresBefore { defaults.set(Date(), forKey: Self.doneKey) }
            }
        }
        let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
        if report != Report() {
            logger.info("screengrabs history move screenshots=\(report.screenshots, privacy: .public) recordings=\(report.recordings, privacy: .public) duplicates=\(report.duplicates, privacy: .public) partials=\(report.partials, privacy: .public) failures=\(report.failures, privacy: .public) ms=\(milliseconds, privacy: .public)")
        }
        return report
    }

    /// Whether a failed `KeybumpsFolderMove` left the recordings or the index in their old place.
    /// One it left there because it is, or holds, a folder chosen before #605 doesn't count.
    private var recordingsWait: Bool {
        let chosen = AppPreferences.chosenScreengrabFolderPaths(in: defaults)
        return [KeybumpsFolderItem.recordings, .recordingsIndex].contains {
            paths.leftInOldPlace.contains($0) && !KeybumpsFolderMove.holdsChosenFolder(paths.oldPlace(of: $0), chosen)
        }
    }

    // MARK: Screenshots

    /// Each screenshot item outside the history, given a copy there.
    private func moveScreenshots(_ report: inout Report) {
        let file = paths.inUse(.clipboardHistory)
        guard var entries = readJSON(file) as? [[String: Any]] else { return }
        let history = paths.screengrabsScreenshots
        let media = paths.inUse(.clipboardMedia)
        var named = Self.names(in: history, of: entries.flatMap { [$0["mediaPath"], $0["sourcePath"]] }.compactMap { $0 as? String })
        var copiesInMedia: [URL] = []
        for index in entries.indices where Self.isScreenshot(entries[index]) {
            let mediaPath = entries[index]["mediaPath"] as? String
            let sourcePath = entries[index]["sourcePath"] as? String
            guard let mediaPath, !ScreengrabFiles.isDirectly(URL(fileURLWithPath: mediaPath), in: history) else { continue }
            // Its copy in `media/`, else its own file; with neither, it stays as it was, moved or deleted.
            guard let original = [mediaPath, sourcePath].compactMap({ $0 }).map({ URL(fileURLWithPath: $0) }).first(where: exists) else { continue }
            let like = Self.historyName(for: original, named: sourcePath, in: history)
            switch place(original, in: history, naming: ScreengrabFiles.fileNames(like: like), named: named, sharing: false) {
            case .placed(let kept), .found(let kept):
                named.insert(kept.lastPathComponent)
                entries[index]["mediaPath"] = kept.path
                entries[index]["sourcePath"] = kept.path
                report.screenshots += 1
                if Self.isInside(original, media) { copiesInMedia.append(original) }
            case .named:
                continue
            case .failed(let code):
                fail(.copyScreenshot, code: code, &report)
            }
        }
        guard report.screenshots > 0 else { return }
        do {
            // As Clipboard History writes it.
            let data = try JSONSerialization.data(withJSONObject: entries, options: [])
            try data.write(to: file, options: .atomic)
        } catch {
            // The items still name their copies in `media/`, and the next launch finds the copies
            // made here already in place.
            fail(.writeClipboardHistory, code: (error as NSError).code, &report)
            report.screenshots = 0
            return
        }
        for copy in copiesInMedia { try? fileManager.removeItem(at: copy) }
    }

    /// The name a screenshot's copy in the history starts from: its own file's name, with the
    /// extension of the file copied, which is what it holds.
    private static func historyName(for original: URL, named sourcePath: String?, in history: URL) -> URL {
        let own = sourcePath.map { URL(fileURLWithPath: $0) } ?? original
        let base = own.deletingPathExtension().lastPathComponent
        let fileExtension = original.pathExtension.isEmpty ? own.pathExtension : original.pathExtension
        return history.appendingPathComponent(base).appendingPathExtension(fileExtension)
    }

    /// A screenshot, as `ClipboardEntry` decodes one: an image, marked as a screen capture, or, in
    /// history saved before that mark, with a source.
    private static func isScreenshot(_ entry: [String: Any]) -> Bool {
        guard entry["kind"] as? String == ClipboardEntry.Kind.image.rawValue else { return false }
        return (entry["isScreenCapture"] as? Bool) ?? (entry["sourcePath"] is String)
    }

    // MARK: Recordings

    /// Each recording the index lists outside the history, given a copy of its folder there. Returns
    /// the folders it listed there, resolved (`ProductPaths.canonicalPath`).
    private func moveIndexedRecordings(_ report: inout Report) -> Set<String> {
        let file = paths.inUse(.recordingsIndex)
        guard var index = readJSON(file) as? [String: Any],
              index["version"] as? Int == RecordingIndexFile.currentVersion,
              var recordings = index["recordings"] as? [Any] else { return [] }
        let history = paths.screengrabsRecordings
        var named = Self.names(in: history, of: recordings.compactMap { ($0 as? [String: Any])?["folder"] as? String })
        var listedOutside: Set<String> = []
        var duplicates: [Int] = []
        var changed = false
        for position in recordings.indices {
            guard var recording = recordings[position] as? [String: Any],
                  let path = recording["folder"] as? String else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard !ScreengrabFiles.isDirectly(folder, in: history), isFolder(folder) else { continue }
            listedOutside.insert(ProductPaths.canonicalPath(folder))
            switch place(folder, in: history, naming: ScreengrabFiles.recordingFolderNames(like: folder), named: named, sharing: true) {
            case .placed(let kept), .found(let kept):
                named.insert(kept.lastPathComponent)
                recording["folder"] = kept.path
                recordings[position] = recording
                report.recordings += 1
                changed = true
            case .named:
                // The launch's index check listed the copy an earlier launch made, before the index
                // was written: that entry is the recording.
                duplicates.append(position)
                changed = true
            case .failed(let code):
                fail(.copyRecording, code: code, &report)
            }
        }
        guard changed else { return listedOutside }
        for position in duplicates.reversed() { recordings.remove(at: position) }
        index["recordings"] = recordings
        do {
            // As the index writes it: readable only by the person (`PrivateFile`).
            let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try PrivateFile.write(data, to: file)
            report.duplicates += duplicates.count
        } catch {
            fail(.writeIndex, code: (error as NSError).code, &report)
            report.recordings = 0
        }
        return listedOutside
    }

    /// Each recording in a folder ScreenGrabs recorded into that the index didn't list (`indexed`),
    /// given a copy in the history, unless the history holds a folder of its name: the recorder names
    /// each by the second it started, so that's the same recording. Only folders the recorder names,
    /// holding a video's `meta.json`, are opened, as the index's own check does.
    private func moveUnindexedRecordings(skipping indexed: Set<String>, _ report: inout Report) {
        let history = paths.screengrabsRecordings
        let historyPath = ProductPaths.canonicalPath(history)
        for folder in RecordingFolderMemory(defaults: defaults).folders where ProductPaths.canonicalPath(folder) != historyPath {
            let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for recording in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ScreencastCaptureFolder.isFolderName(recording.lastPathComponent) && isFolder(recording) {
                guard !indexed.contains(ProductPaths.canonicalPath(recording)),
                      !exists(history.appendingPathComponent(recording.lastPathComponent)),
                      RecordingStructure.read(in: recording)?.isVideo == true else { continue }
                switch place(recording, in: history, naming: ScreengrabFiles.recordingFolderNames(like: recording), named: [], sharing: true) {
                case .placed: report.recordings += 1
                case .found, .named: continue
                case .failed(let code): fail(.copyUnindexedRecording, code: code, &report)
                }
            }
        }
    }

    // MARK: Copying

    private enum Placed: Equatable {
        /// A new copy.
        case placed(URL)
        /// One already there with the same contents that nothing names, such as one a launch cut
        /// short made.
        case found(URL)
        /// One already there with the same contents that something else names.
        case named(URL)
        case failed(Int)
    }

    /// Puts a copy of `original` in `folder` under the first free name `name(n)` gives
    /// (`ScreengrabFiles.copy`). A name holding the same contents is the copy, unless it's one of
    /// `named`, the names in `folder` something names: then that's `.named` when `sharing`, and is
    /// passed over otherwise, so two screenshots never share a file.
    private func place(_ original: URL, in folder: URL, naming name: (Int) -> String, named: Set<String>, sharing: Bool) -> Placed {
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed((error as NSError).code)
        }
        for attempt in 1...ScreengrabFiles.maximumAttempts {
            let destination = folder.appendingPathComponent(name(attempt))
            switch ScreengrabFiles.copy(original, to: destination, fileManager: fileManager, clone: clone) {
            case .copied(let url): return .placed(url)
            case .failed(let code): return .failed(code)
            case .exists:
                guard fileManager.contentsEqual(atPath: original.path, andPath: destination.path) else { continue }
                guard named.contains(destination.lastPathComponent) else { return .found(destination) }
                if sharing { return .named(destination) }
            }
        }
        return .failed(Int(EEXIST))
    }

    // MARK: Helpers

    private enum Stage: String {
        case copyScreenshot, writeClipboardHistory, copyRecording, writeIndex, copyUnindexedRecording
    }

    private func fail(_ stage: Stage, code: Int, _ report: inout Report) {
        report.failures += 1
        logger.error("screengrabs history move failed stage=\(stage.rawValue, privacy: .public) code=\(code, privacy: .public)")
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    private func readJSON(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// The names of those of `paths` directly in `folder`, however either is spelled
    /// (`ScreengrabFiles.isDirectly`).
    private static func names(in folder: URL, of paths: [String]) -> Set<String> {
        Set(paths.map { URL(fileURLWithPath: $0) }.filter { ScreengrabFiles.isDirectly($0, in: folder) }.map(\.lastPathComponent))
    }

    /// Whether `url` is inside `folder`, links resolved.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/")
    }
}
