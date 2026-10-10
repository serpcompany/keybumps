import AppKit
import AVKit
import SwiftUI

/// The review panel after each capture (#450): a small floating panel in the corner of the screen
/// that takes the keyboard for the note, and asks what to do with the capture. It starts from
/// Snapzy's quick-access card (BSD-3-Clause, see LICENSE.snapzy), grown into a panel.
///
/// The flow that finishes captures makes one, calls `show` with each capture and the context read
/// when it started, and hears how each ended through `onFinish`. Captures take turns: one that
/// arrives while another is under review closes that one first, which saves it, unless the
/// Screenshot Editor is open on it, which the person finishes first. After `shutDown()`, a capture
/// still waiting is saved without showing.
@MainActor
final class ScreencastReviewPanel {
    let panel = ScreencastReviewWindow()
    private(set) var model: ScreencastReviewModel?
    /// Called when the panel is done with a capture.
    var onFinish: ((ScreencastReviewOutcome) -> Void)?

    private let repositories: ScreencastRepositoryMemory
    private let fileManager: FileManager
    private let pasteboard: NSPasteboard
    private let keepOutOfClipboardHistory: () -> Void
    private let editor: @MainActor () -> (any ScreencastScreenshotEditing)?
    private let trimmer: any ScreencastTrimming
    private let screenshots: @MainActor () -> (any ScreencastScreenshotsLibrary)?
    private let settings: ScreencastReviewSettings
    private let screen: @MainActor () -> NSScreen?
    private let ordersPanelIn: Bool
    private var playback: ScreencastReviewPlayback?
    private var keyMonitor: Any?
    /// The last capture's turn, which the next one waits for.
    private var turn: Task<Void, Never>?
    /// False after `shutDown()`, until `startAccepting()`.
    private(set) var isAccepting = true

    /// - Parameters:
    ///   - keepOutOfClipboardHistory: Marks Copy's write so Clipboard History skips it; the app
    ///     passes `ClipboardHistoryService.suppressCurrentChange`.
    ///   - editor: Screenshot Tools' editor for a screenshot's Edit while it's on, or nil to offer
    ///     none; read for each capture.
    ///   - screenshots: Clipboard History while it's on, for "Also add to Screenshots (⌘3)"; read
    ///     for each capture.
    ///   - settings: Where the panel remembers that switch; tests pass `InMemoryDefaults`.
    ///   - screen: Where the panel shows: the screen with the pointer.
    ///   - ordersPanelIn: False keeps the panel off screen, as under the unit-test host.
    init(
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .keybumps,
        keepOutOfClipboardHistory: @escaping () -> Void,
        editor: @escaping @MainActor () -> (any ScreencastScreenshotEditing)? = { nil },
        trimmer: any ScreencastTrimming = ScreencastFileTrimmer(),
        screenshots: @escaping @MainActor () -> (any ScreencastScreenshotsLibrary)?,
        settings: ScreencastReviewSettings,
        screen: @escaping @MainActor () -> NSScreen? = ScreencastReviewPanel.screenWithPointer,
        ordersPanelIn: Bool = !UnitTestHost.isActive
    ) {
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.editor = editor
        self.trimmer = trimmer
        self.screenshots = screenshots
        self.settings = settings
        self.screen = screen
        self.ordersPanelIn = ordersPanelIn
    }

    var isShown: Bool { model != nil }

    /// Shows the panel for `input` once the captures before it are done, guessing its repository
    /// from `context`, or from `contextRead` when it comes. It returns once the panel is up, or the
    /// capture is saved without showing.
    func show(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext = .none,
        contextRead: Task<ScreencastCaptureContext, Never>? = nil
    ) async {
        let previous = turn
        let current = Task { @MainActor [weak self] in
            await previous?.value
            await self?.present(input, context: context, contextRead: contextRead)
        }
        turn = current
        await current.value
    }

    /// Screencast turned off: the capture under review is saved and the panel closes. An editor open
    /// on it stays open with its markup. Captures still waiting are saved without showing.
    func shutDown() {
        isAccepting = false
        guard let model else { return }
        Task { await model.close() }
    }

    /// Screencast is on again.
    func startAccepting() {
        isAccepting = true
    }

    /// Keybumps is quitting or relaunching: the capture under review is saved at once, without a
    /// trim not yet applied.
    func saveNow() {
        model?.saveNow()
    }

    private func present(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext,
        contextRead: Task<ScreencastCaptureContext, Never>?
    ) async {
        while let shown = model {
            if shown.isEditing {
                await shown.waitUntilFinished()
            } else {
                await close()
            }
        }
        let model = makeModel(input, context: context, contextRead: contextRead)
        guard isAccepting else {
            await model.saveWhenContextComes()
            return
        }
        install(model)
    }

    private func makeModel(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext,
        contextRead: Task<ScreencastCaptureContext, Never>?
    ) -> ScreencastReviewModel {
        ScreencastReviewModel(
            input: input,
            context: context,
            contextRead: contextRead,
            repositories: repositories,
            fileManager: fileManager,
            pasteboard: pasteboard,
            keepOutOfClipboardHistory: keepOutOfClipboardHistory,
            editor: editor(),
            trimmer: trimmer,
            screenshots: screenshots(),
            settings: settings
        )
    }

