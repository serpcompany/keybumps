import AppKit
import AVKit
import SwiftUI

/// The review after each recording (#450), which asks what to do with it: a big standard window to
/// watch it in, with Discard, Copy, and Save (#475, `ScreencastRecordingReviewWindow`), and nothing
/// to type.
///
/// The flow that finishes captures makes one, calls `show` with each capture and the context read
/// when it started, and hears how each ended through `onFinish`. Captures take turns: one that
/// arrives while another is under review closes that one first, which saves it. A capture starting
/// does so before its picker opens (`makeWayForNextCapture()`), so the window is never over the
/// picker or the recording. After `shutDown()`, a capture still waiting is saved without showing.
@MainActor
final class ScreencastReviewPanel {
    let window = ScreencastRecordingReviewWindow()
    private(set) var model: ScreencastReviewModel?
    /// Called when the review is done with a capture.
    var onFinish: ((ScreencastReviewOutcome) -> Void)?

    private let repositories: ScreencastRepositoryMemory
    private let fileManager: FileManager
    private let pasteboard: NSPasteboard
    private let keepOutOfClipboardHistory: () -> Void
    private let screen: @MainActor () -> NSScreen?
    private let ordersPanelIn: Bool
    private let makePlayback: @MainActor () -> ScreencastReviewPlayback?
    private let fullKeyboardAccess: @MainActor () -> Bool
    /// The recording's player, while the window is up.
    private(set) var playback: ScreencastReviewPlayback?
    /// The app in front before the window took it, which gets it back after. It's kept while the
    /// window makes way for what comes next, which hands it back in its turn.
    private var previousApp: NSRunningApplication?
    /// The window is closing for the next review, which takes the front itself.
    private var isTakingTurns = false
    /// The window went for the next capture (`makeWayForNextCapture()`), until its capture is saved.
    private(set) var isMakingWay = false
    /// The window had the keyboard when it went for the next capture: `previousApp` gets the front
    /// back once the picker and the countdown are done (`captureUnderWay()`).
    private var owesFront = false
    private var keyMonitor: Any?
    /// The last capture's turn, which the next one waits for.
    private var turn: Task<Void, Never>?
    /// False after `shutDown()`, until `startAccepting()`.
    private(set) var isAccepting = true

    /// - Parameters:
    ///   - pasteboard: Where Copy writes: `.keybumps` for the app, a named pasteboard for a test.
    ///   - keepOutOfClipboardHistory: Marks Copy's write so Clipboard History skips it; the app
    ///     passes `ClipboardHistoryService.suppressCurrentChange`.
    ///   - screen: Where the window shows: the screen with the pointer.
    ///   - ordersPanelIn: False keeps the window off screen, as under the unit-test host.
    ///   - makePlayback: The recording's player, none under the unit-test host unless a test asks.
    ///   - fullKeyboardAccess: Whether Tab reaches buttons (Keyboard Navigation in System Settings),
    ///     so a toolbar button can have the keyboard.
    init(
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard,
        keepOutOfClipboardHistory: @escaping () -> Void,
        screen: @escaping @MainActor () -> NSScreen? = ScreencastReviewPanel.screenWithPointer,
        ordersPanelIn: Bool = !UnitTestHost.isActive,
        makePlayback: @escaping @MainActor () -> ScreencastReviewPlayback? = {
            UnitTestHost.isActive ? nil : ScreencastReviewPlayback()
        },
        fullKeyboardAccess: @escaping @MainActor () -> Bool = { NSApp.isFullKeyboardAccessEnabled }
    ) {
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.screen = screen
        self.ordersPanelIn = ordersPanelIn
        self.makePlayback = makePlayback
        self.fullKeyboardAccess = fullKeyboardAccess
        window.onClose = { [weak self] in
            Task { await self?.close() }
        }
    }

    /// A capture is under review in the window, not one that made way and is still being saved.
    var isShown: Bool { model != nil && !isMakingWay }

    /// Shows the window for `input` once the captures before it are done, guessing its repository
    /// from `context`, or from `contextRead` when it comes. It returns once the window is up, or the
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

    /// Screencast turned off: the capture under review is saved and the window closes. Captures still
    /// waiting are saved without showing.
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

    /// A capture is starting, before its picker opens: the window goes at once, so it's never over
    /// the picker or the recording and never takes their keys, and its capture is saved, as closing
    /// it does. If the window had the keyboard, the app in front before it gets the front back once
    /// the capture is under way or cancelled (`captureUnderWay()`): the picker takes the keyboard
    /// meanwhile.
    func makeWayForNextCapture() {
        guard model != nil, !isMakingWay else { return }
        isMakingWay = true
        owesFront = window.isKeyWindow
        // Another app has the front already: nothing to give back.
        if !owesFront { previousApp = nil }
        hideWindow()
        Task { await close() }
    }

    /// The capture that made the window go is recording, or was cancelled: the front goes back to
    /// the app that had it before the window, if Keybumps still has it.
    func captureUnderWay() {
        guard owesFront else { return }
        owesFront = false
        if NSApp.isActive, !isShown { previousApp?.activate() }
        if !isShown { previousApp = nil }
    }

