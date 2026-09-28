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

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        kind: Kind = .text,
        mediaPath: String? = nil,
        mediaPasteboardType: String? = nil,
        fingerprint: String? = nil,
        sourcePath: String? = nil,
        isScreenCapture: Bool = false
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
    var sourceURL: URL? { sourcePath.map { URL(fileURLWithPath: $0) } }
    var imageURL: URL? { mediaPath.map { URL(fileURLWithPath: $0) } }
    var contentKey: String { fingerprint ?? "text:\(text)" }

    private enum CodingKeys: String, CodingKey {
        case id, text, capturedAt, kind, mediaPath, mediaPasteboardType, fingerprint, sourcePath, isScreenCapture
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
    }
}

@MainActor
@Observable
class ClipboardHistoryService {
    nonisolated static let capacity = 50
    nonisolated static let maximumImageBytes = 50 * 1_024 * 1_024

    private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private let storageURL: URL
    private let pasteboard: NSPasteboard
    private let mediaDirectoryURL: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil,
        pasteboard: NSPasteboard = .general,
        mediaDirectoryURL: URL? = nil
    ) {
        let directory = ProductPaths.keybumps(fileManager: fileManager).applicationSupport
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileManager = fileManager
        self.storageURL = storageURL ?? directory.appendingPathComponent("clipboard-history.json")
        self.mediaDirectoryURL = mediaDirectoryURL ?? directory.appendingPathComponent("clipboard-media", isDirectory: true)
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func delete(_ entry: ClipboardEntry) {
        removeMedia(for: entry)
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.forEach(removeMedia)
        entries.removeAll()
        persist()
    }

    /// Removes screen-capture items and their media copies; original files are never touched.
    func clearScreenshots() {
        entries.filter(\.isScreenshot).forEach(removeMedia)
        entries.removeAll(where: \.isScreenshot)
        persist()
    }

    @discardableResult
    func restore(_ entry: ClipboardEntry) -> Bool {
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
        suppressedChangeCount = nil
        return true
    }

    /// Adds a screenshot file as an image item without touching the pasteboard.
    @discardableResult
    func ingestImageFile(at url: URL, isScreenCapture: Bool = true) -> Bool {
        guard let payload = ClipboardImagePayload.read(fileAt: url) else { return false }
        return ingestImage(payload, sourcePath: url.path, isScreenCapture: isScreenCapture)
    }

    func ingestForTesting(_ text: String) { ingestText(text) }
    func pollForTesting() { poll() }
    func suppressCurrentChange() { suppressedChangeCount = pasteboard.changeCount }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return
        }
        suppressedChangeCount = nil

        // Finder file copies also carry a TIFF of the file's icon; never store that.
        // Keep the first copied image file's real contents and ignore other files.
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            if let imageFile = fileURLs.first(where: ClipboardImagePayload.isSupportedImageFile) {
                ingestImageFile(at: imageFile, isScreenCapture: false)
            }
            return
        }

        if let image = ClipboardImagePayload.read(from: pasteboard) {
            ingestImage(image)
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        ingestText(text)
    }

    private func ingestText(_ text: String) {
        insert(ClipboardEntry(
            id: UUID(),
            text: text,
            capturedAt: Date(),
            fingerprint: "text:\(text)"
        ))
    }

    @discardableResult
    private func ingestImage(_ payload: ClipboardImagePayload, sourcePath: String? = nil, isScreenCapture: Bool = false) -> Bool {
        guard payload.data.count <= Self.maximumImageBytes else { return false }
        let fingerprint = "image:" + SHA256.hash(data: payload.data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard entries.first?.contentKey != fingerprint else { return false }

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
                isScreenCapture: isScreenCapture
            ))
            return true
        } catch {
            try? fileManager.removeItem(at: mediaURL)
            return false
        }
    }

    private func insert(_ entry: ClipboardEntry) {
        guard entries.first?.contentKey != entry.contentKey else { return }
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

