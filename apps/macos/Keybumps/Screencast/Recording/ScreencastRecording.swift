import CoreGraphics
import Foundation

// The recording engine's vocabulary: what to record, with which sound, what state it's in, and what
// a finished capture holds. `ScreencastRecorder` drives a recording with these; the picker, control
// bar, overlays, and review panel read them.

/// What a screencast records.
enum ScreencastTarget: Equatable, Sendable {
    /// One display, whole.
    case display(CGDirectDisplayID)
    /// Every display connected when recording starts, each in its own file.
    case everyDisplay
    /// One window, followed as it moves or resizes, with its app's menus, sheets, and popovers.
    case window(CGWindowID)
    /// Part of one display. `rect` is in the display's points with the origin at its top-left, the
    /// space of ScreenCaptureKit's `sourceRect`; `displayLocalRect(fromAppKit:screenFrame:)` converts a
    /// rect a picker drew in AppKit's global space.
    case area(display: CGDirectDisplayID, rect: CGRect)

    /// The kind alone, as `meta.json` records it: never a display, window, or app.
    var kind: String {
        switch self {
        case .display: "display"
        case .everyDisplay: "everyDisplay"
        case .window: "window"
        case .area: "area"
        }
    }

    /// `rect`, in AppKit's global space (origin at the main display's bottom-left), as a rect on the
    /// display whose `NSScreen.frame` is `screenFrame`: its points, origin at its top-left.
    static func displayLocalRect(fromAppKit rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// The two sounds a screencast can record, each in its own track.
enum ScreencastAudioSource: String, CaseIterable, Codable, Sendable {
    case microphone
    case systemAudio
}

/// Which sounds a recording starts with. A source that's off at the start has no track and can't
/// be turned on later; one that's on can be switched off and on while recording.
struct ScreencastAudio: Equatable, Sendable {
    var microphone: Bool
    var systemAudio: Bool

    static let none = ScreencastAudio(microphone: false, systemAudio: false)

    init(microphone: Bool, systemAudio: Bool) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    var sources: [ScreencastAudioSource] {
        ScreencastAudioSource.allCases.filter(contains)
    }

    func contains(_ source: ScreencastAudioSource) -> Bool {
        switch source {
        case .microphone: microphone
        case .systemAudio: systemAudio
        }
    }
}

/// One sound during a recording, as the control bar shows it.
enum ScreencastAudioSourceState: Equatable, Sendable {
    /// Off when the recording started: no track, and its switch does nothing.
    case notRecorded
    /// Recording.
    case on
    /// Switched off: its track gets silence until it's switched back on.
    case off
    /// Its capture stopped working; its track is silent from then on, and the video goes on.
    case failed
}

/// Why a recording couldn't start, or ended without `stop()`. A category only: never a window,
/// app, file, or display name, so it can be shown, logged, and stored as it is.
enum ScreencastFailure: String, Error, Equatable, Codable, Sendable {
    /// ScreenCaptureKit refused to capture: Keybumps lacks Screen Recording.
    case screenRecordingDenied
    /// The display or window to record isn't there any more.
    case targetUnavailable
    /// A stream failed to start, or stopped on its own.
    case captureFailed
    /// macOS stopped the capture: Stop Sharing in the menu bar, or the system ending it.
    case stoppedByMacOS
    /// A file couldn't be written: a full disk or a failed encoder.
    case writerFailed
    /// The captures folder couldn't be created.
    case folderUnavailable
    /// The recording ended before any picture was written, so there's nothing to keep.
    case noFootage
}

/// A call made in a state that doesn't allow it, such as `stop()` while idle.
enum ScreencastRecorderError: Error, Equatable {
    case alreadyRecording
    case notRecording
}

/// Where a recording is.
enum ScreencastRecorderState: Equatable, Sendable {
    case idle
    /// Reading what's on screen, creating the files, and starting the streams.
    case starting
    case recording
    case paused
    /// Finishing the files and writing the mixdown and `meta.json`.
    case stopping
    /// The last recording couldn't start or ended early. `start` works again from here.
    case failed(ScreencastFailure)

    /// Recording or paused: the states `pause`, `resume`, `restart`, `stop`, and `discard` act in.
    var isActive: Bool {
        self == .recording || self == .paused
    }
}

/// How a recording is captured and encoded.
struct ScreencastOptions: Equatable, Sendable {
    var framesPerSecond = 30
    /// Draws the pointer into the video.
    var showsCursor = true
    /// ScreenCaptureKit's own click highlight, in the video only (#449).
    var showsMouseClicks = false

    init(framesPerSecond: Int = 30, showsCursor: Bool = true, showsMouseClicks: Bool = false) {
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
        self.showsMouseClicks = showsMouseClicks
    }
}

/// A finished recording, saved in its own folder in the captures folder.
struct ScreencastCapture: Equatable, Sendable {
    /// `<captures folder>/<timestamp>/`.
    let folder: URL
    /// One per display, in display order.
    let videos: [ScreencastVideo]
    /// Recorded seconds, pauses excluded: the longest video's.
    let duration: TimeInterval
    /// Why it ended without `stop()`, if it did. Everything captured until then is kept.
    let endedEarly: ScreencastFailure?
    /// Displays of an every-display recording whose stream stopped while the others recorded on.
    var displaysEndedEarly: [ScreencastDisplayEnd] = []

    var metadataURL: URL { folder.appendingPathComponent(ScreencastMetadata.fileName) }
}

/// A display whose stream stopped (it was disconnected, or macOS stopped it) while the recording's
/// other displays went on. Its file ends there, and is kept when it has footage.
struct ScreencastDisplayEnd: Equatable, Sendable {
    /// Its place among the recording's displays, from 0: `video-<index + 1>.mov`.
    let index: Int
    let reason: ScreencastFailure
    /// Its file, when it recorded anything before it stopped.
    let file: URL?
}

/// One display's file in a capture.
struct ScreencastVideo: Equatable, Sendable {
    /// The full recording: the picture, then a track for each recorded sound.
    let file: URL
    /// The picture with every sound mixed into one stereo track, for players and uploads that play
    /// only one audio track. Nil when the recording has one audio track or none.
    let mixdown: URL?
    let pixelWidth: Int
    let pixelHeight: Int
    let audioTracks: [ScreencastAudioSource]
    let duration: TimeInterval

    /// The file to copy or send: the mixdown when there is one.
    var forSharing: URL { mixdown ?? file }
}