    private func install(_ model: ScreencastReviewModel) {
        let input = model.input
        model.onFinish = { [weak self, weak model] outcome in
            guard let self, let model, self.model === model else { return }
            self.dismiss()
            self.onFinish?(outcome)
        }
        self.model = model
        let playback = input.isVideo && ordersPanelIn ? ScreencastReviewPlayback() : nil
        self.playback = playback
        let host = ScreencastReviewHostingView(rootView: ScreencastReviewView(model: model, playback: playback))
        panel.contentView = host
        let size = host.fittingSize
        if let visibleFrame = screen()?.visibleFrame {
            panel.setFrame(CGRect(origin: Self.origin(for: size, in: visibleFrame), size: size), display: false)
        }
        installKeyMonitor()
        guard ordersPanelIn else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel without a choice, which saves the capture. An editor open on it stays open.
    func close() async {
        guard let model else { return }
        await model.close()
        // A capture whose model couldn't finish still leaves the panel.
        if self.model === model { dismiss() }
    }

    private func dismiss() {
        removeKeyMonitor()
        playback?.stop()
        playback = nil
        model = nil
        // The view stays until the next capture replaces it: it may be in the middle of a click.
        panel.orderOut(nil)
    }

    // MARK: Placement

    /// Snapzy's quick-access corner: the bottom-right of the visible frame, `padding` in from each
    /// edge, kept on screen when the panel is taller than it (`QuickAccessPosition.calculateOrigin`).
    static func origin(for size: CGSize, in visibleFrame: CGRect, padding: CGFloat = 20) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX, visibleFrame.maxX - size.width - padding),
            y: min(visibleFrame.minY + padding, max(visibleFrame.minY, visibleFrame.maxY - size.height))
        )
    }

    static func screenWithPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, let model else { return event }
        let isComposing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch ScreencastReviewKey.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isTrimming: model.isTrimming,
            isComposing: isComposing,
            isConfirmingDiscard: model.isConfirmingDiscard,
            isEditing: model.isEditing
        ) {
        case .pass: return event
        case .ignore: return nil
        case .save:
            Task { await model.save() }
            return nil
        case .close:
            Task { await self.close() }
            return nil
        case .keep:
            model.keep()
            return nil
        }
    }
}

/// What a key does in the review panel. Return saves and Escape closes, which saves too; while the
/// discard question is up, Escape keeps the capture and Return does nothing, so a key never
/// deletes. While the Screenshot Editor is open on the screenshot, neither does anything, so its
/// markup is never thrown away. The player's trim controls and a text field still composing (an
/// input method's marked text) keep their keys.
enum ScreencastReviewKey: Equatable {
    case save
    case close
    case keep
    /// Swallowed.
    case ignore
    /// Left to the panel's controls.
    case pass

    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isTrimming: Bool,
        isComposing: Bool,
        isConfirmingDiscard: Bool,
        isEditing: Bool = false
    ) -> ScreencastReviewKey {
        guard !isTrimming, !isComposing,
              modifiers.intersection([.command, .control, .option]).isEmpty else { return .pass }
        if isEditing, keyCode == escapeKeyCode || returnKeyCodes.contains(keyCode) { return .ignore }
        if keyCode == escapeKeyCode { return isConfirmingDiscard ? .keep : .close }
        if returnKeyCodes.contains(keyCode) { return isConfirmingDiscard ? .ignore : .save }
        return .pass
    }
}

/// The review panel's window: borderless, floating over other apps on every Space and beside
/// full-screen apps, like Snapzy's `QuickAccessPanel`. Unlike that card it takes key focus for the
/// note, without making Keybumps the active app, as the Command Palette does. Under the unit-test
/// host it never becomes key, so it can't take keystrokes typed in other apps.
final class ScreencastReviewWindow: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier(ScreencastReviewID.panel)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        identifier = Self.identifier
        setAccessibilityIdentifier(ScreencastReviewID.panel)
        setAccessibilityLabel("Review capture")
    }

    override var canBecomeKey: Bool { !UnitTestHost.isActive }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, so a button works while another app is active.
private final class ScreencastReviewHostingView: NSHostingView<ScreencastReviewView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A recording's player and its trim controls, `AVPlayerView`'s own.
@MainActor
final class ScreencastReviewPlayback: ScreencastTrimPresenting {
    let view = AVPlayerView()
    private let player = AVPlayer()
    private var shown: URL?

    init() {
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.setAccessibilityIdentifier(ScreencastReviewID.player)
    }

    /// Shows `video`, keeping only `trim` of it.
    func show(_ video: ScreencastVideo, trim: ScreencastTrimRange?) {
        let url = video.forSharing
        if shown != url || player.currentItem == nil {
            shown = url
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        guard let item = player.currentItem else { return }
        item.reversePlaybackEndTime = trim.map { CMTime(seconds: $0.start, preferredTimescale: 600) } ?? .invalid
        item.forwardPlaybackEndTime = trim.map { CMTime(seconds: $0.end, preferredTimescale: 600) } ?? .invalid
    }

    /// Shows the file again, as after a trim replaced it.
    func reload(_ video: ScreencastVideo) {
        shown = nil
        show(video, trim: nil)
    }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        shown = nil
    }

    func beginTrimming(_ completion: @escaping (ClosedRange<TimeInterval>?) -> Void) -> Bool {
        guard view.canBeginTrimming, let item = player.currentItem else { return false }
        player.pause()
        view.beginTrimming { [weak item] result in
            MainActor.assumeIsolated {
                guard result == .okButton, let item else { return completion(nil) }
                let duration = item.duration.isNumeric ? item.duration.seconds : .infinity
                let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : duration
                completion(start...max(start, end))
            }
        }
        return true
    }
}
