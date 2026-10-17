import Foundation

/// One recording in ScreenGrabs' recordings index (#492): where its folder is, and structure read
/// from its `meta.json`. Never a title, note, repository, app, address, or anything else the
/// recording window's review holds.
struct IndexedRecording: Codable, Equatable, Identifiable, Sendable {
    /// One display's file, by its name in the recording's folder.
    struct Video: Codable, Equatable, Sendable {
        /// The full recording: `video-1.mov`.
        var file: String
        /// Its stereo mixdown, when it has one: `video-1-mixdown.mp4`.
        var mixdown: String?
    }

    /// Made when the recording is indexed. It names the poster frame, so it's kept as long as the entry.
    let id: UUID
    /// The recording's own folder, `<recordings folder>/<timestamp>/`, wherever it's saved.
    var folder: URL
    var startedAt: Date
    /// Recorded seconds, pauses excluded.
    var duration: Double
    var displayCount: Int
    /// `display`, `everyDisplay`, `window`, or `area`.
    var target: String
    var videos: [Video]
    /// The poster frame's file name in the poster cache (`RecordingPosterFrames`), made when first asked for.
    var posterFrame: String
    /// Its folder, or every video in it, was gone when the index last looked: moved or deleted
    /// outside Keybumps. Worked out each time the index looks, never stored.
    var isMissing = false

    /// The full recordings, one per display.
    var videoURLs: [URL] { videos.map { folder.appendingPathComponent($0.file) } }

    /// What to copy or send: each display's mixdown when it has one, else its full recording, as
    /// the recording window's Copy does.
    var sharingURLs: [URL] { videos.map { folder.appendingPathComponent($0.mixdown ?? $0.file) } }

    private enum CodingKeys: String, CodingKey {
        case id, folder, startedAt, duration, displayCount, target, videos, posterFrame
    }

    init(id: UUID = UUID(), folder: URL, metadata: RecordingStructure) {
        self.id = id
        // One spelling, however the folder was found, so entries compare by path.
        self.folder = URL(fileURLWithPath: folder.standardizedFileURL.path, isDirectory: true)
        startedAt = metadata.startedAt
        duration = metadata.duration ?? 0
        displayCount = metadata.displayCount ?? metadata.videos?.count ?? 0
        target = metadata.target ?? "display"
        videos = (metadata.videos ?? []).map { Video(file: $0.file, mixdown: $0.mixdown) }
        posterFrame = "\(id.uuidString).jpg"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        folder = URL(fileURLWithPath: try container.decode(String.self, forKey: .folder), isDirectory: true)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        displayCount = try container.decodeIfPresent(Int.self, forKey: .displayCount) ?? 0
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? "display"
        videos = try container.decode([Video].self, forKey: .videos)
        posterFrame = try container.decodeIfPresent(String.self, forKey: .posterFrame) ?? "\(id.uuidString).jpg"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(folder.path, forKey: .folder)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(displayCount, forKey: .displayCount)
        try container.encode(target, forKey: .target)
        try container.encode(videos, forKey: .videos)
        try container.encode(posterFrame, forKey: .posterFrame)
    }

    /// Takes a newer read of the same folder, keeping its ID and poster frame.
    func updated(with metadata: RecordingStructure) -> IndexedRecording {
        var next = IndexedRecording(id: id, folder: folder, metadata: metadata)
        next.posterFrame = posterFrame
        return next
    }

    /// Newest first; two that started together, by folder.
    static func newestFirst(_ left: IndexedRecording, _ right: IndexedRecording) -> Bool {
        left.startedAt == right.startedAt ? left.folder.path > right.folder.path : left.startedAt > right.startedAt
    }
}

/// `recordings.json`: version 1, then every indexed recording. An entry that can't be decoded is
/// skipped rather than failing the file (`RecordingIndexFile.read`).
struct RecordingIndexFile: Encodable {
    static let fileName = "recordings.json"
    static let currentVersion = 1

    var version = Self.currentVersion
    var recordings: [IndexedRecording]

    /// What reading the file found.
    enum Contents {
        /// Version 1. `skipped` entries couldn't be decoded.
        case current([IndexedRecording], skipped: Int)
        /// Written by a later build. What could be read is listed, and nothing is written over it.
        case newer([IndexedRecording])
        /// Not an index this build can read at all.
        case corrupt
    }

    static func read(_ data: Data) -> Contents {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { return .corrupt }
        let readable = header.recordings.compactMap(\.recording)
        if header.version > currentVersion { return .newer(readable) }
        guard header.version == currentVersion else { return .corrupt }
        return .current(readable, skipped: header.recordings.count - readable.count)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private struct Header: Decodable {
        var version: Int
        var recordings: [LenientRecording]
    }

    /// One entry that decodes to nil instead of failing the whole file.
    private struct LenientRecording: Decodable {
        let recording: IndexedRecording?

        init(from decoder: Decoder) throws {
            recording = try? IndexedRecording(from: decoder)
        }
    }
}

/// The structural keys of a recording folder's `meta.json`, and nothing else: the recording
/// window's `review` block (the note, type, repository, and capture-time app and site) is never
/// decoded. A folder an earlier QA build's Screencast saved a screenshot in has `kind: screenshot`.
struct RecordingStructure: Decodable, Equatable, Sendable {
    struct Video: Decodable, Equatable, Sendable {
        var file: String
        var mixdown: String?
    }

    var kind: String?
    var startedAt: Date
    var target: String?
    var duration: Double?
    var displayCount: Int?
    var videos: [Video]?

    /// A video recording, with at least one file.
    var isVideo: Bool { kind != "screenshot" && !(videos ?? []).isEmpty }
    /// A screenshot a QA build's Screencast saved before #487.
    var isScreenshot: Bool { kind == "screenshot" }

    init(kind: String? = nil, startedAt: Date, target: String?, duration: Double?, displayCount: Int?, videos: [Video]?) {
        self.kind = kind
        self.startedAt = startedAt
        self.target = target
        self.duration = duration
        self.displayCount = displayCount
        self.videos = videos
    }

    /// The `meta.json` in `folder`, or nil when there's none or it isn't a recording's.
    static func read(in folder: URL) -> RecordingStructure? {
        let url = folder.appendingPathComponent(ScreencastMetadata.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingStructure.self, from: data)
    }
}
