import AppKit
import CryptoKit
import Foundation
import Observation

struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }

    let id: UUID
    let text: String
    let capturedAt: Date
    let kind: Kind
    let mediaPath: String?
    let mediaPasteboardType: String?
    let fingerprint: String?
    /// A copied image file's own file; a screenshot's file in ScreenGrabs' history, which `mediaPath`
    /// names too (#605). Nil for image data copied from apps.
    let sourcePath: String?
    /// True only for files macOS marked as screen captures (ingested by ScreenGrabs).
    let isScreenCapture: Bool
    /// The app it was copied from; nil for screenshots, other devices, and items saved before this existed.
    let sourceApp: ClipboardSourceApp?
    /// The website's domain (the page address's host only), when the browser said which page it was.
    let sourceDomain: String?
    /// True for a screenshot cleared or deleted from the Clipboard tab, or one that was never copied
    /// there, such as one taken while Clipboard History was off. It stays, with its file, for the
    /// ScreenGrabs tab. Copying it again shows it in the Clipboard tab again. History saved before
    /// this existed decodes it as false.
    var isHiddenFromClipboardTab: Bool

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        kind: Kind = .text,
        mediaPath: String? = nil,
        mediaPasteboardType: String? = nil,
        fingerprint: String? = nil,
        sourcePath: String? = nil,
        isScreenCapture: Bool = false,
        sourceApp: ClipboardSourceApp? = nil,
        sourceDomain: String? = nil,
        isHiddenFromClipboardTab: Bool = false
    ) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.kind = kind
        self.mediaPath = mediaPath
        self.mediaPasteboardType = mediaPasteboardType
        self.fingerprint = fingerprint
        self.sourcePath = sourcePath
        self.isScreenCapture = isScreenCapture
        self.sourceApp = sourceApp
        self.sourceDomain = sourceDomain
        self.isHiddenFromClipboardTab = isHiddenFromClipboardTab
    }

    var isScreenshot: Bool { kind == .image && isScreenCapture }
    var kindLabel: String { kind == .text ? "Text" : (isScreenshot ? "Screenshot" : "Image") }
    var displayText: String {
        switch kind {
        case .text: text
        case .image: sourceURL?.deletingPathExtension().lastPathComponent ?? "Image"
        }
    }
    var searchableText: String { kind == .image ? "\(kindLabel) \(displayText) \(mediaPasteboardType ?? "")" : text }

    /// Whether a Clipboard tab search matches this item: its content anywhere, its source app's name
    /// from the start of a word, or its source domain from the start of a label other than the last
    /// one or `www`. So `com` or `www` doesn't match everything copied from the web.
    func matches(_ query: String) -> Bool {
        searchableText.localizedCaseInsensitiveContains(query)
            || sourceApp.map { ClipboardSourceSearch.matchesWordStart(query, in: $0.name) } == true
            || sourceDomain.map { ClipboardSourceSearch.matchesLabelStart(query, in: $0) } == true
    }
    var sourceURL: URL? { sourcePath.map { URL(fileURLWithPath: $0) } }
    var imageURL: URL? { mediaPath.map { URL(fileURLWithPath: $0) } }
    var contentKey: String { fingerprint ?? "text:\(text)" }

    private enum CodingKeys: String, CodingKey {
        case id, text, capturedAt, kind, mediaPath, mediaPasteboardType, fingerprint, sourcePath, isScreenCapture, sourceApp, sourceDomain
        case isHiddenFromClipboardTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        mediaPath = try container.decodeIfPresent(String.self, forKey: .mediaPath)
        mediaPasteboardType = try container.decodeIfPresent(String.self, forKey: .mediaPasteboardType)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        // Items written before copied files were supported only had a source when they were screenshots.
        isScreenCapture = try container.decodeIfPresent(Bool.self, forKey: .isScreenCapture) ?? (sourcePath != nil)
        sourceApp = try container.decodeIfPresent(ClipboardSourceApp.self, forKey: .sourceApp)
        sourceDomain = try container.decodeIfPresent(String.self, forKey: .sourceDomain)
        isHiddenFromClipboardTab = try container.decodeIfPresent(Bool.self, forKey: .isHiddenFromClipboardTab) ?? false
    }
}

