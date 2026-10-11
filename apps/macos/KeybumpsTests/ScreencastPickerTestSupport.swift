import CoreGraphics
import Foundation
@testable import Keybumps

// Stand-ins for the picker's and `ScreencastController`'s seams: overlays that draw nothing and
// record what they were asked, a screen that's made up, and a clock the test moves. With these
// and the recorder's fakes (`ScreencastTestSupport.swift`), nothing captures, opens the
// microphone, asks for a permission, or shows a window.

/// The picker's overlays, recording each call. The test plays the person: `record()`, `cancel()`,
/// `pressEscape()`.
@MainActor
final class FakeOverlays: ScreencastOverlayPresenting {
    enum Event: Equatable {
        case showPicker
        case closePicker
        case countdown(Int, frames: [CGRect])
        case closeCountdown
        case highlight(ScreencastPickedArea)
        case closeHighlight
        case watchEscape
        case stopWatchingEscape
        case message(String)
        case gettingReady
        case hideGettingReady
    }

    private(set) var events: [Event] = []
    private(set) var picker: ScreencastPickerModel?
    private var confirm: (() -> Void)?
    private var cancelPicker: (() -> Void)?
    private var cancelCountdown: (() -> Void)?
    private var escape: (() -> Void)?

    var isWatchingEscape: Bool { escape != nil }
    var messages: [String] { events.compactMap { if case .message(let text) = $0 { text } else { nil } } }
    var countdowns: [Int] { events.compactMap { if case .countdown(let remaining, _) = $0 { remaining } else { nil } } }

    func showPicker(_ model: ScreencastPickerModel, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        events.append(.showPicker)
        picker = model
        self.confirm = confirm
        cancelPicker = cancel
    }

    func closePicker() {
        events.append(.closePicker)
        picker = nil
        confirm = nil
        cancelPicker = nil
    }

    func showCountdown(_ remaining: Int, in frames: [CGRect], cancel: @escaping () -> Void) {
        events.append(.countdown(remaining, frames: frames))
        cancelCountdown = cancel
    }

    func closeCountdown() {
        events.append(.closeCountdown)
        cancelCountdown = nil
    }

    func showAreaHighlight(_ area: ScreencastPickedArea) { events.append(.highlight(area)) }
    func closeAreaHighlight() { events.append(.closeHighlight) }

    func watchEscape(_ handler: @escaping () -> Void) {
        events.append(.watchEscape)
        escape = handler
    }

    func stopWatchingEscape() {
        events.append(.stopWatchingEscape)
        escape = nil
    }

    func showMessage(_ message: String) { events.append(.message(message)) }
    func showGettingReady() { events.append(.gettingReady) }
    func hideGettingReady() { events.append(.hideGettingReady) }

    /// The bar's Record.
    func record() { confirm?() }
    /// The bar's close button.
    func cancel() { cancelPicker?() }
    /// The countdown's Cancel.
    func cancelTheCountdown() { cancelCountdown?() }
    func pressEscape() { escape?() }
}

/// A screen that's made up: `content()` returns `screen`.
@MainActor
final class FakePickerSystem: ScreencastPickerSystem {
    var screen: ScreencastContent
    var contentError: ScreencastFailure?
    /// Windows drawn with alpha 0.
    var transparent: Set<CGWindowID> = []
    /// Runs as the screen is read.
    var onContent: () -> Void = {}
    /// Holds reading the screen until `releaseContent()`.
    var holdsContent = false
    private var heldContent: [CheckedContinuation<Void, Never>] = []
    private(set) var contentReads = 0

    init(content: ScreencastContent) {
        screen = content
    }

    func content() async throws -> ScreencastContent {
        contentReads += 1
        onContent()
        if holdsContent { await withCheckedContinuation { heldContent.append($0) } }
        if let contentError { throw contentError }
        return screen
    }

    func releaseContent() {
        holdsContent = false
        let held = heldContent
        heldContent = []
        held.forEach { $0.resume() }
    }

    func transparentWindows() -> Set<CGWindowID> { transparent }
}

