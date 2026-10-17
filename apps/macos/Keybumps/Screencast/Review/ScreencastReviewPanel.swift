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
    private let front: ScreencastReviewFront
    private let export: ScreencastEditExport
    /// The recording's player, while the window is up.
    private(set) var playback: ScreencastReviewPlayback?
    /// The app in front before the window took it, which gets it back after. It's kept while the
    /// window makes way for what comes next, which hands it back in its turn.
    private var previousApp: pid_t?
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
    ///     so a button in the bar can have the keyboard.
    ///   - front: Who has the front and the keyboard, which the window takes and gives back.
    ///   - export: How Save and Copy write a recording's edits (#517).
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
        fullKeyboardAccess: @escaping @MainActor () -> Bool = { NSApp.isFullKeyboardAccessEnabled },
        front: ScreencastReviewFront = .app,
        export: ScreencastEditExport = .movies
    ) {
        self.repositories = repositories
        self.export = export
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.screen = screen
        self.ordersPanelIn = ordersPanelIn
        self.makePlayback = makePlayback
        self.fullKeyboardAccess = fullKeyboardAccess
        self.front = front
        window.onClose = { [weak self] in
            Task { await self?.requestClose() }
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
        owesFront = front.windowHasKeyboard(window)
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
        guard !isShown else { return }
        if front.keybumpsIsActive(), let previousApp { front.activate(previousApp) }
        previousApp = nil
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
            keepOutOfClipboardHistory: keepOutOfClipboardHistory,
            export: export
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
        window.barTakesKeyboard = false
        window.contentView = host
        if let visibleFrame = screen()?.visibleFrame {
            window.setFrame(ScreencastRecordingReviewWindow.frame(in: visibleFrame), display: false)
        }
        owesFront = false
        // Keybumps in front means the window before had it, or the picker: the app before them
        // keeps its claim.
        if let app = front.otherAppInFront() { previousApp = app }
        guard ordersPanelIn else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Nothing has the keyboard at first, so Space plays the recording at once, even with Keyboard
        // Navigation on (`barTakesKeyboard`). Return and Escape are the key monitor's either way.
        window.makeFirstResponder(nil)
    }

    /// The close button, or Escape with no tool picked: with edits not yet saved, the bar asks first
    /// ("Save your edits?"); while they're being written, that stops. Otherwise it closes, which saves.
    func requestClose() async {
        guard let model, !isMakingWay else { return }
        if model.isExporting { return model.cancelExport() }
        if model.asksBeforeClosing { return model.askToSaveEdits() }
        await close()
    }

    /// Closes the window without a choice, which saves the capture as it was recorded.
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
        let hadKeyboard = front.windowHasKeyboard(window)
        hideWindow()
        // The next window, or the next capture's picker, takes the front: the app before keeps
        // its claim until they're done.
        guard !isTakingTurns, !isMakingWay else { return }
        if hadKeyboard, let previousApp { front.activate(previousApp) }
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
        let key = action(
            forKey: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers, in: event.window
        )
        return perform(key, isRepeat: event.isARepeat) ? nil : event
    }

    /// What a key pressed in `keyWindow` does: nothing outside the review's own window, or once it
    /// made way for the next capture. `characters` are the key's, ignoring modifiers, as ⌘C reads.
    func action(
        forKey keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil, in keyWindow: NSWindow?
    ) -> ScreencastReviewKey {
        guard let model, !isMakingWay, let keyWindow, keyWindow === window else { return .pass }
        return ScreencastReviewKey.action(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters,
            isComposing: (keyWindow.firstResponder as? NSTextView)?.hasMarkedText() == true,
            isConfirmingDiscard: model.isConfirmingDiscard,
            isClaimed: OwnWindowKeyClaims.shared.isClaimed(keyCode: keyCode, modifiers: modifiers),
            controlHasKeyboard: fullKeyboardAccess() && window.barHas(keyWindow.firstResponder),
            editing: ScreencastReviewKey.Editing(
                tool: model.tool,
                isExporting: model.isExporting,
                isAskingToSaveEdits: model.isAskingToSaveEdits,
                hasExportFailure: model.exportFailure != nil,
                hasBlurs: !model.blurs.isEmpty
            )
        )
    }

    /// Does what a key asks, and says whether it took the key. A held key acts once: Space plays or
    /// pauses once, a held Return or Escape saves once, and a held ⌘C copies once. Undo and redo
    /// repeat while held, as in any Mac app.
    @discardableResult
    func perform(_ key: ScreencastReviewKey, isRepeat: Bool = false) -> Bool {
        guard let model, !isMakingWay else { return false }
        switch key {
        case .pass: return false
        case .ignore: break
        case .save: if !isRepeat { Task { await model.save() } }
        case .copy: if !isRepeat { Task { await model.copy() } }
        case .close: if !isRepeat { Task { await self.requestClose() } }
        case .keep: model.keep()
        case .togglePlay: if !isRepeat { playback?.togglePlay() }
        case .tab:
            window.barTakesKeyboard = true
            return false
        case .tool(let tool): if !isRepeat { model.pick(tool) }
        case .putToolDown: model.putToolDown()
        case .undo: model.undo()
        case .redo: model.redo()
        case .cutSelection: if !isRepeat { model.cutSelection() }
        case .markIn: model.markSelectionStart(at: playback?.recordingTime ?? 0)
        case .markOut: model.markSelectionEnd(at: playback?.recordingTime ?? 0)
        case .deleteBlur: if !isRepeat { model.deleteSelectedBlur() }
        case .selectNextBlur: model.selectNextBlur()
        case .cancelExport: model.cancelExport()
        case .dismissQuestion: model.dismissSaveQuestion()
        case .saveEdited: if !isRepeat { Task { await model.saveEdited() } }
        case .tryAgain: if !isRepeat { Task { await model.tryAgain() } }
        }
        return true
    }
}