@MainActor
@Observable
class ClipboardHistoryService {
    /// In the Keybumps folder's `clipboard_history/`, with each copied image's copy in `media/`
    /// (ADR 0013). A screenshot has no copy there: its item names its file in ScreenGrabs' history,
    /// `screengrabs/screenshots/` (`screenshotsFolder`, #605).
    nonisolated static let fileName = "clipboard-history.json"
    /// How many items that aren't screenshots are kept, and the most the Clipboard tab lists.
    /// Screenshots aren't counted and are never dropped: the ScreenGrabs tab lists every one in
    /// ScreenGrabs' history (#605). A build before #605 keeps only the newest 50 screenshots (one
    /// before #493, the newest `capacity` items of any kind) and drops the rest on its next save. It
    /// removes files only in `media/`, so theirs stay in the history, and this build lists them
    /// again (`adoptScreenshots()`).
    nonisolated static let capacity = 50
    nonisolated static let maximumImageBytes = 50 * 1_024 * 1_024

    /// Every item, newest first, including screenshots hidden from the Clipboard tab.
    private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount: Int
    /// When a pasteboard change was last seen, including suppressed changes and restores.
    private var lastChangeSeenAt: Date?
    private var suppressedChangeCount: Int?
    /// Where the index and media are kept; read by the unit-test isolation guard.
    let storageURL: URL
    private let pasteboard: NSPasteboard
    let mediaDirectoryURL: URL
    /// ScreenGrabs' history of screenshots, the Keybumps folder's `screengrabs/screenshots/` (#605):
    /// every screenshot's file, which its item names. The ScreenGrabs hotkeys save there, and a
    /// screenshot macOS saves is copied there.
    let screenshotsFolder: URL
    private let fileManager: FileManager
    private let sourceTracker: ClipboardSourceTracker
    private let trash: (URL) throws -> Void

