import Foundation
import Observation
import OSLog

/// Whether the recordings and screenshots already in the recordings folder were imported
/// (`screencast.recordingsImported`), so the import runs once.
struct RecordingImportMemory {
    static let key = "screencast.recordingsImported"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isDone: Bool { defaults.bool(forKey: Self.key) }

    func markDone() {
        defaults.set(true, forKey: Self.key)
    }
}

/// Every folder ScreenGrabs recorded into (`screencast.recordingsFolders`, #504): the Recordings
/// folder of the time, chosen or the default, and any fallback, remembered as each recording's own
/// folder is made there, so the launch check and a rebuild find recordings saved in a Recordings
/// folder since changed, and ones kept without reaching `RecordingLibrary.add`. In the defaults,
/// not the index, so it outlives a missing or corrupt index. Never logged.
struct RecordingFolderMemory {
    static let key = "screencast.recordingsFolders"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// In the order first saved in.
    var folders: [URL] {
        (defaults.stringArray(forKey: Self.key) ?? [])
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Adds `folder` once, however it or one remembered is spelled, such as through a link
    /// (`ProductPaths.canonicalPath`).
    func remember(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Self.key) ?? []
        // The same spelling, as for each recording after the first, needs no look at the disk.
        guard !paths.contains(path) else { return }
        let resolved = ProductPaths.canonicalPath(folder)
        guard !paths.contains(where: { ProductPaths.canonicalPath(URL(fileURLWithPath: $0, isDirectory: true)) == resolved }) else { return }
        paths.append(path)
        defaults.set(paths, forKey: Self.key)
    }
}

/// ScreenGrabs' recordings index (#492, ADR 0010 decision 6): every recording Keybumps keeps,
/// wherever it's saved, so the ⌘3 tab lists them (#494). It's `recordings.json` in Application
/// Support (`RecordingIndexFile`, written 0600 by `PrivateFile`), holding each recording's folder
/// and the structure of its `meta.json`, never its review, and it's never logged: logs say only
/// counts and categories. A file name read from either is used only if it stays in its folder
/// (`IndexedRecording.isFileName`).
///
/// - **Added** when the recorder finishes writing (`add`), so a crash before Save still leaves the
///   recording listed. **Read again** when the recording window saves, copies, or can't save it,
///   and **removed** when it discards it (`reviewEnded`).
/// - **Where it looks** (`recordingsFolders`): the old recordings folder (`ProductPaths.captures`),
///   where recordings before #504 stay, and each folder a recording was made in since, remembered
///   as the recorder makes the recording's own folder there (`recordingStarted(in:)`,
///   `RecordingFolderMemory`). So a recording kept without reaching `add`, as one is when
///   ScreenGrabs turns off or Keybumps locks while it records, is found at the next launch. A
///   recording stays indexed wherever it is when the Recordings folder changes (#504), and a rebuild
///   finds it in the folder remembered. A folder no recording was made in is never read, and in one
///   that is, only the folders the recorder names (`ScreencastCaptureFolder.isFolderName`) are
///   opened: a Recordings folder such as the Desktop holds the person's own folders too.
/// - **Moved or deleted:** a recording whose folder, or every video in it, is gone is marked
///   `isMissing` each time the index looks (`load`, `refresh`, `recordingsNewestFirst`), and stays
///   listed until it's removed; it's unmarked if it comes back.
/// - **The import** runs once (`RecordingImportMemory`), the first time the index loads without
///   having run it: each recording in the old recordings folder (`ProductPaths.captures`) is indexed
///   where it is, and each screenshot a QA build's Screencast saved there before #487 goes to the
///   ⌘3 tab through `ClipboardHistoryService.importScreenshot(at:capturedAt:)`. Files are never
///   moved or changed.
/// - **Each launch,** once the index has loaded, the folders it looks in are read again off the main
///   actor (`launchCheck`): a recording there that the index lacks, such as one an older build
///   saved in `ProductPaths.captures` after a rollback, is added, matched by resolved path so none
///   is listed twice. Then, if the file was read and is this build's, poster frames no entry names
///   are deleted.
/// - **A missing or corrupt file** after the import is rebuilt from the recordings in the folders it
///   looks in, without importing screenshots again; entries that can't be decoded are skipped
///   and the rest kept. A corrupt or partly read file is replaced only once its replacement is
///   written in full, and is then kept beside it as `recordings.unreadable.json`. If that fails,
///   the old file stays and the index is read-only until the next launch.
/// - **A file this build can't read or write over** (one that exists but can't be read, or a later
///   build's version, whatever its layout) makes the index read-only: it lists what it can and
///   never writes the file.
/// - **One writer:** the index assumes one copy of Keybumps writes it, so of two at once (a Debug
///   build beside the installed app) the last to write drops what the other added, and the next
///   launch's re-check adds back any recording in the folders it looks in.
/// - **Rollback:** a build before #492 never reads or writes `recordings.json` and leaves it as it
///   was; the recordings it saves stay in their folders, and this build's next launch adds them.
@MainActor
@Observable
final class RecordingLibrary {
    enum State: Equatable {
        case notLoaded
        case ready
        /// Lists what it read, and never writes the file.
        case readOnly
    }