/// What a key does in the review. Return saves, ⌘C copies, and Escape closes, which saves too;
/// while the discard question is up, Escape keeps the capture and Return and ⌘C do nothing, so a key
/// never deletes. Space plays and pauses, as in Snapzy's `VideoEditorWindow`. A button in the bar
/// that has the keyboard (Full Keyboard Access's Tab) keeps Space, which presses it, as Space does
/// any macOS button; none has it until Tab is pressed. Return still saves then: on macOS, Return is
/// the window's action, never the focused button's, and this window's is Save. A text field still
/// composing (an input method's marked text) keeps its keys, and a key claimed in Keybumps's own
/// windows (`OwnWindowKeyClaims`), such as Escape while the next recording draws, is left to what
/// claims it.
///
/// Editing (#517): a tool's number or letter picks it, ⌘Z and ⇧⌘Z undo and redo, and with Trim
/// picked, ⌫ cuts the selection and I and O start and end it at the playhead. With Blur picked, ⌫
/// deletes the picked blur and Tab picks the next one, while there are blurs and no control in the
/// bar has the keyboard. Escape puts the picked tool down before it closes anything. While "Save your edits?" is asked, Return saves the edits and
/// Escape goes back; while the edited recording is written, Escape stops it and only Space still
/// works; after it failed, Return tries again.
enum ScreencastReviewKey: Equatable {
    case save
    /// ⌘C, Copy's key.
    case copy
    case close
    case keep
    /// Space.
    case togglePlay
    /// Tab or Shift-Tab: from now on the bar's controls may take the keyboard, and the window moves
    /// it as usual.
    case tab
    /// Swallowed.
    case ignore
    /// Left to the window's controls.
    case pass
    /// A tool's number or letter: picks it, or puts it down.
    case tool(ScreencastEditTool)
    /// Escape with a tool picked.
    case putToolDown
    case undo
    case redo
    /// ⌫ with Trim picked: Cut Section.
    case cutSelection
    /// I and O with Trim picked: the selection starts, or ends, at the playhead.
    case markIn
    case markOut
    /// ⌫ with Blur picked: deletes the picked blur.
    case deleteBlur
    /// Tab with Blur picked: picks the next blur.
    case selectNextBlur
    /// Escape while the edited recording is written.
    case cancelExport
    /// Escape while "Save your edits?" is asked: back to editing.
    case dismissQuestion
    /// Return while "Save your edits?" is asked.
    case saveEdited
    /// Return after the edited recording couldn't be written.
    case tryAgain

