import AVFoundation
import Foundation

/// What the Screencast smoke test records, in the order it runs them (#470): a video of a screen, a
/// window, and an area.
enum ScreencastSmokeMode: String, CaseIterable, Codable, Sendable {
    case videoScreen = "video-screen"
    case videoWindow = "video-window"
    case videoArea = "video-area"

    var target: ScreencastPickerTarget {
        switch self {
        case .videoScreen: .screen
        case .videoWindow: .window
        case .videoArea: .area
        }
    }
}

/// How far one capture got: the last stage it entered. A capture that passed reached `cleanedUp`.
enum ScreencastSmokeStage: String, Codable, Sendable {
    case notStarted
    /// Start Screencast: the controller reading the screen for the picker.
    case opening
    /// The picker's choice being made through its model.
    case picking
    /// Record pressed.
    case chosen
    case starting
    case recording
    /// Stopping the recording.
    case finishing
    case saved
    case checked
    case cleanedUp
}

/// Why a capture, or the whole run, failed, besides the engine's own `ScreencastFailure`s, which
/// the result names by their raw values.
enum ScreencastSmokeFailure: String, Error, Sendable {
    /// Keybumps doesn't have Screen Recording: nothing was captured, and nothing asked for it.
    case permissionDenied
    case unsupportedMacOS
    /// Its own defaults couldn't be opened.
    case setupFailed
    /// A step took longer than its limit; the stage says which.
    case timeout
    /// Start Screencast didn't open the picker.
    case openRefused
    /// The picker had nothing to record after choosing.
    case noChoice
    /// The blank window the script shows from a helper process wasn't on screen in time, or the
    /// script couldn't show it (no `-KBScreencastSmokeWindowPID`). No other window is ever taken
    /// instead.
    case noSmokeWindow
    /// The capture ended with no file and no reason.
    case ended
    case controlBarMissing
    case overlaysMissing
    case wrongFileCount
    case missingFile
    case emptyFile
    case unreadableVideo
    case noVideoTrack
    case durationOutOfRange
    case cleanupFailed
    /// An earlier capture didn't wind down, so this one didn't run.
    case skipped
}

/// The smoke test's result, written as JSON to `ScreencastSmokeTest.resultURL()` after every stage,
/// so a crash or a hang leaves the last stage reached. Structure only: modes, stages, timings,
/// error categories, sizes, the macOS version, and the number of displays; never a window title,
/// app name, file name, path, or URL.
struct ScreencastSmokeReport: Codable, Equatable, Sendable {
    /// Milliseconds each part of a capture took.
    struct Timings: Codable, Equatable, Sendable {
        /// From Start Screencast until the picker's windows were read.
        var pickerMs: Int?
        /// From Record until recording.
        var startMs: Int?
        /// Recording.
        var recordMs: Int?
        /// From Stop until the recording was saved.
        var finishMs: Int?
        var checkMs: Int?
        var totalMs: Int?
    }

    struct Capture: Codable, Equatable, Sendable {
        var mode: ScreencastSmokeMode
        var passed = false
        var stage = ScreencastSmokeStage.notStarted
        var errorCategory: String?
        var timings = Timings()
        /// Whether the control bar and the overlays were up while it recorded, and how many
        /// overlay windows the recorder was given.
        var controlBarShown: Bool?
        var overlaysShown: Bool?
        var overlayWindows: Int?
        /// What the file check read.
        var durationSeconds: Double?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var bytes: Int?

        init(mode: ScreencastSmokeMode) {
            self.mode = mode
        }
    }

    static let currentVersion = 1

    var version = currentVersion
    /// False until the run ends.
    var complete = false
    var passed = false
    /// Why nothing was captured: `permissionDenied`, `unsupportedMacOS`, or `setupFailed`.
    var errorCategory: String?
    var macOS: String
    var displayCount: Int
    /// Whether the folder the captures were saved in was deleted at the end.
    var cleanedUp = false
    var captures: [Capture]

    init(macOS: String, displayCount: Int, modes: [ScreencastSmokeMode]) {
        self.macOS = macOS
        self.displayCount = displayCount
        captures = modes.map(Capture.init(mode:))
    }

    /// 0 when everything passed, 1 when a capture failed, 2 when nothing could be captured: the
    /// run couldn't start, or Screen Recording was refused. `smoke-screencast.sh` reads the same
    /// from the result, since `open` doesn't pass the app's exit code on.
    var exitCode: Int32 {
        if passed { return 0 }
        let refused = captures.contains { $0.errorCategory == ScreencastFailure.screenRecordingDenied.rawValue }
        return errorCategory == nil && !refused ? 1 : 2
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func write(to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json().write(to: url, options: .atomic)
    }
}

/// What a check reads from a video file.
struct ScreencastSmokeVideoFacts: Equatable, Sendable {
    let videoTracks: Int
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Reads saved recordings: AVFoundation loads a video. Tests pass their own for a fake writer's
/// files.
struct ScreencastSmokeInspector: Sendable {
    var video: @Sendable (URL) async throws -> ScreencastSmokeVideoFacts

    static let system = ScreencastSmokeInspector(
        video: { url in
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration).seconds
            let size = try await tracks.first?.load(.naturalSize) ?? .zero
            return ScreencastSmokeVideoFacts(
                videoTracks: tracks.count,
                duration: duration.isFinite ? duration : 0,
                pixelWidth: ScreencastSmokeChecks.pixels(size.width),
                pixelHeight: ScreencastSmokeChecks.pixels(size.height)
            )
        }
    )
}

/// The checks on each saved file: it exists and isn't empty, and has a picture of about the length
/// recorded.
enum ScreencastSmokeChecks {
    /// The file's size in bytes, or `missingFile` or `emptyFile`.
    static func size(of url: URL, fileManager: FileManager) throws -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw ScreencastSmokeFailure.missingFile
        }
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0 else { throw ScreencastSmokeFailure.emptyFile }
        return bytes
    }

    /// A video with a picture, sized, and as long as `durations` allows.
    static func check(_ facts: ScreencastSmokeVideoFacts, durations: ClosedRange<TimeInterval>) throws {
        guard facts.videoTracks > 0, facts.pixelWidth > 0, facts.pixelHeight > 0 else {
            throw ScreencastSmokeFailure.noVideoTrack
        }
        guard durations.contains(facts.duration) else { throw ScreencastSmokeFailure.durationOutOfRange }
    }

    /// A size AVFoundation reports, as whole pixels; 0 for one that isn't a finite number, rather
    /// than a trap.
    static func pixels(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0, value < CGFloat(Int32.max) else { return 0 }
        return Int(value.rounded())
    }
}
