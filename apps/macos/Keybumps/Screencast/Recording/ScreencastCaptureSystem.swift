import CoreGraphics
import CoreMedia
import Foundation

/// How one video stream reads the screen.
struct ScreencastStreamConfiguration: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// In the display's points, top-left origin.
    var sourceRect: CGRect
    let framesPerSecond: Int
    let showsCursor: Bool
    let showsMouseClicks: Bool
    /// A window recording: a resized window scales into the fixed-size video instead of being
    /// cropped.
    let scalesToFit: Bool
    /// ScreenCaptureKit's `includeChildWindows`. Off for window recordings, whose filter names
    /// every window it shows (sheets and popovers included), so a child window nobody named, such as
    /// one an overlay attaches, stays out. Left at ScreenCaptureKit's default, on, elsewhere.
    var includesChildWindows = true
}

/// Where a stream delivers its samples, on its own queue. A stream that stops on its own (the
/// display went away, macOS stopped it) reports once through `stopped`.
struct ScreencastSampleHandler: Sendable {
    var video: @Sendable (CMSampleBuffer) -> Void = { _ in }
    var audio: @Sendable (CMSampleBuffer, ScreencastAudioSource) -> Void = { _, _ in }
    var stopped: @Sendable (ScreencastFailure) -> Void = { _ in }
}

/// One ScreenCaptureKit stream.
@MainActor
protocol ScreencastStream: AnyObject {
    func start() async throws
    /// Stops it; a stream that already stopped is fine.
    func stop() async
    /// Rebuilds its content filter while it runs (`SCStream.updateContentFilter`).
    func update(plan: ScreencastFilterPlan, content: ScreencastContent) async throws
    /// Moves what it reads (`SCStream.updateConfiguration`), for a window that moved.
    func update(sourceRect: CGRect) async throws
}

/// ScreenCaptureKit, behind a seam: `SCShareableContent` and `SCStream` in the app, a fake in
/// tests, which therefore never capture the screen, open the microphone, or ask for permission.
/// Errors it throws are `ScreencastFailure`s.
@MainActor
protocol ScreencastCaptureSystem: AnyObject {
    /// What's on screen now.
    func content() async throws -> ScreencastContent

    /// What's on screen now, with `onScreenOnly` leaving out windows that aren't: minimized,
    /// hidden, or on other Spaces. Smaller and faster, which is all a window recording needs.
    func content(onScreenOnly: Bool) async throws -> ScreencastContent

    /// A stream showing `plan`, delivering frames sized by `configuration`, with no sound.
    func makeVideoStream(
        plan: ScreencastFilterPlan,
        configuration: ScreencastStreamConfiguration,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream

    /// A display-wide stream for sound only: the Mac's sound (without Keybumps's own) and the
    /// microphone, as `audio` asks. One feeds every file, whatever the target, because a window's
    /// stream would hear only its own app.
    func makeAudioStream(
        audio: ScreencastAudio,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream

    /// A window's frame now (global top-left points), or nil while it's off screen or closed.
    func windowFrame(_ id: CGWindowID) -> CGRect?

    /// The window numbers of Keybumps's visible windows, to notice when one opens or closes.
    func ownVisibleWindows() -> Set<CGWindowID>

    /// The window numbers of a process's windows on screen now, read cheaply many times a second
    /// to notice a recorded app opening a menu or sheet; nil when they can't be read.
    func onScreenWindows(of processID: pid_t) -> Set<CGWindowID>?

    /// The window numbers of the Open and Save panel services' windows on screen now, read like
    /// `onScreenWindows(of:)`, to notice a sandboxed app's Save panel opening.
    func onScreenPanelServiceWindows() -> Set<CGWindowID>?

    /// Whether a window still exists, on screen or not: minimized, hidden, and on another Space
    /// all count. Nil when it can't be told.
    func windowExists(_ id: CGWindowID) -> Bool?
}

extension ScreencastCaptureSystem {
    /// A capture system that can't tell: window recordings then pick up an app's new windows only
    /// when something else rebuilds the filter.
    func onScreenWindows(of processID: pid_t) -> Set<CGWindowID>? { nil }

    func onScreenPanelServiceWindows() -> Set<CGWindowID>? { nil }

    func windowExists(_ id: CGWindowID) -> Bool? { nil }

    /// A capture system with one kind of read gives it whatever's asked.
    func content(onScreenOnly: Bool) async throws -> ScreencastContent {
        try await content()
    }
}