    /// What the window is doing with its edits, which decides some keys.
    struct Editing: Equatable {
        var tool: ScreencastEditTool?
        var isExporting = false
        var isAskingToSaveEdits = false
        var hasExportFailure = false
        /// The shown display has blurs.
        var hasBlurs = false

        static let none = Editing()
    }

    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 76]
    static let spaceKeyCode: UInt16 = 49
    static let tabKeyCode: UInt16 = 48
    /// Delete (⌫) and Forward Delete.
    static let deleteKeyCodes: Set<UInt16> = [51, 117]
    /// ⌘C's character, read from the key ignoring modifiers, so it follows the keyboard layout.
    static let copyCharacter = "c"
    /// The C key (kVK_ANSI_C), ⌘C on a layout with no Latin letters, such as Russian, as for menus.
    static let copyKeyCode: UInt16 = 8
    /// ⌘Z's character, and the Z key (kVK_ANSI_Z) on a layout with no Latin letters.
    static let undoCharacter = "z"
    static let undoKeyCode: UInt16 = 6

    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String? = nil,
        isComposing: Bool,
        isConfirmingDiscard: Bool,
        isClaimed: Bool = false,
        controlHasKeyboard: Bool = false,
        editing: Editing = .none
    ) -> ScreencastReviewKey {
        guard !isClaimed, !isComposing else { return .pass }
        let held = modifiers.intersection([.command, .control, .option, .shift])
        let isAsking = isConfirmingDiscard || editing.isAskingToSaveEdits
        if editing.isExporting {
            if held.isEmpty, keyCode == escapeKeyCode { return .cancelExport }
            if held.isEmpty, keyCode == spaceKeyCode, !controlHasKeyboard { return .togglePlay }
            return keyCode == tabKeyCode ? .pass : .ignore
        }
        if held == .command, isCopyKey(keyCode: keyCode, characters: characters) {
            return isAsking ? .ignore : .copy
        }
        if held == .command || held == [.command, .shift], isLatinKey(undoCharacter, keyCode: keyCode, letterKeyCode: undoKeyCode, characters: characters) {
            guard !isAsking else { return .ignore }
            return held.contains(.shift) ? .redo : .undo
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return .pass }
        if keyCode == tabKeyCode {
            let picksBlur = editing.tool == .blur && editing.hasBlurs && !isAsking && !controlHasKeyboard && !modifiers.contains(.shift)
            return picksBlur ? .selectNextBlur : .tab
        }
        if keyCode == spaceKeyCode { return modifiers.contains(.shift) || controlHasKeyboard ? .pass : .togglePlay }
        if keyCode == escapeKeyCode {
            if isConfirmingDiscard { return .keep }
            if editing.isAskingToSaveEdits { return .dismissQuestion }
            return editing.tool == nil ? .close : .putToolDown
        }
        if returnKeyCodes.contains(keyCode) {
            if isConfirmingDiscard { return .ignore }
            if editing.isAskingToSaveEdits { return .saveEdited }
            return editing.hasExportFailure ? .tryAgain : .save
        }
        guard !isAsking, !modifiers.contains(.shift) else { return .pass }
        if editing.tool == .blur, deleteKeyCodes.contains(keyCode) { return .deleteBlur }
        if editing.tool == .trim {
            if deleteKeyCodes.contains(keyCode) { return .cutSelection }
            switch characters?.lowercased() {
            case "i": return .markIn
            case "o": return .markOut
            default: break
            }
        }
        if let characters, let tool = ScreencastEditTool.matching(key: characters) { return .tool(tool) }
        return .pass
    }

    /// The layout's C, wherever it is, or, on a layout with no Latin letters, the C key.
    static func isCopyKey(keyCode: UInt16, characters: String?) -> Bool {
        isLatinKey(copyCharacter, keyCode: keyCode, letterKeyCode: copyKeyCode, characters: characters)
    }

    /// The layout's `letter`, wherever it is, or, on a layout with no Latin letters, the key at
    /// `letterKeyCode`, as menus read it.
    static func isLatinKey(_ letter: String, keyCode: UInt16, letterKeyCode: UInt16, characters: String?) -> Bool {
        let characters = characters?.lowercased() ?? ""
        guard characters.unicodeScalars.contains(where: \.isASCII) else { return keyCode == letterKeyCode }
        return characters == letter
    }
}