/// The countdown's clock: each `sleep` waits until the test calls `advance()`, or throws when its
/// task is cancelled, as `Task.sleep` does.
@MainActor
final class ManualSleeper {
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0
    /// Every sleep asked for, in seconds.
    private(set) var requested: [TimeInterval] = []

    var pending: Int { waiting.count }

    func sleep(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Ends the oldest sleep.
    func advance() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().continuation.resume()
    }

    private func cancel(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// `ScreencastScreens`' two displays as AppKit sees them: the main one on the left, and a taller
/// one to its right whose top lines up with it, so its AppKit frame starts below zero.
enum PickerScreens {
    static let left = ScreencastScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, uuid: "MADE-UP-LEFT-DISPLAY")
    static let right = ScreencastScreen(
        id: 2, frame: CGRect(x: 1512, y: -98, width: 1920, height: 1080), scale: 1, uuid: "MADE-UP-RIGHT-DISPLAY"
    )

    static let both = ScreencastScreenLayout(screens: [left, right])
    static let leftOnly = ScreencastScreenLayout(screens: [left])

    static func preferences(
        microphone: Bool = true,
        systemAudio: Bool = true,
        countdown: Int = 3,
        shortcuts: Bool = true,
        clicks: Bool = false,
        captures: URL = FileManager.default.temporaryDirectory
    ) -> ScreencastPreferences {
        ScreencastPreferences(
            recordsMicrophone: microphone,
            recordsSystemAudio: systemAudio,
            countdownSeconds: countdown,
            showsShortcuts: shortcuts,
            highlightsClicks: clicks,
            capturesFolder: captures
        )
    }

    /// A picker on both screens with the settings' defaults.
    @MainActor
    static func model(
        layout: ScreencastScreenLayout = both,
        microphoneAvailable: Bool = true,
        rememberedArea: ScreencastPickedArea? = nil,
        pointerScreen: CGDirectDisplayID? = nil
    ) -> ScreencastPickerModel {
        ScreencastPickerModel(
            layout: layout, preferences: preferences(), microphoneAvailable: microphoneAvailable,
            rememberedArea: rememberedArea, pointerScreen: pointerScreen
        )
    }
}

enum ScreencastWait {
    /// Lets the main actor run what was handed to it until `condition` holds, then waits up to
    /// five seconds for work off the main actor, such as a recording starting or saving.
    @MainActor
    static func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await Task.yield()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

/// The recorder's fake writers, scripted: each mixdown can be held until `releaseMixdowns()`, so a
/// recording that ends on its own stays in the middle of saving (the recorder `.stopping`) for as
/// long as a test needs, and new files can be refused, so a restart fails. After the round-2 review
/// of #462's repros.
final class ScriptedWriters: ScreencastWriterFactory, @unchecked Sendable {
    let base = FakeWriterFactory()
    private let lock = NSLock()
    private var holds: Bool
    private var refusesNewFiles = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(holdsMixdowns: Bool = false) {
        holds = holdsMixdowns
    }

    var holdsMixdowns: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }

    /// New files throw `writerFailed`.
    var failsNewFiles: Bool {
        get { lock.withLock { refusesNewFiles } }
        set { lock.withLock { refusesNewFiles = newValue } }
    }

    var isHoldingMixdown: Bool { lock.withLock { !held.isEmpty } }

    func makeWriter(
        at url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        audio: [ScreencastAudioSource],
        options: ScreencastOptions,
        onFailure: @escaping @Sendable () -> Void
    ) throws -> any ScreencastMovieWriting {
        if failsNewFiles { throw ScreencastFailure.writerFailed }
        return try base.makeWriter(at: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight, audio: audio, options: options, onFailure: onFailure)
    }

    func writeMixdown(of source: URL, to destination: URL) async throws {
        await withCheckedContinuation { continuation in
            let resumesNow = lock.withLock { () -> Bool in
                if holds { held.append(continuation) }
                return !holds
            }
            if resumesNow { continuation.resume() }
        }
        try await base.writeMixdown(of: source, to: destination)
    }

    /// Lets every mixdown through, from now on too.
    func releaseMixdowns() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held = [] }
            holds = false
            return held
        }
        continuations.forEach { $0.resume() }
    }
}
