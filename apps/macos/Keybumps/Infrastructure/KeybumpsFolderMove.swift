import Darwin
import Foundation
import OSLog

/// A file or folder that the one-time move (`KeybumpsFolderMove`, ADR 0013) brings into the
/// Keybumps folder, in the order it moves them. Its old place and its place now are
/// `ProductPaths.oldPlace(of:)` and `ProductPaths.place(of:)`.
enum KeybumpsFolderItem: String, CaseIterable, Sendable {
    /// Dictation History's folders, from `~/Documents/Keybumps/recordings`.
    case dictationHistory
    case lastDictation
    /// The downloaded models, about 4 GB, from `DictationModels/` at the top of the Keybumps folder.
    /// A download cut short moves with them and is still not installed: `model-location.txt` is
    /// written only once a model has downloaded and checked out (`DictationModelManager`), and the
    /// move rewrites the folder it names (`rewritePaths`).
    case dictationModels
    case emojiRecents
    case recentItems
    case applicationUsage
    case timers
    case clipboardMedia
    case clipboardHistory
    case recentTranslations
    /// `snippets.json`. The move takes its `snippets.unreadable-<date>.json` copies along.
    case snippets
    case coachingEvents
    /// ScreenGrabs' recordings from before #504, `~/Documents/Keybumps/captures`.
    case recordings
    case recordingsIndex
    case recordingsIndexUnreadable
    case screencastRepositories

    /// In `~/Documents/Keybumps`, a folder macOS asks permission for, so the move looks there only
    /// on a Mac that ran an earlier build (`KeybumpsFolderMove.looksInDocuments`).
    var isInDocuments: Bool { self == .dictationHistory || self == .recordings }
}

extension ProductPaths {
    /// Where `item` was kept before #602.
    func oldPlace(of item: KeybumpsFolderItem) -> URL {
        switch item {
        case .dictationHistory: oldDocumentsFolder.appendingPathComponent("recordings", isDirectory: true)
        case .lastDictation: keybumpsFolder.appendingPathComponent(DictationService.recoveryFileName)
        case .dictationModels: keybumpsFolder.appendingPathComponent("DictationModels", isDirectory: true)
        case .emojiRecents: keybumpsFolder.appendingPathComponent(EmojiRecents.fileName)
        case .recentItems: keybumpsFolder.appendingPathComponent(RecentItemStore.fileName)
        case .applicationUsage: keybumpsFolder.appendingPathComponent(ApplicationUsageStore.fileName)
        case .timers: keybumpsFolder.appendingPathComponent(TimerStore.fileName)
        case .clipboardMedia: keybumpsFolder.appendingPathComponent("clipboard-media", isDirectory: true)
        case .clipboardHistory: keybumpsFolder.appendingPathComponent(ClipboardHistoryService.fileName)
        case .recentTranslations: keybumpsFolder.appendingPathComponent(RecentTranslations.fileName)
        case .snippets: keybumpsFolder.appendingPathComponent(SnippetStore.fileName)
        case .coachingEvents: keybumpsFolder.appendingPathComponent(JSONEventPersistence.fileName)
        case .recordings: oldDocumentsFolder.appendingPathComponent("captures", isDirectory: true)
        case .recordingsIndex: keybumpsFolder.appendingPathComponent(RecordingIndexFile.fileName)
        case .recordingsIndexUnreadable: keybumpsFolder.appendingPathComponent(RecordingLibrary.unreadableCopyName)
        case .screencastRepositories: keybumpsFolder.appendingPathComponent(ScreencastRepositoryMemory.fileName)
        }
    }

