import AppKit
import AVKit
import SwiftUI

/// The review after each capture (#450), which asks what to do with it. A screenshot's is a small
/// floating panel in the corner of the screen that takes the keyboard for the note, started from
/// Snapzy's quick-access card (BSD-3-Clause, see LICENSE.snapzy), grown into a panel. A recording's
/// is a bigger standard window to watch it in, with Discard, Copy, and Save (#475,
/// `ScreencastRecordingReviewWindow`), and nothing to type.
///
/// The flow that finishes captures makes one, calls `show` with each capture and the context read
/// when it started, and hears how each ended through `onFinish`. Captures take turns: one that
/// arrives while another is under review closes that one first, which saves it, unless the
/// Screenshot Editor is open on it, which the person finishes first. After `shutDown()`, a capture
/// still waiting is saved without showing.
@MainActor
final class ScreencastReviewPanel {
    let panel = ScreencastReviewWindow()
    let recordingWindow = ScreencastRecordingReviewWindow()
    private(set) var model: ScreencastReviewModel?
    /// Called when the panel is done with a capture.
    var onFinish: ((ScreencastReviewOutcome) -> Void)?

    private let repositories: ScreencastRepositoryMemory
    private let fileManager: FileManager
    private let pasteboard: NSPasteboard
    private let keepOutOfClipboardHistory: () -> Void
    private let editor: @MainActor () -> (any ScreencastScreenshotEditing)?
    private let screenshots: @MainActor () -> (any ScreencastScreenshotsLibrary)?
    private let settings: ScreencastReviewSettings
    private let screen: @MainActor () -> NSScreen?
    private let ordersPanelIn: Bool
    private let takeKeyboard: @MainActor (NSPanel) -> Void
    private let makePlayback: @MainActor () -> ScreencastReviewPlayback?
    private var activationObserver: NSObjectProtocol?
    /// A recording's player, while its window is up.
    private(set) var playback: ScreencastReviewPlayback?
    /// The app in front before a recording's window took it, which gets it back after.
    private var previousApp: NSRunningApplication?
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
    ///   - ordersPanelIn: False keeps the panel and the window off screen, as under the unit-test host.
    ///   - takeKeyboard: Makes the panel key again after the Screenshot Editor; tests record it.
    ///   - makePlayback: A recording's player, none under the unit-test host unless a test asks.
    init(
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .keybumps,
        keepOutOfClipboardHistory: @escaping () -> Void,
        editor: @escaping @MainActor () -> (any ScreencastScreenshotEditing)? = { nil },
        screenshots: @escaping @MainActor () -> (any ScreencastScreenshotsLibrary)?,
        settings: ScreencastReviewSettings,
        screen: @escaping @MainActor () -> NSScreen? = ScreencastReviewPanel.screenWithPointer,
        ordersPanelIn: Bool = !UnitTestHost.isActive,
        takeKeyboard: @escaping @MainActor (NSPanel) -> Void = ScreencastReviewPanel.makeKeyIfShown,
        makePlayback: @escaping @MainActor () -> ScreencastReviewPlayback? = {
            UnitTestHost.isActive ? nil : ScreencastReviewPlayback()
        }
    ) {
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.editor = editor
        self.screenshots = screenshots
        self.settings = settings
        self.screen = screen
        self.ordersPanelIn = ordersPanelIn
        self.takeKeyboard = takeKeyboard
        self.makePlayback = makePlayback
        recordingWindow.onClose = { [weak self] in
            Task { await self?.close() }
        }
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

    /// Screencast turned off: the capture under review is saved and the panel or window closes. An
    /// editor open on it stays open with its markup. Captures still waiting are saved without showing.
    func shutDown() {
        isAccepting = false
        guard model != nil else { return }
        Task { await close() }
    }

    /// Screencast is on again.
    func startAccepting() {
        isAccepting = true
    }

    /// Keybumps is quitting or relaunching: the capture under review is saved at once.
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
            screenshots: screenshots(),
            settings: settings
        )
    }

    private func install(_ model: ScreencastReviewModel) {
        model.onFinish = { [weak self, weak model] outcome in
            guard let self, let model, self.model === model else { return }
            self.dismiss()
            self.onFinish?(outcome)
        }
        model.onEditorFinished = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.returnKeyboard()
        }
        self.model = model
        installKeyMonitor()
        if model.input.isVideo {
            showRecording(model)
        } else {
            showScreenshot(model)
        }
    }

    private func showScreenshot(_ model: ScreencastReviewModel) {
        let host = ScreencastReviewHostingView(rootView: ScreencastReviewView(model: model))
        panel.contentView = host
        let size = host.fittingSize
        if let visibleFrame = screen()?.visibleFrame {
            panel.setFrame(CGRect(origin: Self.origin(for: size, in: visibleFrame), size: size), display: false)
        }
        guard ordersPanelIn else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// A recording's window, filling the screen with the pointer, where the recording was just
    /// stopped. It's a standard window, so Keybumps comes to the front for it, and gives the front
    /// back when it closes, as the Screenshot Editor does.
    private func showRecording(_ model: ScreencastReviewModel) {
        let playback = makePlayback()
        self.playback = playback
        if let playback, let video = model.currentVideo { playback.show(video) }
        let host = NSHostingView(rootView: ScreencastRecordingReviewView(model: model, playback: playback))
        host.sizingOptions = [.minSize]
        recordingWindow.contentView = host
        recordingWindow.showActions(for: model)
        if let visibleFrame = screen()?.visibleFrame {
            recordingWindow.setFrame(ScreencastRecordingReviewWindow.frame(in: visibleFrame), display: false)
        }
        guard ordersPanelIn else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if recordingWindow.isMiniaturized { recordingWindow.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        recordingWindow.makeKeyAndOrderFront(nil)
        // Nothing has the keyboard at first, so Space plays the recording at once. Return and Escape
        // are the key monitor's either way.
        recordingWindow.makeFirstResponder(nil)
    }

    /// Closes the panel or window without a choice, which saves the capture. An editor open on it
    /// stays open.
    func close() async {
        guard let model else { return }
        await model.close()
        // A capture whose model couldn't finish still leaves the panel.
        if self.model === model { dismiss() }
    }

    /// The editor closed with the panel still open: the panel takes the keyboard back, so Return
    /// saves here rather than reaching the app the editor gave the front back to. That app's
    /// activation can land a moment later and take the keyboard, so the panel takes it again then,
    /// once, within a second. It's a non-activating panel's key focus, as when the panel first shows,
    /// so Keybumps doesn't come to the front.
    private func returnKeyboard() {
        takeKeyboard(panel)
        removeActivationObserver()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let review = self else { return }
                review.removeActivationObserver()
                if review.model != nil { review.takeKeyboard(review.panel) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.removeActivationObserver() }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// The app's way to take the keyboard back: only for a panel on screen.
    static func makeKeyIfShown(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        panel.makeKey()
    }

    private func dismiss() {
        removeActivationObserver()
        removeKeyMonitor()
        playback?.stop()
        playback = nil
        let wasRecording = model?.input.isVideo == true
        model = nil
        // The view stays until the next capture replaces it: it may be in the middle of a click.
        guard wasRecording else { return panel.orderOut(nil) }
        let hadKeyboard = recordingWindow.isKeyWindow
        recordingWindow.orderOut(nil)
        if hadKeyboard { previousApp?.activate() }
        previousApp = nil
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
        let key = action(forKey: event.keyCode, modifiers: event.modifierFlags, in: event.window)
        return perform(key, isRepeat: event.isARepeat) ? nil : event
    }

    /// What a key pressed in `window` does, given what has its keyboard: nothing outside the
    /// review's own panel or window.
    func action(forKey keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow?) -> ScreencastReviewKey {
        guard let model, let window, window === (model.input.isVideo ? recordingWindow : panel) else { return .pass }
        return ScreencastReviewKey.action(
            keyCode: keyCode,
            modifiers: modifiers,
            isComposing: (window.firstResponder as? NSTextView)?.hasMarkedText() == true,
            isConfirmingDiscard: model.isConfirmingDiscard,
            isEditing: model.isEditing,
            playsRecording: model.input.isVideo,
            isClaimed: OwnWindowKeyClaims.shared.isClaimed(keyCode: keyCode, modifiers: modifiers)
        )
    }

    /// Does what a key asks, and says whether it took the key. A held key acts once: Space plays or
    /// pauses once, and a held Return or Escape saves once.
    @discardableResult
    func perform(_ key: ScreencastReviewKey, isRepeat: Bool = false) -> Bool {
        guard let model else { return false }
        switch key {
        case .pass: return false
        case .ignore: break
        case .save: if !isRepeat { Task { await model.save() } }
        case .close: if !isRepeat { Task { await self.close() } }
        case .keep: model.keep()
        case .togglePlay: if !isRepeat { playback?.togglePlay() }
        }
        return true
    }
}

/// What a key does in the review. Return saves and Escape closes, which saves too; while the
/// discard question is up, Escape keeps the capture and Return does nothing, so a key never
/// deletes. While the Screenshot Editor is open on the screenshot, neither does anything, so its
/// markup is never thrown away. In a recording's window, Space plays and pauses, as in Snapzy's
/// `VideoEditorWindow`. A text field still composing (an input method's marked text) keeps its
/// keys, and a key claimed in Keybumps's own windows
/// (`OwnWindowKeyClaims`), such as Escape while the next recording draws, is left to what claims it.
enum ScreencastReviewKey: Equatable {
    case save
    case close
    case keep
    /// Space in a recording's window.
    case togglePlay
    /// Swallowed.
    case ignore
    /// Left to the panel's controls.
    case pass

    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]
    static let spaceKeyCode: UInt16 = 49

    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isComposing: Bool,
        isConfirmingDiscard: Bool,
        isEditing: Bool = false,
        playsRecording: Bool = false,
        isClaimed: Bool = false
    ) -> ScreencastReviewKey {
        guard !isClaimed, !isComposing,
              modifiers.intersection([.command, .control, .option]).isEmpty else { return .pass }
        let isEscape = keyCode == escapeKeyCode
        let isReturn = returnKeyCodes.contains(keyCode)
        if isEditing, isEscape || isReturn { return .ignore }
        if keyCode == spaceKeyCode {
            return playsRecording && !modifiers.contains(.shift) ? .togglePlay : .pass
        }
        if isEscape { return isConfirmingDiscard ? .keep : .close }
        if isReturn { return isConfirmingDiscard ? .ignore : .save }
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

/// A recording's player, `AVPlayerView` with its own controls for play, pause, and scrubbing.
@MainActor
final class ScreencastReviewPlayback {
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

    /// Shows `video`, unless it already shows.
    func show(_ video: ScreencastVideo) {
        let url = video.forSharing
        guard shown != url || player.currentItem == nil else { return }
        shown = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    func pause() { player.pause() }

    var isPlaying: Bool { player.rate != 0 }

    /// Space: plays or pauses. At the end of the recording, it plays from the start again.
    func togglePlay() {
        guard let item = player.currentItem else { return }
        if isPlaying { return player.pause() }
        // Within a frame or so of it: the player stops at about the end.
        if item.duration.isNumeric, CMTimeSubtract(item.duration, player.currentTime()).seconds < 0.05 {
            player.seek(to: .zero)
        }
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        shown = nil
    }
}
