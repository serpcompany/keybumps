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

/// ScreenGrabs' recordings index (#492, ADR 0010 decision 6): every recording Keybumps keeps,
/// wherever it's saved, so the ⌘3 tab lists them (#494). It's `recordings.json` in Application
/// Support (`RecordingIndexFile`, written 0600 by `PrivateFile`), holding each recording's folder
/// and the structure of its `meta.json`, never its review, and it's never logged: logs say only
/// counts and categories.
///
/// - **Added** when the recorder finishes writing (`add`), so a crash before Save still leaves the
///   recording listed. **Read again** when the recording window saves, copies, or can't save it,
///   and **removed** when it discards it (`reviewEnded`).
/// - **Moved or deleted:** a recording whose folder, or every video in it, is gone is marked
///   `isMissing` each time the index looks (`load`, `refresh`, `recordingsNewestFirst`), and stays
///   listed until it's removed; it's unmarked if it comes back.
/// - **The import** runs once (`RecordingImportMemory`), the first time the index loads without
///   having run it: each recording in the recordings folder (`ProductPaths.captures`) is indexed
///   where it is, and each screenshot a QA build's Screencast saved there before #487 goes to the
///   ⌘3 tab through `ClipboardHistoryService.importScreenshot(at:capturedAt:)`. Files are never
///   moved or changed.
/// - **A missing or corrupt file** after the import is rebuilt from the recordings folder's
///   recordings, without importing screenshots again. A corrupt file is first kept beside it as
///   `recordings.unreadable.json`; entries that can't be decoded are skipped and the rest kept.
/// - **A file this build can't read or write over** (one that exists but can't be read, or a later
///   build's version) makes the index read-only: it lists what it can and never writes the file.
/// - **Rollback:** a build before #492 never reads or writes `recordings.json` and leaves it as it
///   was; the recordings it saves stay in their folders, and aren't in the index (the import
///   already ran).
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
    /// Where the import and a rebuild look: `ProductPaths.captures`.
    @ObservationIgnored let capturesFolder: URL
    @ObservationIgnored let posterFrames: RecordingPosterFrames
    @ObservationIgnored private let importMemory: RecordingImportMemory
    @ObservationIgnored private weak var screenshots: ClipboardHistoryService?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var posterTasks: [UUID: Task<URL?, Never>] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    init(
        storageURL: URL,
        capturesFolder: URL,
        posterFrames: RecordingPosterFrames,
        importMemory: RecordingImportMemory,
        screenshots: ClipboardHistoryService?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.capturesFolder = capturesFolder
        self.posterFrames = posterFrames
        self.importMemory = importMemory
        self.screenshots = screenshots
        self.fileManager = fileManager
        self.now = now
    }

    /// The app's: in Application Support, Caches, and the recordings folder, through `ProductPaths`,
    /// so the UI-test sandbox and the unit-test host keep theirs in their own folders.
    static func makeDefault(importMemory: RecordingImportMemory, screenshots: ClipboardHistoryService?) -> RecordingLibrary {
        let paths = ProductPaths.keybumps()
        return RecordingLibrary(
            storageURL: paths.applicationSupport.appendingPathComponent(RecordingIndexFile.fileName),
            capturesFolder: paths.captures,
            posterFrames: RecordingPosterFrames(folder: RecordingPosterFrames.defaultFolder),
            importMemory: importMemory,
            screenshots: screenshots
        )
    }

    var unreadableCopyURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("recordings.unreadable.json")
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
    /// missing or corrupt file. Later calls do nothing.
    func load() {
        guard state == .notLoaded else { return }
        state = .ready
        let source: String
        switch readFile() {
        case .missing:
            source = startOver()
        case .unreadable:
            state = .readOnly
            recordings = videoFolders(in: scanRecordingsFolder()).map { IndexedRecording(folder: $0.folder, metadata: $0.structure) }
            source = "unreadable"
        case .contents(.newer(let read)):
            state = .readOnly
            recordings = read
            source = "newer"
        case .contents(.corrupt):
            setAsideUnreadable()
            source = "corrupt+" + startOver()
        case .contents(.current(let read, let skipped)):
            recordings = read
            source = skipped > 0 ? "partial" : "file"
            if skipped > 0 { setAsideUnreadable() }
            if !importMemory.isDone {
                runImport()
            } else if skipped > 0 {
                merge(videoFolders(in: scanRecordingsFolder()))
                save()
            }
        }
        sort()
        refresh()
        let missing = recordings.filter(\.isMissing).count
        logger.info("recordings index loaded source=\(source, privacy: .public) count=\(self.recordings.count, privacy: .public) missing=\(missing, privacy: .public)")
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

    /// The recorder finished writing: the recording is indexed from its `meta.json` at once, or from
    /// what the recorder reported if that couldn't be read.
    func add(_ capture: ScreencastCapture) {
        load()
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
        let path = folder.standardizedFileURL.path
        let removed = recordings.filter { $0.folder.path == path }
        guard !removed.isEmpty else { return }
        for recording in removed {
            posterTasks[recording.id]?.cancel()
            posterFrames.remove(for: recording)
        }
        recordings.removeAll { $0.folder.path == path }
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
        merge(videoFolders(in: scanRecordingsFolder()))
        save()
        return "rebuilt"
    }

    /// The one-time import: recordings into the index, and a QA build's Screencast screenshots into
    /// the ⌘3 tab at their own dates. Nothing is moved or changed.
    private func runImport() {
        let found = scanRecordingsFolder()
        let videos = videoFolders(in: found)
        merge(videos)
        var screenshotCount = 0
        if let screenshots {
            for (folder, structure) in found where structure.isScreenshot {
                for file in screenshotFiles(in: folder)
                where screenshots.importScreenshot(at: file, capturedAt: structure.startedAt) {
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
            try PrivateFile.write(RecordingIndexFile(recordings: recordings).encoded(), to: storageURL, fileManager: fileManager)
            return true
        } catch {
            logger.error("recordings index not written code=\((error as NSError).code, privacy: .public)")
            return false
        }
    }

    /// Keeps a corrupt index beside it, unread, before it's written over, replacing an older copy.
    private func setAsideUnreadable() {
        if rename(storageURL.path, unreadableCopyURL.path) != 0 {
            logger.error("recordings index not set aside errno=\(errno, privacy: .public)")
        }
    }

    // MARK: The recordings folder

    /// Each folder in the recordings folder with a `meta.json` this build understands.
    private func scanRecordingsFolder() -> [(folder: URL, structure: RecordingStructure)] {
        let items = (try? fileManager.contentsOfDirectory(
            at: capturesFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in RecordingStructure.read(in: folder).map { (folder, $0) } }
    }

    private func videoFolders(in found: [(folder: URL, structure: RecordingStructure)]) -> [(folder: URL, structure: RecordingStructure)] {
        found.filter { $0.structure.isVideo }
    }

    /// A Screencast screenshot folder's PNGs: `screenshot-1.png`, and any `screenshot-1 (edited).png`.
    private func screenshotFiles(in folder: URL) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix("screenshot-") && $0.lowercased().hasSuffix(".png") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Adds each folder not indexed yet.
    private func merge(_ found: [(folder: URL, structure: RecordingStructure)]) {
        let indexed = Set(recordings.map(\.folder.path))
        let added = found
            .filter { !indexed.contains($0.folder.standardizedFileURL.path) }
            .map { IndexedRecording(folder: $0.folder, metadata: $0.structure) }
        recordings += added
        sort()
    }

    private func upsert(_ folder: URL, _ structure: RecordingStructure) {
        let path = folder.standardizedFileURL.path
        if let index = recordings.firstIndex(where: { $0.folder.path == path }) {
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