    /// Every indexed recording, newest first.
    private(set) var recordings: [IndexedRecording] = []
    private(set) var state: State = .notLoaded

    @ObservationIgnored let storageURL: URL
    /// The old recordings folder, `ProductPaths.captures`: where the import looks, and always one of
    /// `recordingsFolders`.
    @ObservationIgnored let capturesFolder: URL
    @ObservationIgnored let posterFrames: RecordingPosterFrames
    @ObservationIgnored private let importMemory: RecordingImportMemory
    @ObservationIgnored private let folderMemory: RecordingFolderMemory
    @ObservationIgnored private weak var screenshots: ClipboardHistoryService?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var posterTasks: [UUID: Task<URL?, Never>] = [:]
    /// The next write keeps the file it replaces as `recordings.unreadable.json`: a corrupt or
    /// partly read index.
    @ObservationIgnored private var setsAsideOnSave = false
    /// What each load starts off the main actor: the folders it looks in read again when the load
    /// didn't read them, then the poster-frame sweep. Tests await it.
    @ObservationIgnored private(set) var launchCheck: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    init(
        storageURL: URL,
        capturesFolder: URL,
        posterFrames: RecordingPosterFrames,
        importMemory: RecordingImportMemory,
        folderMemory: RecordingFolderMemory,
        screenshots: ClipboardHistoryService?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.capturesFolder = capturesFolder
        self.posterFrames = posterFrames
        self.importMemory = importMemory
        self.folderMemory = folderMemory
        self.screenshots = screenshots
        self.fileManager = fileManager
        self.now = now
    }

    /// The app's: in Application Support, Caches, and the recordings folder, through `ProductPaths`,
    /// so the UI-test sandbox and the unit-test host keep theirs in their own folders.
    static func makeDefault(
        importMemory: RecordingImportMemory,
        folderMemory: RecordingFolderMemory,
        screenshots: ClipboardHistoryService?
    ) -> RecordingLibrary {
        let paths = ProductPaths.keybumps()
        return RecordingLibrary(
            storageURL: paths.applicationSupport.appendingPathComponent(RecordingIndexFile.fileName),
            capturesFolder: paths.captures,
            posterFrames: RecordingPosterFrames(folder: RecordingPosterFrames.defaultFolder),
            importMemory: importMemory,
            folderMemory: folderMemory,
            screenshots: screenshots
        )
    }

    /// The folders the index looks in for recordings: the old recordings folder, then each folder a
    /// recording was saved in, once each however it's spelled (`ProductPaths.canonicalPath`).
    var recordingsFolders: [URL] {
        var seen: Set<String> = []
        return ([capturesFolder] + folderMemory.folders).filter { seen.insert(ProductPaths.canonicalPath($0)).inserted }
    }

