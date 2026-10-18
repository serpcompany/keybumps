import Foundation

/// What the ⌘3 tab (#494) reads of a saved recording beyond its index entry: the recording as the
/// recording window takes it, and the poster frame a moved or deleted one keeps. Like the index, it
/// reads only structure from `meta.json` (each video's file, mixdown, size, sounds, and length),
/// never the review, and logs nothing.
extension IndexedRecording {
    /// The recording as the recording window opens it again (`ScreencastReviewFlow.open(_:)`), from
    /// its `meta.json`; nil when that can't be read, names a file outside the folder, or a video is
    /// gone.
    func savedCapture(fileManager: FileManager = .default) -> ScreencastCapture? {
        let url = folder.appendingPathComponent(ScreencastMetadata.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let structure = try? decoder.decode(SavedRecordingStructure.self, from: data) else { return nil }
        var videos: [ScreencastVideo] = []
        for video in structure.videos {
            guard Self.isFileName(video.file) else { return nil }
            let file = folder.appendingPathComponent(video.file)
            guard fileManager.fileExists(atPath: file.path) else { return nil }
            let mixdown = video.mixdown
                .flatMap { Self.isFileName($0) ? folder.appendingPathComponent($0) : nil }
                .flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
            videos.append(ScreencastVideo(
                file: file,
                mixdown: mixdown,
                pixelWidth: video.width,
                pixelHeight: video.height,
                audioTracks: (video.tracks ?? []).compactMap(ScreencastAudioSource.init(rawValue:)),
                duration: video.duration
            ))
        }
        guard !videos.isEmpty else { return nil }
        return ScreencastCapture(folder: folder, videos: videos, duration: structure.duration, endedEarly: nil)
    }
}

extension RecordingLibrary {
    /// The poster frame already cached for `recording`, without making one: what a moved or deleted
    /// recording's tile keeps (`posterFrame(for:)` makes none for it).
    func cachedPosterFrame(for recording: IndexedRecording) -> URL? {
        guard let url = posterFrames.url(for: recording), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// The keys of `meta.json` the recording window needs for each video, and nothing else.
private struct SavedRecordingStructure: Decodable {
    struct Video: Decodable {
        var file: String
        var mixdown: String?
        var width: Int
        var height: Int
        /// `video`, then the recorded sounds.
        var tracks: [String]?
        var duration: Double
    }

    var duration: Double
    var videos: [Video]
}