    /// Where `item` is kept in the Keybumps folder.
    func place(of item: KeybumpsFolderItem) -> URL {
        switch item {
        case .dictationHistory: dictationRecordings
        case .lastDictation: dictation.appendingPathComponent(DictationService.recoveryFileName)
        case .dictationModels: dictationModels
        case .emojiRecents: emojiPicker.appendingPathComponent(EmojiRecents.fileName)
        case .recentItems: quickSearch.appendingPathComponent(RecentItemStore.fileName)
        case .applicationUsage: quickSearch.appendingPathComponent(ApplicationUsageStore.fileName)
        case .timers: timers.appendingPathComponent(TimerStore.fileName)
        case .clipboardMedia: clipboardHistory.appendingPathComponent("media", isDirectory: true)
        case .clipboardHistory: clipboardHistory.appendingPathComponent(ClipboardHistoryService.fileName)
        case .recentTranslations: translations.appendingPathComponent(RecentTranslations.fileName)
        case .snippets: snippets.appendingPathComponent(SnippetStore.fileName)
        case .coachingEvents: shortcutCoach.appendingPathComponent(JSONEventPersistence.fileName)
        case .recordings: screengrabsRecordings
        case .recordingsIndex: screengrabs.appendingPathComponent(RecordingIndexFile.fileName)
        case .recordingsIndexUnreadable: screengrabs.appendingPathComponent(RecordingLibrary.unreadableCopyName)
        case .screencastRepositories: screengrabs.appendingPathComponent(ScreencastRepositoryMemory.fileName)
        }
    }

    /// Where its store reads and writes `item`: its place in the Keybumps folder, unless this
    /// launch's move left it in its old place (`leftInOldPlace`), where it's read until a later
    /// launch moves it. It never looks at the disk.
    func inUse(_ item: KeybumpsFolderItem) -> URL {
        leftInOldPlace.contains(item) ? oldPlace(of: item) : place(of: item)
    }
}

/// The one-time move into the Keybumps folder (ADR 0013, #602), run at launch before any store
/// loads (`AppModel.forLaunch`). Each `KeybumpsFolderItem` goes from its old place to its place
/// in the Keybumps folder, and every launch runs it again, so a move cut short finishes later.
///
/// - **A rename** on the same volume, which never replaces anything there (`RENAME_EXCL`). Else a
///   copy beside the destination (`.<name>.keybumps-moving`), checked against the original, put
///   in place the same way, and only then the original removed.
/// - **Already there:** two folders merge, item by item. A file identical to the one there is
///   removed from the old place; one that differs is a conflict: both stay, and the store uses the
///   Keybumps folder's.
/// - **A failure** leaves the original where it was, and its store reads it there this launch
///   (`leftInOldPlace`). Nothing is ever overwritten or deleted except an original whose copy is in
///   place, Finder's `.DS_Store`, and the move's own partial copies.
/// - **A folder chosen** in Settings › ScreenGrabs before #605, or one inside it, isn't moved: an old
///   place that is, or holds, a chosen folder stays, read there, and is looked at again each launch.
///   Nor is a chosen `~/Documents/Keybumps` removed once it's empty.
/// - **Paths:** Clipboard History, the recordings index, and each Dictation model's
///   `model-location.txt` store absolute paths, and ScreenGrabs remembered the folders it recorded
///   into until #605 (`RecordingFolderMemory`); one into a folder that moved is rewritten once its
///   file is in the new place (`rewritePaths`). Then `ScreengrabsHistoryMove` brings every screengrab
///   into ScreenGrabs' history.
/// - **This change's first candidates** kept each dictation at the top of `dictation/`; they move
///   into `dictation/recordings/` (`moveDictationsFromTheFirstCandidates`).
/// - **`~/Documents/Keybumps`** is looked in only on a Mac that ran an earlier build: while
///   `documentsMovedKey` isn't set and the Keybumps folder exists or `AppPreferences.ranBefore`,
///   and again once it's set whenever a file outside Documents is in its old place and newer than
///   the key, the sign that a build before #602 ran since and saved dictations in Documents too. So
///   a new install never makes macOS ask for Documents. It's removed once it's empty, and the key
///   set to the time once nothing of Keybumps's is left there.
/// - **Logs** say only the stage, the item, an error code, and how long the move took: never a
///   path, a name, or content.
struct KeybumpsFolderMove {
    struct Report: Equatable {
        var moved = 0
        var conflicts = 0
        var failures = 0
        /// Items that are still in their old place and not in the Keybumps folder.
        var leftInOldPlace: Set<KeybumpsFolderItem> = []
        var looksInDocuments = false
    }