    /// - Parameter screenshotsFolder: ScreenGrabs' history of screenshots: the Keybumps folder's by
    ///   default, or, for a history given its own `storageURL`, a `screenshots` folder beside it, so
    ///   a test's history keeps its screenshots to itself.
    /// - Parameter trash: Moves a screenshot's file to the Trash when it's deleted from the
    ///   ScreenGrabs tab (`moveToTrash`).
    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil,
        pasteboard: NSPasteboard = .keybumps,
        mediaDirectoryURL: URL? = nil,
        screenshotsFolder: URL? = nil,
        sourceApps: ClipboardSourceAppReader = .system,
        trash: @escaping (URL) throws -> Void = ClipboardHistoryService.moveToTrash
    ) {
        let paths = ProductPaths.keybumps(fileManager: fileManager)
        self.fileManager = fileManager
        sourceTracker = ClipboardSourceTracker(reader: sourceApps)
        self.storageURL = storageURL ?? paths.inUse(.clipboardHistory)
        self.mediaDirectoryURL = mediaDirectoryURL ?? paths.inUse(.clipboardMedia)
        self.screenshotsFolder = screenshotsFolder
            ?? storageURL.map { $0.deletingLastPathComponent().appendingPathComponent("screenshots", isDirectory: true) }
            ?? paths.screengrabsScreenshots
        self.trash = trash
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        // Only the folders this history uses, so injected locations never create the default one.
        try? fileManager.createDirectory(at: self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.mediaDirectoryURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            // History saved under a limit is within it, so it loads unchanged.
            entries = Self.splitAtCapacity(decoded).kept
        }
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        suppressedChangeCount = nil
        sourceTracker.reset()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// What the Clipboard tab lists: the newest `capacity` items, leaving out screenshots cleared
    /// or deleted there.
    var clipboardTabEntries: [ClipboardEntry] { clipboardTabEntries(matching: { _ in true }) }

    /// What the Clipboard tab lists for its filter and search, which `matches` applies: the newest
    /// `capacity` items that match. Matching comes before the limit, so every stored copy can still
    /// be found, filtered, and deleted one at a time.
    func clipboardTabEntries(matching matches: (ClipboardEntry) -> Bool) -> [ClipboardEntry] {
        Array(entries.filter { !$0.isHiddenFromClipboardTab && matches($0) }.prefix(Self.capacity))
    }

    /// Removes an item from both tabs, with its media copy. A screenshot's file in ScreenGrabs'
    /// history goes to the Trash; if it can't, the item stays and this returns false. Its copy where
    /// macOS saves screenshots is the person's, and stays.
    @discardableResult
    func delete(_ entry: ClipboardEntry) -> Bool {
        guard removeFiles(of: entry) else { return false }
        entries.removeAll { $0.id == entry.id }
        persist()
        return true
    }

    /// The Clipboard tab's Delete: hides a screenshot there, keeping it for the Screenshots tab,
    /// and deletes anything else.
    func removeFromClipboardTab(_ entry: ClipboardEntry) {
        guard entry.isScreenshot else {
            delete(entry)
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isHiddenFromClipboardTab = true
        persist()
    }

    /// The Clipboard tab's Clear All: deletes every item that isn't a screenshot, with its media
    /// copy, and hides screenshots there, keeping them and their files for the Screenshots tab.
    func clearClipboardTab() {
        entries.filter { !$0.isScreenshot }.forEach { removeFiles(of: $0) }
        entries.removeAll { !$0.isScreenshot }
        for index in entries.indices { entries[index].isHiddenFromClipboardTab = true }
        persist()
    }

    /// The Screenshots tab's Clear All: removes screen-capture items from both tabs, moving their
    /// files in ScreenGrabs' history to the Trash (`delete`). One whose file can't be moved stays.
    /// Their copies where macOS saves screenshots stay.
    func clearScreenshots() {
        let removed = Set(entries.filter { $0.isScreenshot && removeFiles(of: $0) }.map(\.id))
        entries.removeAll { removed.contains($0.id) }
        persist()
    }

    /// Puts `entry` back on the pasteboard. A restore the user asked for counts as a copy for
    /// `pasteboardChanged(since:)`; ScreenGrabs' automatic copy passes `countsAsCopy: false`,
    /// so one screenshot's copy never stops a newer screenshot from being copied. An image whose
    /// stored copy can't be read returns false and leaves the pasteboard as it was.
    @discardableResult
    func restore(_ entry: ClipboardEntry, countsAsCopy: Bool = true) -> Bool {
        let restored: Bool
        switch entry.kind {
        case .text:
            pasteboard.clearContents()
            restored = pasteboard.setString(entry.text, forType: .string)
        case .image:
            // Read the stored copy before clearing, so a missing or empty file never empties the clipboard.
            guard let imageURL = entry.imageURL,
                  let typeName = entry.mediaPasteboardType,
                  let data = try? Data(contentsOf: imageURL), !data.isEmpty else { return false }
            pasteboard.clearContents()
            restored = pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeName))
        }
        guard restored else { return false }
        lastChangeCount = pasteboard.changeCount
        if countsAsCopy {
            lastChangeSeenAt = Date()
            // Copying a screenshot from the Screenshots tab puts it back in the Clipboard tab.
            showInClipboardTab(entry.id)
        }
        suppressedChangeCount = nil
        return true
    }

    /// Adds an image file as an image item without touching the pasteboard: a screen capture as a
    /// screenshot (`addScreenshot(at:)`), any other as a copied image file.
    @discardableResult
    func ingestImageFile(
        at url: URL,
        isScreenCapture: Bool = true,
        sourceApp: ClipboardSourceApp? = nil,
        sourceDomain: String? = nil
    ) -> Bool {
        if isScreenCapture { return addScreenshot(at: url) != nil }
        guard let payload = ClipboardImagePayload.read(fileAt: url) else { return false }
        return ingestImage(payload, sourcePath: url.path, sourceApp: sourceApp, sourceDomain: sourceDomain)
    }

    /// Adds a screenshot, newest, without touching the pasteboard, and returns its item (#605). Its
    /// file is kept in ScreenGrabs' history (`screenshotsFolder`): a ScreenGrabs hotkey's is there
    /// already, and one saved anywhere else, such as by macOS's own screenshot shortcuts on the
    /// Desktop, is copied there (`ScreengrabFiles`), so deleting or moving that one never touches
    /// the history. The item names the history's file; nothing goes in `media/`. Every screenshot
    /// is its own item, even one that looks the same as another. Nil when it adds nothing: the file
    /// isn't an image Clipboard History keeps, can't be copied, or is listed already.
    @discardableResult
    func addScreenshot(at url: URL) -> ClipboardEntry? {
        guard let payload = ClipboardImagePayload.read(fileAt: url), !lists(url),
              let kept = keepInHistory(url), !lists(kept) else { return nil }
        let entry = ClipboardEntry(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            kind: .image,
            mediaPath: kept.path,
            mediaPasteboardType: payload.type.rawValue,
            fingerprint: Self.fingerprint(of: payload.data),
            sourcePath: kept.path,
            isScreenCapture: true
        )
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    /// Adds a screenshot an earlier build kept elsewhere, for the recordings index's one-time import
    /// of a QA build's Screencast screenshots (#492). Its file is copied into ScreenGrabs' history,
    /// as `addScreenshot(at:)` does. Unlike that, it skips content already kept anywhere in the
    /// history, keeps `capturedAt` and places the item by it rather than first, keeps it out of the
    /// Clipboard tab, and records no source app. False when it adds nothing.
    @discardableResult
    func importScreenshot(at url: URL, capturedAt: Date) -> Bool {
        guard let payload = ClipboardImagePayload.read(fileAt: url) else { return false }
        let fingerprint = Self.fingerprint(of: payload.data)
        guard !entries.contains(where: { $0.contentKey == fingerprint }),
              let kept = keepInHistory(url), !lists(kept) else { return false }
        insertByDate(ClipboardEntry(
            id: UUID(),
            text: "",
            capturedAt: capturedAt,
            kind: .image,
            mediaPath: kept.path,
            mediaPasteboardType: payload.type.rawValue,
            fingerprint: fingerprint,
            sourcePath: kept.path,
            isScreenCapture: true,
            isHiddenFromClipboardTab: true
        ))
        persist()
        return true
    }

    /// Lists every screenshot in ScreenGrabs' history that no item names yet, by when its file was
    /// made, kept out of the Clipboard tab (#605): one a hotkey took while Clipboard History was off
    /// or not running, or one an older build dropped past its limit. A file that looks the same as
    /// a screenshot whose file is still outside the history is left for the one-time move
    /// (`ScreengrabsHistoryMove`), which gives that item this file. Hidden files, such as a copy
    /// being written, and files that aren't images Clipboard History keeps are left alone. Returns
    /// how many it adds.
    @discardableResult
    func adoptScreenshots() -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: screenshotsFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        // The names in the history that items name, however their paths are spelled.
        let listed = Set(entries.flatMap { [$0.imageURL, $0.sourceURL] }.compactMap { $0 }.filter { isInHistory($0) }.map(\.lastPathComponent))
        let waiting = Set(entries.filter { $0.isScreenshot && !isInHistory($0.imageURL) }.compactMap(\.fingerprint))
        var added = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !listed.contains(file.lastPathComponent) && ClipboardImagePayload.isSupportedImageFile(file) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let payload = ClipboardImagePayload.read(fileAt: file) else { continue }
            let fingerprint = Self.fingerprint(of: payload.data)
            guard !waiting.contains(fingerprint) else { continue }
            // Spelled as the history's folder is, as every other item names it.
            let named = screenshotsFolder.appendingPathComponent(file.lastPathComponent)
            insertByDate(ClipboardEntry(
                id: UUID(),
                text: "",
                capturedAt: values.creationDate ?? values.contentModificationDate ?? Date(),
                kind: .image,
                mediaPath: named.path,
                mediaPasteboardType: payload.type.rawValue,
                fingerprint: fingerprint,
                sourcePath: named.path,
                isScreenCapture: true,
                isHiddenFromClipboardTab: true
            ))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    /// Whether the pasteboard changed at or after `date`, counting a copy the next poll would
    /// have caught (which this records first, so it isn't lost). While Clipboard History is
    /// stopped it never reads the pasteboard and reports only changes it saw while running.
    func pasteboardChanged(since date: Date) -> Bool {
        if timer != nil { poll() }
        return lastChangeSeenAt.map { $0 >= date } ?? false
    }

    func ingestForTesting(_ text: String) { ingestText(text) }
    func pollForTesting() { poll() }
    func suppressCurrentChange() { suppressedChangeCount = pasteboard.changeCount }

    private func poll() {
        sourceTracker.sample()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        lastChangeSeenAt = Date()
        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return
        }
        suppressedChangeCount = nil
        let sourceApp = sourceTracker.sourceApp(of: pasteboard)
        let sourceDomain = ClipboardSourceDomain.read(from: pasteboard)

        // Finder file copies also carry a TIFF of the file's icon; never store that.
        // Keep the first copied image file's real contents and ignore other files.
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            if let imageFile = fileURLs.first(where: ClipboardImagePayload.isSupportedImageFile) {
                ingestImageFile(at: imageFile, isScreenCapture: false, sourceApp: sourceApp, sourceDomain: sourceDomain)
            }
            return
        }

        if let image = ClipboardImagePayload.read(from: pasteboard) {
            ingestImage(image, sourceApp: sourceApp, sourceDomain: sourceDomain)
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        ingestText(text, sourceApp: sourceApp, sourceDomain: sourceDomain)
    }

    private func ingestText(_ text: String, sourceApp: ClipboardSourceApp? = nil, sourceDomain: String? = nil) {
        insert(ClipboardEntry(
            id: UUID(),
            text: text,
            capturedAt: Date(),
            fingerprint: "text:\(text)",
            sourceApp: sourceApp,
            sourceDomain: sourceDomain
        ))
    }

    /// Adds an image copied from an app, or a copied image file (`sourcePath`). Screenshots come
    /// through `addScreenshot(at:)`.
    @discardableResult
    private func ingestImage(
        _ payload: ClipboardImagePayload,
        sourcePath: String? = nil,
        sourceApp: ClipboardSourceApp? = nil,
        sourceDomain: String? = nil
    ) -> Bool {
        guard payload.data.count <= Self.maximumImageBytes else { return false }
        let fingerprint = Self.fingerprint(of: payload.data)
        guard !repeatsNewest(fingerprint) else { return false }
        // A copy of a screenshot's bytes, such as its file copied in Finder, moves the screenshot
        // up instead of replacing it with an image item the ScreenGrabs tab leaves out.
        if let screenshot = entries.first(where: { $0.isScreenshot && $0.fingerprint == fingerprint }) {
            moveToTop(screenshot.id)
            return true
        }

        let id = UUID()
        let mediaURL = mediaDirectoryURL.appendingPathComponent("\(id.uuidString).\(payload.fileExtension)")
        do {
            try payload.data.write(to: mediaURL, options: .atomic)
            insert(ClipboardEntry(
                id: id,
                text: "",
                capturedAt: Date(),
                kind: .image,
                mediaPath: mediaURL.path,
                mediaPasteboardType: payload.type.rawValue,
                fingerprint: fingerprint,
                sourcePath: sourcePath,
                sourceApp: sourceApp,
                sourceDomain: sourceDomain
            ))
            return true
        } catch {
            try? fileManager.removeItem(at: mediaURL)
            return false
        }
    }

    private static func fingerprint(of imageData: Data) -> String {
        "image:" + SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a copy that isn't a screenshot, newest, in place of any item with the same content, and
    /// drops the oldest past `capacity`.
    private func insert(_ entry: ClipboardEntry) {
        guard !repeatsNewest(entry.contentKey) else { return }
        let duplicates = entries.filter { !$0.isScreenshot && $0.contentKey == entry.contentKey }
        duplicates.forEach { removeFiles(of: $0) }
        entries.removeAll { !$0.isScreenshot && $0.contentKey == entry.contentKey }
        entries.insert(entry, at: 0)
        let (kept, dropped) = Self.splitAtCapacity(entries)
        dropped.forEach { removeFiles(of: $0) }
        entries = kept
        persist()
    }

    /// Places an item by `capturedAt`, after any taken at the same time.
    private func insertByDate(_ entry: ClipboardEntry) {
        entries.insert(entry, at: entries.firstIndex { $0.capturedAt < entry.capturedAt } ?? entries.endIndex)
    }

    /// Splits items, newest first, into those kept and the older ones past `capacity`, keeping
    /// their order. Only items that aren't screenshots count toward it; every screenshot is kept.
    private static func splitAtCapacity(_ items: [ClipboardEntry]) -> (kept: [ClipboardEntry], dropped: [ClipboardEntry]) {
        var others = 0
        var kept: [ClipboardEntry] = []
        var dropped: [ClipboardEntry] = []
        for item in items {
            if item.isScreenshot {
                kept.append(item)
                continue
            }
            others += 1
            if others <= capacity { kept.append(item) } else { dropped.append(item) }
        }
        return (kept, dropped)
    }

    /// Whether an item names this file already.
    private func lists(_ file: URL) -> Bool {
        let path = Self.standardizedPath(file.path)
        return entries.contains { entry in
            [entry.mediaPath, entry.sourcePath].contains { $0.map(Self.standardizedPath) == path }
        }
    }

    /// Where `file` is in ScreenGrabs' history: `file` itself when it's there already, else a copy
    /// under its own name, or the first free name after it (`ScreengrabFiles`). A file of that name
    /// with the same contents, such as the history's own file this one was copied from, is the
    /// one. Nil when it can't be copied.
    private func keepInHistory(_ file: URL) -> URL? {
        // Spelled as the history's folder is, so `lists(_:)` finds it however the caller spelled it.
        if isInHistory(file) { return screenshotsFolder.appendingPathComponent(file.lastPathComponent) }
        return ScreengrabFiles.copy(
            file,
            into: screenshotsFolder,
            naming: ScreengrabFiles.fileNames(like: file),
            reusingIdentical: true,
            fileManager: fileManager
        )
    }

    /// Whether `file` is directly in ScreenGrabs' history.
    private func isInHistory(_ file: URL?) -> Bool {
        file.map { ScreengrabFiles.isDirectly($0, in: screenshotsFolder) } ?? false
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether this content repeats the newest item. That adds nothing, but a screenshot hidden
    /// from the Clipboard tab shows there again.
    private func repeatsNewest(_ contentKey: String) -> Bool {
        guard let newest = entries.first, newest.contentKey == contentKey else { return false }
        showInClipboardTab(newest.id)
        return true
    }

    /// Moves an item to the top as a new copy would, showing it in the Clipboard tab again.
    private func moveToTop(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.isHiddenFromClipboardTab = false
        entries.insert(entry, at: 0)
        persist()
    }

    private func showInClipboardTab(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isHiddenFromClipboardTab else { return }
        entries[index].isHiddenFromClipboardTab = false
        persist()
    }

    /// Removes what an item keeps: its copy in `media/`, or a screenshot's file in ScreenGrabs'
    /// history, which goes to the Trash. Nothing else is touched, such as a copied image's own file.
    /// False when a screenshot's file is still there.
    @discardableResult
    private func removeFiles(of entry: ClipboardEntry) -> Bool {
        guard let imageURL = entry.imageURL else { return true }
        if entry.isScreenshot, isInHistory(imageURL) {
            guard fileManager.fileExists(atPath: imageURL.path) else { return true }
            do {
                try trash(imageURL)
                return true
            } catch {
                return false
            }
        }
        let mediaRoot = mediaDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = imageURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.hasPrefix(mediaRoot + "/") else { return true }
        try? fileManager.removeItem(at: imageURL)
        return true
    }

    /// The app's Trash for a screenshot's file: the Finder's; the sandbox's `Trash` folder in UI test
    /// mode; and under the unit-test host this run's own (`UnitTestHost.dataDirectory`), so no test
    /// reaches the real Trash.
    nonisolated static func moveToTrash(_ file: URL) throws {
        let ownTrash = ProductPaths.sandboxRoot ?? (UnitTestHost.isActive ? UnitTestHost.dataDirectory : nil)
        guard let ownTrash else {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            return
        }
        let trash = ownTrash.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

private struct ClipboardImagePayload {
    let data: Data
    let type: NSPasteboard.PasteboardType
    let fileExtension: String

    static func read(from pasteboard: NSPasteboard) -> ClipboardImagePayload? {
        for candidate in candidates {
            if let data = pasteboard.data(forType: candidate.type), !data.isEmpty {
                return ClipboardImagePayload(data: data, type: candidate.type, fileExtension: candidate.fileExtension)
            }
        }
        return nil
    }

    static func isSupportedImageFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return candidates.contains { $0.fileExtensions.contains(fileExtension) }
    }

    static func read(fileAt url: URL) -> ClipboardImagePayload? {
        let fileExtension = url.pathExtension.lowercased()
        guard let candidate = candidates.first(where: { $0.fileExtensions.contains(fileExtension) }),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > 0, size <= ClipboardHistoryService.maximumImageBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return ClipboardImagePayload(data: data, type: candidate.type, fileExtension: candidate.fileExtension)
    }

    private static let candidates: [(type: NSPasteboard.PasteboardType, fileExtension: String, fileExtensions: Set<String>)] = [
        (.png, "png", ["png"]),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg", ["jpg", "jpeg"]),
        (NSPasteboard.PasteboardType("public.heic"), "heic", ["heic"]),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif", ["gif"]),
        (.tiff, "tiff", ["tif", "tiff"])
    ]
}