    private func present(
        _ input: ScreencastReviewInput,
        context: ScreencastCaptureContext,
        contextRead: Task<ScreencastCaptureContext, Never>?
    ) async {
        // The next window takes the front, and gives it back to the app before this one.
        isTakingTurns = true
        while model != nil {
            await close()
        }
        isTakingTurns = false
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
            keepOutOfClipboardHistory: keepOutOfClipboardHistory
        )
    }

    private func install(_ model: ScreencastReviewModel) {
        model.onFinish = { [weak self, weak model] outcome in
            guard let self, let model, self.model === model else { return }
            self.dismiss()
            self.onFinish?(outcome)
            self.isMakingWay = false
        }
        self.model = model
        installKeyMonitor()
        showWindow(model)
    }

    /// The window, filling the screen with the pointer, where the recording was just stopped. It's
    /// a standard window, so Keybumps comes to the front for it, and gives the front back when it
    /// closes, as the Screenshot Editor does.
    private func showWindow(_ model: ScreencastReviewModel) {
        let playback = makePlayback()
        self.playback = playback
        if let playback, let video = model.currentVideo { playback.show(video) }
        let host = NSHostingView(rootView: ScreencastRecordingReviewView(model: model, playback: playback))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.showActions(for: model)
        if let visibleFrame = screen()?.visibleFrame {
            window.setFrame(ScreencastRecordingReviewWindow.frame(in: visibleFrame), display: false)
        }
        owesFront = false
        guard ordersPanelIn else { return }
        // Keybumps in front means the window before had it, or the picker: the app before them
        // keeps its claim.
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Nothing has the keyboard at first, so Space plays the recording at once. Return and Escape
        // are the key monitor's either way.
        window.makeFirstResponder(nil)
    }

    /// Closes the window without a choice, which saves the capture.
    func close() async {
        guard let model else { return }
        await model.close()
        // A capture whose model couldn't finish still leaves the window.
        if self.model === model {
            dismiss()
            isMakingWay = false
        }
    }

    /// The review is done with its capture. `onFinish` comes next, with `isMakingWay` still saying
    /// whether the next capture closed it.
    private func dismiss() {
        model = nil
        let hadKeyboard = window.isKeyWindow
        hideWindow()
        // The next window, or the next capture's picker, takes the front: the app before keeps
        // its claim until they're done.
        guard !isTakingTurns, !isMakingWay else { return }
        if hadKeyboard { previousApp?.activate() }
        previousApp = nil
    }

    /// The window off screen, its keys and player gone. The view stays until the next capture
    /// replaces it: it may be in the middle of a click.
    private func hideWindow() {
        removeKeyMonitor()
        playback?.stop()
        playback = nil
        window.orderOut(nil)
    }

    // MARK: Placement

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

    /// What a key pressed in `keyWindow` does: nothing outside the review's own window, or once it
    /// made way for the next capture.
    func action(forKey keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in keyWindow: NSWindow?) -> ScreencastReviewKey {
        guard let model, !isMakingWay, let keyWindow, keyWindow === window else { return .pass }
        return ScreencastReviewKey.action(
            keyCode: keyCode,
            modifiers: modifiers,
            isComposing: (keyWindow.firstResponder as? NSTextView)?.hasMarkedText() == true,
            isConfirmingDiscard: model.isConfirmingDiscard,
            isClaimed: OwnWindowKeyClaims.shared.isClaimed(keyCode: keyCode, modifiers: modifiers),
            controlHasKeyboard: fullKeyboardAccess() && window.toolbarHas(keyWindow.firstResponder)
        )
    }

    /// Does what a key asks, and says whether it took the key. A held key acts once: Space plays or
    /// pauses once, and a held Return or Escape saves once.
    @discardableResult
    func perform(_ key: ScreencastReviewKey, isRepeat: Bool = false) -> Bool {
        guard let model, !isMakingWay else { return false }
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
/// deletes. Space plays and pauses, as in Snapzy's `VideoEditorWindow`. A toolbar button that has
/// the keyboard (Full Keyboard Access's Tab) keeps Space and Return, as any macOS button does,
/// though Return still never answers the discard question. A text field still composing (an input
/// method's marked text) keeps its keys, and a key claimed in Keybumps's own windows
/// (`OwnWindowKeyClaims`), such as Escape while the next recording draws, is left to what claims it.
enum ScreencastReviewKey: Equatable {
    case save
    case close
    case keep
    /// Space.
    case togglePlay
    /// Swallowed.
    case ignore
    /// Left to the window's controls.
    case pass

    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]
    static let spaceKeyCode: UInt16 = 49

    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isComposing: Bool,
        isConfirmingDiscard: Bool,
        isClaimed: Bool = false,
        controlHasKeyboard: Bool = false
    ) -> ScreencastReviewKey {
        guard !isClaimed, !isComposing,
              modifiers.intersection([.command, .control, .option]).isEmpty else { return .pass }
        if keyCode == spaceKeyCode { return modifiers.contains(.shift) || controlHasKeyboard ? .pass : .togglePlay }
        if keyCode == escapeKeyCode { return isConfirmingDiscard ? .keep : .close }
        if returnKeyCodes.contains(keyCode) {
            if isConfirmingDiscard { return .ignore }
            return controlHasKeyboard ? .pass : .save
        }
        return .pass
    }
}

/// The recording's player, `AVPlayerView` with its own controls for play, pause, and scrubbing.
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