    /// The time nothing of Keybumps's was left in `~/Documents/Keybumps`, or a Mac that never ran
    /// a build before the Keybumps folder was found to be new (`documentsMoved(in:)`).
    static let documentsMovedKey = "keybumpsFolder.documentsMoved"

    /// When the key was set, or nil while Documents is still to be looked in. `true`, which this
    /// change's first candidates stored, reads as long ago.
    static func documentsMoved(in defaults: UserDefaults) -> Date? {
        if let date = defaults.object(forKey: documentsMovedKey) as? Date { return date }
        return defaults.bool(forKey: documentsMovedKey) ? .distantPast : nil
    }

    /// What this launch's move left in its old place. Set once at launch, before any store is
    /// built, and read through `ProductPaths.keybumps()`.
    nonisolated(unsafe) private(set) static var leftInOldPlace: Set<KeybumpsFolderItem> = []

    let paths: ProductPaths
    var fileManager: FileManager = .default
    var defaults: UserDefaults = .standard
    /// A rename that never replaces anything: 0, or the error code. Tests make it fail with `EXDEV`
    /// so the copy fallback runs.
    var rename: (URL, URL) -> Int32 = KeybumpsFolderMove.renameExclusively
    private let logger = Logger(subsystem: "com.serp.keybumps", category: "keybumps-folder")

    init(paths: ProductPaths, fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.fileManager = fileManager
        self.defaults = defaults
    }

    /// The app's launch. Never under the unit-test host or in UI test mode, whose folders start empty.
    static func runAtLaunch() {
        guard !UnitTestHost.isActive, ProductPaths.sandboxRoot == nil else { return }
        leftInOldPlace = KeybumpsFolderMove(paths: .keybumps()).run().leftInOldPlace
    }

    @discardableResult
    func run() -> Report {
        let started = ContinuousClock.now
        var report = Report()
        report.looksInDocuments = looksInDocuments()
        var documentsFailures = 0
        let chosen = AppPreferences.chosenScreengrabFolderPaths(in: defaults)
        for item in KeybumpsFolderItem.allCases where report.looksInDocuments || !item.isInDocuments {
            let failuresBefore = report.failures
            if holdsChosenFolder(paths.oldPlace(of: item), chosen) {
                if fileExists(paths.oldPlace(of: item)) { report.leftInOldPlace.insert(item) }
                if item.isInDocuments { documentsFailures += 1 }
                continue
            }
            move(paths.oldPlace(of: item), to: paths.place(of: item), item: item, &report)
            if item == .snippets { moveUnreadableSnippetCopies(&report) }
            if fileExists(paths.oldPlace(of: item)), !fileExists(paths.place(of: item)) {
                report.leftInOldPlace.insert(item)
            }
            if item.isInDocuments { documentsFailures += report.failures - failuresBefore }
        }
        moveDictationsFromTheFirstCandidates(&report)
        let failuresBefore = report.failures
        rewritePaths(&report)
        if report.looksInDocuments {
            documentsFailures += report.failures - failuresBefore
            if !holdsChosenFolder(paths.oldDocumentsFolder, chosen) { removeIfEmpty(paths.oldDocumentsFolder) }
            if documentsFailures == 0 {
                defaults.set(Date(), forKey: Self.documentsMovedKey)
            } else {
                // Looked in again next launch, even when what showed an older build ran has moved.
                defaults.removeObject(forKey: Self.documentsMovedKey)
            }
        }
        // A copy across volumes, or of files iCloud has to download first, can make a launch slow.
        let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
        logger.info("keybumps folder move moved=\(report.moved, privacy: .public) conflicts=\(report.conflicts, privacy: .public) failures=\(report.failures, privacy: .public) left=\(report.leftInOldPlace.count, privacy: .public) documents=\(report.looksInDocuments, privacy: .public) ms=\(milliseconds, privacy: .public)")
        return report
    }

