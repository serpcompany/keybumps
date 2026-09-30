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
    /// Original file for screenshots and copied image files; nil for image data copied from apps.
    let sourcePath: String?
    /// True only for files macOS marked as screen captures (ingested by Screenshot Tools).
    let isScreenCapture: Bool
    /// The app it was copied from; nil for screenshots, other devices, and items saved before this existed.
    let sourceApp: ClipboardSourceApp?
    /// The website's domain (the page address's host only), when the browser said which page it was.
    let sourceDomain: String?
    /// True for a screenshot cleared or deleted from the Clipboard tab. It stays, with its media, for
    /// the Screenshots tab and still counts toward the capacity. Copying it again shows it in the
    /// Clipboard tab again. History saved before this existed decodes it as false.
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
    private let fileManager: FileManager
    private let sourceTracker: ClipboardSourceTracker

    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil,
        pasteboard: NSPasteboard = .keybumps,
        mediaDirectoryURL: URL? = nil,
        sourceApps: ClipboardSourceAppReader = .system
    ) {
        let directory = ProductPaths.keybumps(fileManager: fileManager).applicationSupport
        self.fileManager = fileManager
        sourceTracker = ClipboardSourceTracker(reader: sourceApps)
        self.storageURL = storageURL ?? directory.appendingPathComponent("clipboard-history.json")
        self.mediaDirectoryURL = mediaDirectoryURL ?? directory.appendingPathComponent("clipboard-media", isDirectory: true)
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        // Only the folders this history uses, so injected locations never create the default one.
        try? fileManager.createDirectory(at: self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.mediaDirectoryURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = Array(decoded.prefix(Self.capacity))
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

    /// What the Clipboard tab lists: every item except screenshots cleared or deleted there.
    var clipboardTabEntries: [ClipboardEntry] { entries.filter { !$0.isHiddenFromClipboardTab } }

    /// Removes an item from both tabs, with its media copy.
    func delete(_ entry: ClipboardEntry) {
        removeMedia(for: entry)
        entries.removeAll { $0.id == entry.id }
        persist()
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
    /// copy, and hides screenshots there, keeping them and their media for the Screenshots tab.
    func clearClipboardTab() {
        entries.filter { !$0.isScreenshot }.forEach(removeMedia)
        entries.removeAll { !$0.isScreenshot }
        for index in entries.indices { entries[index].isHiddenFromClipboardTab = true }
        persist()
    }

    /// The Screenshots tab's Clear All: removes screen-capture items from both tabs, with their
    /// media copies. Original files are never touched.
    func clearScreenshots() {
        entries.filter(\.isScreenshot).forEach(removeMedia)
        entries.removeAll(where: \.isScreenshot)
        persist()
    }

    /// Puts `entry` back on the pasteboard. A restore the user asked for counts as a copy for
    /// `pasteboardChanged(since:)`; Screenshot Tools' automatic copy passes `countsAsCopy: false`,
    /// so one screenshot's copy never stops a newer screenshot from being copied.
    @discardableResult
    func restore(_ entry: ClipboardEntry, countsAsCopy: Bool = true) -> Bool {
        pasteboard.clearContents()
        let restored: Bool
        switch entry.kind {
        case .text:
            restored = pasteboard.setString(entry.text, forType: .string)
        case .image:
            guard let imageURL = entry.imageURL,
                  let typeName = entry.mediaPasteboardType,
                  let data = try? Data(contentsOf: imageURL) else { return false }
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

    /// Adds a screenshot file as an image item without touching the pasteboard.
    @discardableResult
    func ingestImageFile(
        at url: URL,
        isScreenCapture: Bool = true,
        sourceApp: ClipboardSourceApp? = nil,
        sourceDomain: String? = nil
    ) -> Bool {
        guard let payload = ClipboardImagePayload.read(fileAt: url) else { return false }
        return ingestImage(
            payload,
            sourcePath: url.path,
            isScreenCapture: isScreenCapture,
            sourceApp: sourceApp,
            sourceDomain: sourceDomain
        )
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

    @discardableResult
    private func ingestImage(
        _ payload: ClipboardImagePayload,
        sourcePath: String? = nil,
        isScreenCapture: Bool = false,
        sourceApp: ClipboardSourceApp? = nil,
        sourceDomain: String? = nil
    ) -> Bool {
        guard payload.data.count <= Self.maximumImageBytes else { return false }
        let fingerprint = "image:" + SHA256.hash(data: payload.data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard !repeatsNewest(fingerprint) else { return false }

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
                isScreenCapture: isScreenCapture,
                sourceApp: sourceApp,
                sourceDomain: sourceDomain
            ))
            return true
        } catch {
            try? fileManager.removeItem(at: mediaURL)
            return false
        }
    }

    private func insert(_ entry: ClipboardEntry) {
        guard !repeatsNewest(entry.contentKey) else { return }
        let duplicates = entries.filter { $0.contentKey == entry.contentKey }
        duplicates.forEach(removeMedia)
        entries.removeAll { $0.contentKey == entry.contentKey }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            entries.suffix(from: Self.capacity).forEach(removeMedia)
            entries.removeLast(entries.count - Self.capacity)
        }
        persist()
    }

    /// Whether this content repeats the newest item. That adds nothing, but a screenshot hidden
    /// from the Clipboard tab shows there again.
    private func repeatsNewest(_ contentKey: String) -> Bool {
        guard let newest = entries.first, newest.contentKey == contentKey else { return false }
        showInClipboardTab(newest.id)
        return true
    }

    private func showInClipboardTab(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isHiddenFromClipboardTab else { return }
        entries[index].isHiddenFromClipboardTab = false
        persist()
    }

    private func removeMedia(for entry: ClipboardEntry) {
        guard let imageURL = entry.imageURL else { return }
        let mediaRoot = mediaDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = imageURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.hasPrefix(mediaRoot + "/") else { return }
        try? fileManager.removeItem(at: imageURL)
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

