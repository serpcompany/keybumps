import Foundation

/// A capture's own folder, `<captures folder>/<timestamp>/`, named like Dictation's recordings:
/// the start time in Unix seconds, with `-2`, `-3`, … when two start in the same second.
enum ScreencastCaptureFolder {
    static func create(in capturesFolder: URL, startedAt: Date, fileManager: FileManager) throws -> URL {
        let baseName = String(Int(startedAt.timeIntervalSince1970))
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

/// A capture's `meta.json`. Structure only: what was recorded, how long, which tracks, and how
/// many displays, never a window, app, title, or address. The review panel (#450) adds the note,
/// type, and repository later; those stay on this Mac.
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

    var version = Self.currentVersion
    var startedAt: Date
    /// `display`, `everyDisplay`, `window`, or `area`.
    var target: String
    var duration: Double
    var displayCount: Int
    var videos: [Video]
    /// A `ScreencastFailure` category when the recording ended without being stopped.
    var endedEarly: String?

    init(capture: ScreencastCapture, target: ScreencastTarget, startedAt: Date) {
        self.startedAt = startedAt
        self.target = target.kind
        duration = capture.duration
        displayCount = capture.videos.count
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
