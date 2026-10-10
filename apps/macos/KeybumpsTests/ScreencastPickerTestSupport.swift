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

    /// The bar's Record (or Capture).
    func record() { confirm?() }
    /// The bar's close button.
    func cancel() { cancelPicker?() }
    /// The countdown's Cancel.
    func cancelTheCountdown() { cancelCountdown?() }
    func pressEscape() { escape?() }
}

/// A screen that's made up: `content()` returns `screen`, and screenshots are blank images of the
/// size each plan asks for.
@MainActor
final class FakePickerSystem: ScreencastPickerSystem {
    var screen: ScreencastContent
    var contentError: ScreencastFailure?
    var screenshotError: ScreencastFailure?
    private(set) var plans: [ScreencastScreenshotPlan] = []
    private(set) var contentReads = 0

    init(content: ScreencastContent) {
        screen = content
    }

    func content() async throws -> ScreencastContent {
        contentReads += 1
        if let contentError { throw contentError }
        return screen
    }

    func screenshot(_ plan: ScreencastScreenshotPlan, content: ScreencastContent) async throws -> CGImage {
        plans.append(plan)
        if let screenshotError { throw screenshotError }
        return ScreencastImages.blank(width: plan.configuration.pixelWidth, height: plan.configuration.pixelHeight)
    }
}

enum ScreencastImages {
    static func blank(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
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
    static let left = ScreencastScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let right = ScreencastScreen(id: 2, frame: CGRect(x: 1512, y: -98, width: 1920, height: 1080), scale: 1)

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
        rememberedArea: ScreencastPickedArea? = nil
    ) -> ScreencastPickerModel {
        ScreencastPickerModel(layout: layout, preferences: preferences(), microphoneAvailable: microphoneAvailable, rememberedArea: rememberedArea)
    }
}

enum ScreencastWait {
    /// Lets the main actor run what was handed to it until `condition` holds, then waits up to
    /// five seconds for work off the main actor, such as encoding a screenshot.
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