    var unreadableCopyURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("recordings.unreadable.json")
    }

    /// Where a replacement for a corrupt or partly read index is written before it takes its place.
    var stagedURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent(".recordings.rebuilt.json")
    }

    // MARK: Reading

    /// For the ⌘3 tab (#494): every indexed recording, newest first, after looking at each folder
    /// again, so one moved or deleted is marked missing ("Moved or deleted").
    func recordingsNewestFirst() -> [IndexedRecording] {
        load()
        refresh()
        return recordings
    }

    /// The recording's poster frame, made off the main actor the first time and again whenever its
    /// cached file is gone; nil for a missing recording or a video that can't be read.
    func posterFrame(for recording: IndexedRecording) async -> URL? {
        guard !recording.isMissing else { return nil }
        if let task = posterTasks[recording.id] { return await task.value }
        let frames = posterFrames
        let task = Task { await frames.make(for: recording) }
        posterTasks[recording.id] = task
        let url = await task.value
        posterTasks[recording.id] = nil
        // Removed while it was being made: its frame goes with it.
        guard recordings.contains(where: { $0.id == recording.id }) else {
            posterFrames.remove(for: recording)
            return nil
        }
        return url
    }

    /// Reads the index once: from the file, running the import if it hasn't run, or rebuilding a
    /// missing or corrupt file. Then it starts `launchCheck`. Later calls do nothing.
    func load() {
        guard state == .notLoaded else { return }
        state = .ready
        let source: String
        // Whether the launch check reads the recordings folder again: not when this load just did.
        var rereadsFolder = false
        switch readFile() {
        case .missing:
            source = startOver()
        case .unreadable:
            state = .readOnly
            recordings = []
            merge(videoFolders())
            source = "unreadable"
        case .contents(.newer(let read)):
            state = .readOnly
            recordings = read
            source = "newer"
            rereadsFolder = true
        case .contents(.corrupt):
            setsAsideOnSave = true
            source = "corrupt+" + startOver()
        case .contents(.current(let read, let skipped)):
            recordings = read
            source = skipped > 0 ? "partial" : "file"
            setsAsideOnSave = skipped > 0
            if !importMemory.isDone {
                runImport()
            } else if skipped > 0 {
                merge(videoFolders())
                save()
            } else {
                rereadsFolder = true
            }
        }
        sort()
        refresh()
        let missing = recordings.filter(\.isMissing).count
        logger.info("recordings index loaded source=\(source, privacy: .public) count=\(self.recordings.count, privacy: .public) missing=\(missing, privacy: .public)")
        // Only a file that was read says which poster frames are kept: a later build's may name
        // them its own way, and one that can't be read names none this launch knows.
        startLaunchCheck(readingRecordingsFolder: rereadsFolder, sweepingPosterFrames: source != "newer" && source != "unreadable")
    }

    /// Looks again at each recording's folder: one moved or deleted outside Keybumps is marked
    /// missing, and one back where it was isn't.
    func refresh() {
        for index in recordings.indices {
            let missing = !isPresent(recordings[index])
            if recordings[index].isMissing != missing { recordings[index].isMissing = missing }
        }
    }

    // MARK: Changes

    /// The recorder made a recording's own folder in `folder` (`ScreencastRecorder.onFolderMade`):
    /// `folder` is remembered at once, before the recording is kept, so the launch check and a
    /// rebuild look there even if the recording never reaches `add`.
    func recordingStarted(in folder: URL) {
        folderMemory.remember(folder)
    }

    /// The recorder finished writing: the recording is indexed from its `meta.json` at once, or from
    /// what the recorder reported if that couldn't be read, and the folder it's in is remembered.
    func add(_ capture: ScreencastCapture) {
        load()
        folderMemory.remember(capture.folder.deletingLastPathComponent())
        upsert(capture.folder, RecordingStructure.read(in: capture.folder) ?? RecordingStructure(capture, startedAt: now()))
    }

    /// How the recording window ended: Save, Copy, or a review that couldn't be written read the
    /// recording's entry again (adding it if it isn't there); Discard removes it.
    func reviewEnded(_ outcome: ScreencastReviewOutcome) {
        switch outcome {
        case .saved(let input), .copied(let input), .saveFailed(let input, _): update(input.folder)
        case .discarded(let input): remove(folder: input.folder)
        }
    }

    /// Reads the recording in `folder` again; a folder that's gone is marked missing.
    func update(_ folder: URL) {
        load()
        guard let structure = RecordingStructure.read(in: folder), structure.isVideo else {
            refresh()
            return
        }
        upsert(folder, structure)
    }

    /// Removes the recording in `folder` from the index, with its poster frame. Its files are the
    /// caller's: Discard deleted them, or they're gone.
    func remove(folder: URL) {
        load()
        let matched = Set(entries(for: folder))
        guard !matched.isEmpty else { return }
        for recording in recordings where matched.contains(recording.id) {
            posterTasks[recording.id]?.cancel()
            posterFrames.remove(for: recording)
        }
        recordings.removeAll { matched.contains($0.id) }
        save()
    }

    // MARK: Storage

    private enum Found {
        case missing
        case unreadable
        case contents(RecordingIndexFile.Contents)
    }

    private func readFile() -> Found {
        do {
            return .contents(RecordingIndexFile.read(try Data(contentsOf: storageURL)))
        } catch where SnippetStore.isMissingFile(error) {
            return .missing
        } catch {
            return .unreadable
        }
    }

    /// No index, or one that couldn't be read at all: the import if it hasn't run, else the
    /// recordings folder's recordings.
    private func startOver() -> String {
        recordings = []
        if !importMemory.isDone {
            runImport()
            return "import"
        }
        merge(videoFolders())
        save()
        return "rebuilt"
    }

    /// The one-time import: recordings into the index, and a QA build's Screencast screenshots into
    /// the ⌘3 tab at their own dates. Nothing is moved or changed.
    private func runImport() {
        let found = Self.recordingFolders(in: capturesFolder, fileManager: fileManager)
        let videos = found.filter(\.structure.isVideo)
        merge(videos)
        var screenshotCount = 0
        if let screenshots {
            for item in found where item.structure.isScreenshot {
                for file in screenshotFiles(in: item.folder)
                where screenshots.importScreenshot(at: file, capturedAt: item.structure.startedAt) {
                    screenshotCount += 1
                }
            }
        }
        save()
        importMemory.markDone()
        logger.info("recordings imported recordings=\(videos.count, privacy: .public) screenshots=\(screenshotCount, privacy: .public)")
    }

    @discardableResult
    private func save() -> Bool {
        guard state == .ready else { return false }
        do {
            let data = try RecordingIndexFile(recordings: recordings).encoded()
            if setsAsideOnSave {
                try replaceSettingAside(with: data)
                setsAsideOnSave = false
            } else {
                try PrivateFile.write(data, to: storageURL, fileManager: fileManager)
            }
            return true
        } catch {
            logger.error("recordings index not written code=\((error as NSError).code, privacy: .public)")
            // The file that wasn't set aside stays, and no later write this launch replaces it.
            if setsAsideOnSave { state = .readOnly }
            return false
        }
    }

    /// Replaces a corrupt or partly read index, keeping it as `recordings.unreadable.json` (in place
    /// of an older copy). The replacement is written in full first, the old file is linked (or
    /// copied) aside, and then the replacement is renamed over it, so `recordings.json` is there
    /// throughout, and if any step fails the old file stays where it is.
    private func replaceSettingAside(with data: Data) throws {
        try PrivateFile.write(data, to: stagedURL, fileManager: fileManager)
        do {
            try? fileManager.removeItem(at: unreadableCopyURL)
            if link(storageURL.path, unreadableCopyURL.path) != 0 {
                try fileManager.copyItem(at: storageURL, to: unreadableCopyURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
        guard rename(stagedURL.path, storageURL.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: stagedURL)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: The folders it looks in

    /// Each folder in `capturesFolder` named as the recorder names a recording's
    /// (`ScreencastCaptureFolder.isFolderName`) with a `meta.json` this build understands, by name.
    /// Any other folder is never opened. It lists the folder and reads each `meta.json`, so the
    /// launch check runs it off the main actor.
    nonisolated private static func recordingFolders(in capturesFolder: URL, fileManager: FileManager) -> [RecordingFolder] {
        let items = (try? fileManager.contentsOfDirectory(
            at: capturesFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { ScreencastCaptureFolder.isFolderName($0.lastPathComponent) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in
                RecordingStructure.read(in: folder).map {
                    RecordingFolder(folder: folder, structure: $0, resolvedPath: ProductPaths.canonicalPath(folder))
                }
            }
    }

    /// The recordings in every folder it looks in.
    private func videoFolders() -> [RecordingFolder] {
        Self.videoFolders(in: recordingsFolders, fileManager: fileManager)
    }

    nonisolated private static func videoFolders(in folders: [URL], fileManager: FileManager) -> [RecordingFolder] {
        folders.flatMap { recordingFolders(in: $0, fileManager: fileManager) }.filter(\.structure.isVideo)
    }

    /// The found folders that match no indexed folder, or one found before them, by resolved path.
    nonisolated private static func unindexed(_ found: [RecordingFolder], indexed: [URL]) -> [RecordingFolder] {
        var seen = Set(indexed.map(ProductPaths.canonicalPath))
        return found.filter { seen.insert($0.resolvedPath).inserted }
    }

    /// Off the main actor: the folders it looks in read again, adding recordings the index lacks,
    /// when the load didn't read them; then poster frames no entry names are deleted.
    private func startLaunchCheck(readingRecordingsFolder: Bool, sweepingPosterFrames: Bool) {
        let folders = recordingsFolders
        let fileManager = fileManager
        let indexed = recordings.map(\.folder)
        let indexedIDs = Set(recordings.map(\.id))
        launchCheck = Task { [weak self] in
            if readingRecordingsFolder {
                let found = await Task.detached(priority: .utility) {
                    Self.unindexed(Self.videoFolders(in: folders, fileManager: fileManager), indexed: indexed)
                }.value
                self?.addFound(found, indexedBefore: indexedIDs)
            }
            if sweepingPosterFrames { await self?.sweepPosterFrames() }
        }
    }

    /// The launch check's finds, less any indexed (by resolved path) or gone while it looked.
    private func addFound(_ found: [RecordingFolder], indexedBefore: Set<UUID>) {
        let indexedSince = Set(recordings.filter { !indexedBefore.contains($0.id) }.map { ProductPaths.canonicalPath($0.folder) })
        let added = found.filter { !indexedSince.contains($0.resolvedPath) && fileManager.fileExists(atPath: $0.folder.path) }
        guard !added.isEmpty else { return }
        append(added)
        save()
        logger.info("recordings folders checked added=\(added.count, privacy: .public)")
    }

    /// Deletes the poster frames no entry names, off the main actor, keeping any made from now on.
    private func sweepPosterFrames() async {
        let kept = Set(recordings.map(\.posterFrame))
        let cutoff = Date()
        let frames = posterFrames
        let removed = await Task.detached(priority: .utility) {
            frames.removeAll(except: kept, writtenBefore: cutoff)
        }.value
        if removed > 0 { logger.info("recording poster frames swept count=\(removed, privacy: .public)") }
    }

    /// A Screencast screenshot folder's PNGs: `screenshot-1.png`, and any `screenshot-1 (edited).png`.
    private func screenshotFiles(in folder: URL) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix("screenshot-") && $0.lowercased().hasSuffix(".png") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Adds each found recording that isn't indexed, matching folders by resolved path.
    private func merge(_ found: [RecordingFolder]) {
        append(Self.unindexed(found, indexed: recordings.map(\.folder)))
    }

    private func append(_ found: [RecordingFolder]) {
        recordings += found.map { IndexedRecording(folder: $0.folder, metadata: $0.structure) }
        sort()
    }

    /// The IDs of the entries for `folder`: those with its path as spelled, or else those with its
    /// resolved path (`ProductPaths.canonicalPath`), so most lookups stat nothing on the main actor.
    private func entries(for folder: URL) -> [UUID] {
        let path = folder.standardizedFileURL.path
        let spelled = recordings.filter { $0.folder.path == path }
        if !spelled.isEmpty { return spelled.map(\.id) }
        let resolved = ProductPaths.canonicalPath(folder)
        return recordings.filter { ProductPaths.canonicalPath($0.folder) == resolved }.map(\.id)
    }

    private func upsert(_ folder: URL, _ structure: RecordingStructure) {
        if let id = entries(for: folder).first, let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index] = recordings[index].updated(with: structure)
        } else {
            recordings.append(IndexedRecording(folder: folder, metadata: structure))
        }
        sort()
        refresh()
        save()
    }

    private func sort() {
        recordings.sort(by: IndexedRecording.newestFirst)
    }

    private func isPresent(_ recording: IndexedRecording) -> Bool {
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: recording.folder.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        return recording.videoURLs.contains { fileManager.fileExists(atPath: $0.path) }
    }
}

/// A recording's folder in a folder the index looks in: its `meta.json`'s structure, and its path resolved
/// (`ProductPaths.canonicalPath`) to match it to an entry however either is spelled.
private struct RecordingFolder: Sendable {
    let folder: URL
    let structure: RecordingStructure
    let resolvedPath: String
}

extension RecordingStructure {
    /// What the recorder reported, for a recording whose `meta.json` couldn't be read.
    init(_ capture: ScreencastCapture, startedAt: Date) {
        self.init(
            startedAt: startedAt,
            target: nil,
            duration: capture.duration,
            displayCount: capture.videos.count,
            videos: capture.videos.map { Video(file: $0.file.lastPathComponent, mixdown: $0.mixdown?.lastPathComponent) }
        )
    }
}
