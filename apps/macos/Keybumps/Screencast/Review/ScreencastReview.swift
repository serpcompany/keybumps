import Foundation

// What the review panel reviews, what the person tells it, and how it ends. A capture's review is
// user content: it stays in the capture's `meta.json` on this Mac until the person sends the
// capture (#451), and is never logged.

/// A finished recording for the review panel, in its own folder in the captures folder,
/// `<captures folder>/<timestamp>/`, beside its `meta.json`, with a video per display.
enum ScreencastReviewInput: Equatable {
    case video(ScreencastCapture)

    /// What the flow controller saved.
    init(_ result: ScreencastCaptureResult) {
        switch result {
        case .video(let capture): self = .video(capture)
        }
    }

    var folder: URL {
        switch self {
        case .video(let capture): capture.folder
        }
    }

    var metadataURL: URL { folder.appendingPathComponent(ScreencastMetadata.fileName) }

    /// The capture's own files. Discard deletes the folder only when every one is in it.
    var mediaFiles: [URL] {
        switch self {
        case .video(let capture): capture.videos.flatMap { [$0.file] + [$0.mixdown].compactMap { $0 } }
        }
    }
}

/// How the review panel ended.
enum ScreencastReviewOutcome: Equatable {
    /// Save, Return, or closing without a choice: the capture stays in its folder, its review in
    /// its `meta.json`.
    case saved(ScreencastReviewInput)
    /// Copy: saved as above, and on the clipboard.
    case copied(ScreencastReviewInput)
    /// Discard: the capture's folder is deleted.
    case discarded
}

/// What a capture reports: a bug, a feature, or feedback, as Clipy's `--type` takes them.
enum ScreencastReviewType: String, CaseIterable, Codable, Sendable {
    case bug
    case feature
    case feedback

    var title: String {
        switch self {
        case .bug: "Bug"
        case .feature: "Feature"
        case .feedback: "Feedback"
        }
    }
}

/// Why a review action didn't finish. A category only, never a note, file, app, or address, so it
/// can be shown and logged as it is.
enum ScreencastReviewFailure: String, Error, Equatable {
    /// The repository isn't `owner/name`.
    case invalidRepository
    /// `meta.json` couldn't be written.
    case metadataFailed
    /// Nothing went on the clipboard.
    case copyFailed
    /// The capture's folder couldn't be deleted, or wasn't the capture's.
    case deleteFailed

    /// What the panel says.
    var message: String {
        switch self {
        case .invalidRepository: "Type the repository as owner/name, like serpcompany/keybumps."
        case .metadataFailed: "Couldn’t save the note. The capture is still in its folder."
        case .copyFailed: "Couldn’t copy the capture."
        case .deleteFailed: "Couldn’t delete the capture."
        }
    }
}

/// What the person said about a capture in the review panel, kept in its `meta.json` under
/// `review`. User content: it stays on this Mac until the capture is sent, and is never logged.
struct ScreencastReview: Codable, Equatable, Sendable {
    static let key = "review"

    /// One line.
    var note: String
    var type: ScreencastReviewType
    /// `owner/name` on GitHub; nil when none was chosen.
    var repository: String?
    /// The app, and for a browser the website, in front when the capture started.
    var context: ScreencastCaptureContext
    var reviewedAt: Date

    /// Puts `review` in the `meta.json` at `url`, keeping everything the recorder wrote there. From
    /// then on the file holds user content, so only the person can read it (0600).
    static func write(
        _ review: ScreencastReview,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        var metadata: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            // A file that isn't a JSON object has nothing left to keep.
            metadata = ((try? JSONSerialization.jsonObject(with: existing)) as? [String: Any]) ?? [:]
        }
        metadata[key] = try JSONSerialization.jsonObject(with: encoder.encode(review))
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try PrivateFile.write(data, to: url, fileManager: fileManager)
    }

    /// The review in a capture's `meta.json`, or nil when it has none.
    static func read(from url: URL) -> ScreencastReview? {
        guard let data = try? Data(contentsOf: url),
              let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let review = metadata[key],
              let reviewData = try? JSONSerialization.data(withJSONObject: review) else { return nil }
        return try? decoder.decode(ScreencastReview.self, from: reviewData)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