/// Who has the front and the keyboard, as the review window takes them and gives them back: macOS
/// for the app, a stand-in for a test, which also records the apps given the front.
struct ScreencastReviewFront {
    /// The app in front, unless it's Keybumps.
    var otherAppInFront: @MainActor () -> pid_t?
    /// Keybumps is the active app.
    var keybumpsIsActive: @MainActor () -> Bool
    /// The review's window has the keyboard.
    var windowHasKeyboard: @MainActor (NSWindow) -> Bool
    /// Gives the front to an app.
    var activate: @MainActor (pid_t) -> Void

    /// macOS's. Under the unit-test host it reads no app and activates none, and the window never
    /// has the keyboard there anyway.
    static var app: ScreencastReviewFront {
        ScreencastReviewFront(
            otherAppInFront: {
                guard !UnitTestHost.isActive, let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return front.processIdentifier
            },
            keybumpsIsActive: { NSApp.isActive },
            windowHasKeyboard: { $0.isKeyWindow },
            activate: { app in
                guard !UnitTestHost.isActive else { return }
                NSRunningApplication(processIdentifier: app)?.activate()
            }
        )
    }
}

/// The recording's player, `AVPlayerView` with its own controls for play, pause, and scrubbing. With
/// edits (#517), it plays the edited recording (`ScreencastEditComposition`) and says where it is in
/// the recording's own time, for the timeline; while a trim handle is dragged, it shows the frame
/// under it (`previewFrame`), and it makes the timeline's strip of frames (`filmstrip`).
@MainActor
@Observable
final class ScreencastReviewPlayback {
    /// Frames in the timeline's strip.
    static let filmstripCount = 24

    @ObservationIgnored let view = AVPlayerView()
    /// Where the player is, in the recording's time.
    private(set) var recordingTime: Double = 0
    /// The frame under a dragged trim handle, shown over the player until the drag ends.
    private(set) var previewFrame: CGImage?
    /// Frames across the shown video, evenly spaced, for the timeline's strip.
    private(set) var filmstrip: [CGImage] = []
    /// Why the player shows no picture, rather than the one it had: nil while it plays.
    private(set) var blank: Blank?

    enum Blank: Equatable {
        /// The shown display has nothing in the kept part: its stream stopped before it.
        case nothingKept
        /// The edited recording couldn't be made from the file.
        case cannotPlay

        var message: String {
            switch self {
            case .nothingKept: "Nothing of this display is in the kept part."
            case .cannotPlay: "Couldn’t play the edited recording."
            }
        }
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var shown: URL?
    /// The edits the shown item plays, and the parts of the recording it plays.
    @ObservationIgnored private var shownEdits: ScreencastRecordingEdits?
    @ObservationIgnored private var shownDisplay = 0
    @ObservationIgnored private var shownCrops = true
    @ObservationIgnored private var kept: [ScreencastTimeRange] = []
    /// Counts each `show`, so an edited item made too late for the latest is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var previewGenerator: AVAssetImageGenerator?
    @ObservationIgnored private var filmstripTask: Task<Void, Never>?