    /// Whether `folder` is a folder chosen in Settings › ScreenGrabs before #605, or holds one. Lexical: it never
    /// looks at the disk.
    private func holdsChosenFolder(_ folder: URL, _ chosen: [String]) -> Bool {
        let path = folder.standardizedFileURL.path
        return chosen.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// Whether `~/Documents/Keybumps` may still hold something of Keybumps's. Every case that looks
    /// is a Mac that ran an earlier build, which already settled macOS's Documents permission.
    /// - Once the key is set: only if an older build ran since. A build before #602 saves each
    ///   dictation in Documents, and writes `last-dictation.txt`, Clipboard History, and the rest at
    ///   the top of the Keybumps folder, so one of those newer than the key is the sign. One left
    ///   there as a conflict is older, and doesn't count.
    /// - Before: on a Mac with the Keybumps folder, or where an earlier build ran (a Keybumps folder
    ///   removed by hand or by an uninstaller). Anything else is a new install, and the key is set
    ///   without looking.
    private func looksInDocuments() -> Bool {
        if let movedAt = Self.documentsMoved(in: defaults) {
            return KeybumpsFolderItem.allCases.contains { !$0.isInDocuments && modified(paths.oldPlace(of: $0), after: movedAt) }
        }
        guard fileExists(paths.keybumpsFolder) || AppPreferences.ranBefore(in: defaults) else {
            defaults.set(Date(), forKey: Self.documentsMovedKey)
            return false
        }
        return true
    }

    // MARK: Moving

    private enum Stage: String {
        case inspect, makeFolder, list, copy, verify, place, removeOriginal, rewrite
    }

    private enum Entry: Equatable {
        case missing, file, folder
        case unreadable(Int32)
    }

    private func entry(_ url: URL) -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .missing : .unreadable(code)
        }
        return info.st_mode & S_IFMT == S_IFDIR ? .folder : .file
    }

    private func fileExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func modified(_ url: URL, after date: Date) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000) > date
    }

    private func fail(_ stage: Stage, _ item: KeybumpsFolderItem, code: Int, _ report: inout Report) {
        report.failures += 1
        logger.error("keybumps folder move failed stage=\(stage.rawValue, privacy: .public) item=\(item.rawValue, privacy: .public) code=\(code, privacy: .public)")
    }

    /// Moves `source` to `destination`, or merges it into what's there.
    private func move(_ source: URL, to destination: URL, item: KeybumpsFolderItem, _ report: inout Report) {
        let sourceEntry = entry(source)
        switch sourceEntry {
        case .missing: return
        case .unreadable(let code): return fail(.inspect, item, code: Int(code), &report)
        case .file, .folder: break
        }
        switch entry(destination) {
        case .unreadable(let code):
            fail(.inspect, item, code: Int(code), &report)
        case .file, .folder:
            merge(source, sourceEntry, into: destination, item: item, &report)
        case .missing:
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return fail(.makeFolder, item, code: (error as NSError).code, &report)
            }
            // A copy an earlier launch didn't finish: the original is still here, so it goes.
            let partial = Self.partialCopy(of: destination)
            if fileExists(partial) { try? fileManager.removeItem(at: partial) }
            switch rename(source, destination) {
            case 0: report.moved += 1
            case EEXIST: merge(source, sourceEntry, into: destination, item: item, &report)
            default: copyThenRemove(source, to: destination, item: item, &report)
            }
        }
    }

    /// `source` where `destination` is already there: folders merge item by item, an identical file
    /// is removed from the old place, and anything else is a conflict that leaves both.
    private func merge(_ source: URL, _ sourceEntry: Entry, into destination: URL, item: KeybumpsFolderItem, _ report: inout Report) {
        let destinationEntry = entry(destination)
        if sourceEntry == .folder, destinationEntry == .folder {
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: source.path)
            } catch {
                return fail(.list, item, code: (error as NSError).code, &report)
            }
            for name in names.sorted() where name != Self.finderMetadata {
                move(source.appendingPathComponent(name), to: destination.appendingPathComponent(name), item: item, &report)
            }
            removeIfEmpty(source)
        } else if sourceEntry == .file, destinationEntry == .file,
                  fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
            do {
                try fileManager.removeItem(at: source)
                report.moved += 1
            } catch {
                fail(.removeOriginal, item, code: (error as NSError).code, &report)
            }
        } else {
            report.conflicts += 1
        }
    }

    /// The fallback when a rename can't move it, such as to another volume: a copy beside the
    /// destination, checked against the original, renamed into place, and then the original removed.
    private func copyThenRemove(_ source: URL, to destination: URL, item: KeybumpsFolderItem, _ report: inout Report) {
        let partial = Self.partialCopy(of: destination)
        do {
            try fileManager.copyItem(at: source, to: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            return fail(.copy, item, code: (error as NSError).code, &report)
        }
        guard fileManager.contentsEqual(atPath: source.path, andPath: partial.path) else {
            try? fileManager.removeItem(at: partial)
            return fail(.verify, item, code: 0, &report)
        }
        let code = rename(partial, destination)
        guard code == 0 else {
            try? fileManager.removeItem(at: partial)
            return fail(.place, item, code: Int(code), &report)
        }
        do {
            try fileManager.removeItem(at: source)
            report.moved += 1
        } catch {
            // The copy is in place; a later launch removes what's left of the original as identical.
            fail(.removeOriginal, item, code: (error as NSError).code, &report)
        }
    }

    /// This change's first candidates kept each dictation at the top of `dictation/`, which now holds
    /// `recordings/` and `models/` too: a folder there named as a dictation is (`1790000000`, or
    /// `1790000000-2`) moves into `recordings/`. Not a released layout, so a failure is only logged,
    /// and the next launch tries again.
    private func moveDictationsFromTheFirstCandidates(_ report: inout Report) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: paths.dictation.path) else { return }
        for name in names.sorted() where Self.isDictationFolderName(name) {
            let folder = paths.dictation.appendingPathComponent(name, isDirectory: true)
            guard entry(folder) == .folder else { continue }
            move(folder, to: paths.dictationRecordings.appendingPathComponent(name, isDirectory: true), item: .dictationHistory, &report)
        }
    }

    /// A Dictation History folder's name: its time in seconds, and `-2`, `-3`… after a second one
    /// that second (`DictationHistoryService.prepareRecording`).
    static func isDictationFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    private func moveUnreadableSnippetCopies(_ report: inout Report) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: paths.keybumpsFolder.path) else { return }
        for name in names.sorted() where SnippetStore.isUnreadableCopyName(name) {
            move(
                paths.keybumpsFolder.appendingPathComponent(name),
                to: paths.snippets.appendingPathComponent(name),
                item: .snippets,
                &report
            )
        }
    }

    /// Removes `folder` if nothing but Finder's `.DS_Store` is in it. Never anything else.
    private func removeIfEmpty(_ folder: URL) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path),
              names.allSatisfy({ $0 == Self.finderMetadata }) else { return }
        for name in names { try? fileManager.removeItem(at: folder.appendingPathComponent(name)) }
        _ = rmdir(folder.path)
    }

    private static let finderMetadata = ".DS_Store"

    static func partialCopy(of destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).keybumps-moving")
    }

    /// A rename that never replaces what's at `destination`. 0, or the error code.
    static func renameExclusively(_ source: URL, to destination: URL) -> Int32 {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        // A volume without exclusive renames: only this launch writes here, so a check suffices.
        guard code == ENOTSUP || code == EINVAL else { return code }
        var info = stat()
        if lstat(destination.path, &info) == 0 { return EEXIST }
        return Darwin.rename(source.path, destination.path) == 0 ? 0 : errno
    }

    // MARK: Paths

    /// Clipboard History's image copies and screenshot sources, the recordings index's folders, the
    /// folders ScreenGrabs remembered recording into, and each Dictation model's folder are absolute
    /// paths. One under a folder that moved is rewritten to the same place in the new folder once
    /// it's gone from the old one and is there. A file that can't be read, or a later build's index,
    /// is left as it is.
    private func rewritePaths(_ report: inout Report) {
        var moves: [(old: String, new: String)] = [
            (paths.oldPlace(of: .clipboardMedia).path, paths.place(of: .clipboardMedia).path),
            (paths.oldPlace(of: .dictationModels).path, paths.place(of: .dictationModels).path),
        ]
        if report.looksInDocuments { moves.append((paths.oldPlace(of: .recordings).path, paths.place(of: .recordings).path)) }
        var inUse = paths
        inUse.leftInOldPlace = report.leftInOldPlace

        let clipboard = inUse.inUse(.clipboardHistory)
        if var entries = readJSON(clipboard) as? [[String: Any]] {
            var changed = false
            for index in entries.indices {
                for key in ["mediaPath", "sourcePath"] {
                    guard let path = entries[index][key] as? String, let moved = rewritten(path, moves) else { continue }
                    entries[index][key] = moved
                    changed = true
                }
            }
            if changed {
                // As Clipboard History writes it.
                write(entries, options: [], to: clipboard, item: .clipboardHistory, &report) { data, url in
                    try data.write(to: url, options: .atomic)
                }
            }
        }

        let index = inUse.inUse(.recordingsIndex)
        if var file = readJSON(index) as? [String: Any],
           file["version"] as? Int == RecordingIndexFile.currentVersion,
           var recordings = file["recordings"] as? [Any] {
            var changed = false
            for position in recordings.indices {
                guard var recording = recordings[position] as? [String: Any],
                      let folder = recording["folder"] as? String,
                      let moved = rewritten(folder, moves) else { continue }
                recording["folder"] = moved
                recordings[position] = recording
                changed = true
            }
            if changed {
                file["recordings"] = recordings
                // As the index writes it: readable only by the person (`PrivateFile`).
                write(file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes], to: index, item: .recordingsIndex, &report) {
                    try PrivateFile.write($0, to: $1)
                }
            }
        }

        // Else the model reads as not installed, and Dictation goes back to Apple Speech.
        for engine in DictationTranscriptionEngine.allCases where engine.requiresDownload {
            let file = DictationModelManager.locationFile(for: engine, in: inUse.inUse(.dictationModels))
            guard let stored = try? String(contentsOf: file, encoding: .utf8),
                  let moved = rewritten(stored.trimmingCharacters(in: .whitespacesAndNewlines), moves) else { continue }
            do {
                // As `DictationModelManager` writes it.
                try moved.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                fail(.rewrite, .dictationModels, code: (error as NSError).code, &report)
            }
        }

        // So the move into ScreenGrabs' history doesn't look for the old recordings folder in Documents.
        let remembered = defaults.stringArray(forKey: RecordingFolderMemory.key) ?? []
        let updated = remembered.map { rewritten($0, moves) ?? $0 }
        if updated != remembered {
            var seen: Set<String> = []
            defaults.set(updated.filter { seen.insert($0).inserted }, forKey: RecordingFolderMemory.key)
        }
    }

    /// `path` in the folder it moved to, when it is, or is in, a folder that moved and is now gone
    /// from the old place and there in the new one.
    private func rewritten(_ path: String, _ moves: [(old: String, new: String)]) -> String? {
        for move in moves where path == move.old || path.hasPrefix(move.old + "/") {
            let moved = move.new + path.dropFirst(move.old.count)
            let isGone = !fileExists(URL(fileURLWithPath: path))
            return isGone && fileExists(URL(fileURLWithPath: moved)) ? moved : nil
        }
        return nil
    }

    private func readJSON(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func write(
        _ object: Any,
        options: JSONSerialization.WritingOptions,
        to url: URL,
        item: KeybumpsFolderItem,
        _ report: inout Report,
        _ save: (Data, URL) throws -> Void
    ) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: options)
            try save(data, url)
        } catch {
            fail(.rewrite, item, code: (error as NSError).code, &report)
        }
    }
}
