import Foundation

/// A recording's own folder, `<Recordings folder>/<timestamp>/`, named like Dictation's recordings:
/// the start time in Unix seconds, with `-2`, `-3`, … when two start in the same second.
enum ScreencastCaptureFolder {
    /// 2001-09-09, the first Unix second with 10 digits. A clock that reads earlier isn't a real
    /// time, so a name is never a short number like a year.
    private static let earliestSeconds = 1_000_000_000

    /// Whether `name` is one `create` makes: Unix seconds (10 digits or more) or `0`, alone or with
    /// `-2`, `-3`, …. The recordings index and export recovery open only folders named so, since a
    /// Recordings folder such as the Desktop holds the person's own folders too, years like `2024`
    /// among them (#504).
    static func isFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } })
        else { return false }
        let seconds = parts[0]
        return seconds == "0" || (seconds.count >= 10 && !seconds.hasPrefix("0"))
    }

    static func create(in capturesFolder: URL, startedAt: Date, fileManager: FileManager) throws -> URL {
        // A clock that isn't a real time names the folder 0 rather than trapping.
        let seconds = ScreencastNumbers.int(startedAt.timeIntervalSince1970, in: 0...Int.max, fallback: 0)
        let baseName = seconds < earliestSeconds ? "0" : String(seconds)
        var name = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: capturesFolder.appendingPathComponent(name).path) {
            name = "\(baseName)-\(suffix)"
            suffix += 1
        }
        let folder = capturesFolder.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The full recording of the display at `index` (from 0): `video-1.mov`, `video-2.mov`, …
    static func videoName(index: Int) -> String {
        "video-\(index + 1).mov"
    }

    /// Its stereo mixdown: `video-1-mixdown.mp4`, …
    static func mixdownName(index: Int) -> String {
        "video-\(index + 1)-mixdown.mp4"
    }
}

/// A capture's `meta.json`. The recorder writes structure only: what was recorded, how long, which
/// tracks, and how many displays, never a window, app, title, or address. The review panel (#450)
/// adds `review`, the note, type, repository, and capture-time context, which are user content and
/// stay on this Mac.
struct ScreencastMetadata: Codable, Equatable {
    static let fileName = "meta.json"
    static let currentVersion = 1

    struct Video: Codable, Equatable {
        /// File names in the capture's folder.
        var file: String
        var mixdown: String?
        var width: Int
        var height: Int
        /// `video`, then the recorded sounds: `microphone`, `systemAudio`.
        var tracks: [String]
        var duration: Double
    }

    /// A display that stopped while the others recorded on.
    struct DisplayEnd: Codable, Equatable {
        /// From 1, as in `video-1.mov`.
        var display: Int
        /// A `ScreencastFailure` category.
        var reason: String
        /// Its file, when it kept footage.
        var file: String?
    }

    var version = Self.currentVersion
    var startedAt: Date
    /// `display`, `everyDisplay`, `window`, or `area`.
    var target: String
    var duration: Double
    var displayCount: Int
    var videos: [Video]
    /// A `ScreencastFailure` category when the recording ended without being stopped.
    var endedEarly: String?
    /// Left out when every display recorded to the end.
    var displaysEndedEarly: [DisplayEnd]?
    /// What the person said in the review panel; nil until it saves.
    var review: ScreencastReview?

    init(capture: ScreencastCapture, target: ScreencastTarget, startedAt: Date) {
        self.startedAt = startedAt
        self.target = target.kind
        duration = capture.duration
        // A display that stopped before it recorded anything still counts.
        displayCount = capture.videos.count + capture.displaysEndedEarly.filter { $0.file == nil }.count
        videos = capture.videos.map { video in
            Video(
                file: video.file.lastPathComponent,
                mixdown: video.mixdown?.lastPathComponent,
                width: video.pixelWidth,
                height: video.pixelHeight,
                tracks: ["video"] + video.audioTracks.map(\.rawValue),
                duration: video.duration
            )
        }
        endedEarly = capture.endedEarly?.rawValue
        let ends = capture.displaysEndedEarly.map { end in
            DisplayEnd(display: end.index + 1, reason: end.reason.rawValue, file: end.file?.lastPathComponent)
        }
        displaysEndedEarly = ends.isEmpty ? nil : ends
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ScreencastMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScreencastMetadata.self, from: Data(contentsOf: url))
    }
}