    init() {
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.setAccessibilityIdentifier(ScreencastReviewID.player)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: time) }
        }
    }

    /// Shows `video`, unless it already shows.
    func show(_ video: ScreencastVideo) {
        show(video, display: 0, edits: nil)
    }

    /// Shows `display`'s `video` with `edits`, keeping the place in the recording; the recording as
    /// it was when they change nothing. `crops` false shows the whole frame, for placing the crop.
    func show(_ video: ScreencastVideo, display: Int, edits: ScreencastRecordingEdits?, crops: Bool = true) {
        let url = video.forSharing
        let edits = edits.flatMap { Self.changes(display: display, of: $0, crops: crops) ? $0 : nil }
        guard shown != url || player.currentItem == nil || shownEdits != edits || shownDisplay != display || shownCrops != crops else { return }
        let isNewVideo = shown != url
        let place = recordingTime
        shown = url
        shownEdits = edits
        shownDisplay = display
        shownCrops = crops
        generation += 1
        previewGenerator = nil
        blank = nil
        if isNewVideo { makeFilmstrip(of: url, duration: video.duration) }
        guard let edits else {
            kept = [ScreencastTimeRange(start: 0, end: video.duration)]
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            if !isNewVideo { seek(toRecordingTime: place) }
            return
        }
        guard edits.keepsSomething(ofVideoLasting: video.duration) else { return showBlank(.nothingKept) }
        let generation = generation
        Task { [weak self] in
            let edit = try? await ScreencastEditComposition.make(source: url, edits: edits, display: display, crops: crops)
            guard let self, self.generation == generation else { return }
            guard let edit else { return self.showBlank(.cannotPlay) }
            let item = AVPlayerItem(asset: edit.composition)
            if edit.editor.changesFrames { item.videoComposition = edit.videoComposition }
            self.kept = edits.keptRanges(within: video.duration)
            self.player.replaceCurrentItem(with: item)
            self.seek(toRecordingTime: place)
        }
    }

    /// No picture, and why, keeping the place in the recording for the next one.
    private func showBlank(_ reason: Blank) {
        kept = []
        player.replaceCurrentItem(with: nil)
        blank = reason
    }

    /// Whether `edits` change what `display`'s video plays; its crop only if `crops`.
    static func changes(display: Int, of edits: ScreencastRecordingEdits, crops: Bool = true) -> Bool {
        guard !edits.isTrimmed else { return true }
        guard edits.displays.indices.contains(display) else { return false }
        let displayEdits = edits.displays[display]
        return !displayEdits.blurs.isEmpty || (crops && displayEdits.crop != nil)
    }

    func pause() { player.pause() }

    var isPlaying: Bool { player.rate != 0 }

    /// How long what the player plays is, once it knows: the edited recording's length with edits.
    var playingLength: Double? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return nil }
        return duration.seconds
    }

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

    /// Goes to `time` in the recording, or, if it's trimmed or cut off, to where the edited
    /// recording goes on.
    func seek(toRecordingTime time: Double) {
        // Nothing plays: the place is kept for what plays next.
        guard !kept.isEmpty else { return recordingTime = max(time, 0) }
        let edited = kept.editedTime(forRecordingTime: time)
        recordingTime = kept.recordingTime(forEditedTime: edited) ?? 0
        player.seek(to: ScreencastEditComposition.time(edited), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Shows the frame at `time` in the recording over the player, as a trim handle is dragged.
    func preview(atRecordingTime time: Double) {
        guard let shown else { return }
        let generator = previewGenerator ?? {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: shown))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            previewGenerator = generator
            return generator
        }()
        generator.cancelAllCGImageGeneration()
        Task { [weak self] in
            guard let frame = try? await generator.image(at: ScreencastEditComposition.time(time)).image else { return }
            guard let self, self.previewGenerator === generator else { return }
            self.previewFrame = frame
        }
    }

    /// The drag ended: the player shows again.
    func endPreview() {
        previewGenerator?.cancelAllCGImageGeneration()
        previewFrame = nil
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        shown = nil
        shownEdits = nil
        kept = []
        blank = nil
        generation += 1
        filmstripTask?.cancel()
        filmstrip = []
        endPreview()
    }

    private func playerMoved(to time: CMTime) {
        guard time.isNumeric, !kept.isEmpty else { return }
        recordingTime = kept.recordingTime(forEditedTime: time.seconds) ?? 0
    }

    private func makeFilmstrip(of url: URL, duration: Double) {
        filmstripTask?.cancel()
        filmstrip = []
        guard duration > 0 else { return }
        filmstripTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 150)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            let count = Self.filmstripCount
            let times = (0..<count).map { ScreencastEditComposition.time(duration * (Double($0) + 0.5) / Double(count)) }
            var frames: [CGImage] = []
            for await result in generator.images(for: times) {
                guard !Task.isCancelled else { return }
                if let image = try? result.image { frames.append(image) }
            }
            guard let self, !Task.isCancelled else { return }
            self.filmstrip = frames
        }
    }
}
