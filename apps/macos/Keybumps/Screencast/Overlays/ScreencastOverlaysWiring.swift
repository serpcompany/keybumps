import AppKit

extension KeyDisplayOwner {
    /// A Screencast recording, which holds the key display while it records with Show shortcuts on.
    static let screencast = KeyDisplayOwner("screencast")
}

/// The drawing tools' last choices (`screencast.drawingStyle`): the tool, the color, and whether
/// marks fade or stay, so the next recording draws the same way. Nothing drawn is kept.
struct ScreencastDrawingMemory {
    static let key = "screencast.drawingStyle"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The choices last made, or the defaults (a red pen whose marks fade).
    var style: ScreencastDrawingStyle {
        let stored = defaults.dictionary(forKey: Self.key) ?? [:]
        func value(_ key: String) -> String? { stored[key] as? String }
        let fallback = ScreencastDrawingStyle()
        return ScreencastDrawingStyle(
            tool: value("tool").flatMap(ScreencastDrawingTool.init(rawValue:)) ?? fallback.tool,
            color: value("color").flatMap(ScreencastDrawingColor.init(rawValue:)) ?? fallback.color,
            lifetime: value("lifetime").flatMap(ScreencastMarkLifetime.init(rawValue:)) ?? fallback.lifetime
        )
    }

    func save(_ style: ScreencastDrawingStyle) {
        defaults.set(
            ["tool": style.tool.rawValue, "color": style.color.rawValue, "lifetime": style.lifetime.rawValue],
            forKey: Self.key
        )
    }
}

/// Puts Screencast's overlays up around each video it records, and into the video (#449).
/// `ScreencastModule` attaches it to its `ScreencastController`, which tells it each phase
/// (`addPhaseObserver`) and each restart, just before it (`addWillRestartObserver`).
///
/// - When a video's phase leaves `.picking` (counting down or starting), the drawing goes up on the
///   recorded displays (`ScreencastOverlays`) with the tools as they were last left, and its
///   windows go to the recorder (`includeOverlayWindow`) before it starts, so the first frame can
///   have them. The control bar's Draw button and the Draw shortcut toggle it, and a restart
///   clears it and the keys on screen just before the new take starts, so it starts clean.
/// - With Show shortcuts on for the recording, it holds the key display (`KeyDisplay`) on the
///   recorded displays for the whole recording, showing shortcuts only, in the Keystrokes plugin's
///   style while the plugin is on, and gives the recorder those windows too. The keys sit inside
///   what's recorded: along the bottom of the area, or of the window, or of the screen for a
///   screen recording (`KeyDisplayConfiguration.anchor`). With Show shortcuts off it never holds
///   the display, and the display's windows never go to the recorder, so keys the plugin shows
///   (typing included, in All keys) stay out of the video.
/// - A window recording follows its window (`followWindow()`, 20 times a second, as often as the
///   recorder follows it): the keys move with it, and when it moves to another display, so do the
///   drawing and the keys. The two read the frame on their own timers, so for a moment after a
///   move the video can be on the new display before the overlays are.
/// - Click highlights are ScreenCaptureKit's, drawn into the video only
///   (`ScreencastOptions.showsMouseClicks`, which the controller sets from the choice); the key
///   display's rings stay off while recording, so a click isn't highlighted twice.
/// - At `.idle` it takes everything down, lets go of the key display, and takes its windows back
///   from the recorder, which keeps overlays from one recording to the next otherwise.
@MainActor
final class ScreencastOverlaysWiring {
    /// The overlays for the video under way: from the picker closing for it until the phase is
    /// `.idle` again.
    private(set) var overlays: ScreencastOverlays?
    /// Whether this recording holds the key display: Show shortcuts was on.
    private(set) var holdsKeyDisplay = false
    /// The windows given to the recorder: the drawing's, and the key display's while it's held.
    private(set) var includedWindowIDs: Set<CGWindowID> = []

    private let keyDisplay: KeyDisplay?
    private let drawingMemory: ScreencastDrawingMemory
    private let keystrokesConfiguration: @MainActor () -> KeyDisplayConfiguration?
    private let displays: @MainActor () -> [ScreencastOverlayDisplay]
    private let ordersWindowsIn: Bool
    private let watchesOwnKeys: Bool
    private let followInterval: TimeInterval?
    private var keys: (any ScreencastDrawingKeyRegistering)?
    /// A window's frame now, in AppKit's global space, or nil while it's off screen or closed.
    private var windowFrame: @MainActor (CGWindowID) -> CGRect? = { _ in nil }

    private var choice: @MainActor () -> ScreencastChoice? = { nil }
    private var bar: @MainActor () -> ScreencastControlBar? = { nil }
    private var include: @MainActor (CGWindowID) async -> Void = { _ in }
    private var remove: @MainActor (CGWindowID) async -> Void = { _ in }
    private var drawingWindowIDs: Set<CGWindowID> = []
    private var keyWindowIDs: Set<CGWindowID> = []
    /// The recorder's updates, one at a time, in order.
    private var updates: Task<Void, Never>?
    /// The recording's screens and the rect its keys sit in, which a followed window moves.
    private(set) var recordedDisplays: Set<CGDirectDisplayID> = []
    private(set) var anchor: CGRect?
    /// The window a window recording records, while it's followed.
    private(set) var followedWindow: CGWindowID?
    private var followTimer: Timer?

    /// - Parameters:
    ///   - keyDisplay: The shell's key display; nil shows no shortcuts.
    ///   - drawingMemory: Where the drawing tools' choices are kept between recordings.
    ///   - keystrokesConfiguration: The Keystrokes plugin's settings while it's on, else nil.
    ///   - displays: The displays a recording can be on, real or the UI-test composition's.
    ///   - ordersWindowsIn: False keeps the drawing's windows off screen, as under the unit-test host.
    ///   - watchesOwnKeys: Whether the drawing keys are also heard in Keybumps's own windows.
    ///   - followInterval: How often a recorded window's frame is read; nil for no timer (tests call
    ///     `followWindow()`).
    init(
        keyDisplay: KeyDisplay?,
        drawingMemory: ScreencastDrawingMemory,
        keystrokesConfiguration: @escaping @MainActor () -> KeyDisplayConfiguration?,
        displays: @escaping @MainActor () -> [ScreencastOverlayDisplay] = { ScreencastOverlayDisplay.connected },
        ordersWindowsIn: Bool = !UnitTestHost.isActive,
        watchesOwnKeys: Bool = !UnitTestHost.isActive,
        followInterval: TimeInterval? = 0.05
    ) {
        self.keyDisplay = keyDisplay
        self.drawingMemory = drawingMemory
        self.keystrokesConfiguration = keystrokesConfiguration
        self.displays = displays
        self.ordersWindowsIn = ordersWindowsIn
        self.watchesOwnKeys = watchesOwnKeys
        self.followInterval = followInterval
    }

    // MARK: Attaching

    /// Watches `controller`'s phase and restarts, and gives the overlays' windows to its recorder.
    /// `bar` is the control bar the recording shows, and `windowFrame` reads a recorded window's
    /// frame (AppKit's global space) as the recorder follows it.
    @available(macOS 15, *)
    func attach(
        to controller: ScreencastController,
        bar: @escaping @MainActor () -> ScreencastControlBar?,
        windowFrame: @escaping @MainActor (CGWindowID) -> CGRect? = { _ in nil }
    ) {
        controller.addPhaseObserver { [weak self] phase in self?.phaseChanged(phase) }
        controller.addWillRestartObserver { [weak self] in self?.willRestart() }
        let recorder = controller.recorder
        attach(
            choice: { [weak controller] in controller?.choice },
            bar: bar,
            include: { [weak recorder] id in await recorder?.includeOverlayWindow(id) },
            remove: { [weak recorder] id in await recorder?.removeOverlayWindow(id) },
            windowFrame: windowFrame
        )
        phaseChanged(controller.phase)
    }

    /// The pieces of a capture flow the overlays follow. Its phase changes then come through
    /// `phaseChanged(_:)`, and its restarts through `willRestart()`.
    func attach(
        choice: @escaping @MainActor () -> ScreencastChoice?,
        bar: @escaping @MainActor () -> ScreencastControlBar?,
        include: @escaping @MainActor (CGWindowID) async -> Void,
        remove: @escaping @MainActor (CGWindowID) async -> Void,
        windowFrame: @escaping @MainActor (CGWindowID) -> CGRect? = { _ in nil }
    ) {
        end()
        self.choice = choice
        self.bar = bar
        self.include = include
        self.remove = remove
        self.windowFrame = windowFrame
    }

    /// Takes the shortcut coordinator, which registers the drawing keys while drawing, from `apply`.
    func apply(_ context: CapabilityContext) {
        keys = context.shortcuts
    }

    // MARK: Following the recording

    func phaseChanged(_ phase: ScreencastPhase) {
        switch phase {
        case .idle:
            end()
        case .picking:
            break
        case .countingDown, .starting, .recording, .paused:
            if overlays == nil { begin() }
            connectBar()
        case .finishing:
            // Stopping: the pointer goes back to the apps while the files finish.
            overlays?.endDrawing()
        }
    }

    /// A restart is about to start a new take: the marks and the keys on screen go now, so its
    /// first frame has none.
    func willRestart() {
        overlays?.clear()
        if holdsKeyDisplay { keyDisplay?.clearLines() }
    }

    private func begin() {
        guard let choice = choice(), choice.kind == .video else { return }
        let recorded = Set(choice.regions.map(\.display))
        recordedDisplays = recorded
        anchor = Self.anchor(for: choice)
        if case .window(let id) = choice.target { followedWindow = id }
        let overlays = ScreencastOverlays(
            keys: keys,
            displays: displays,
            ordersWindowsIn: ordersWindowsIn,
            watchesOwnKeys: watchesOwnKeys
        )
        overlays.style = drawingMemory.style
        let memory = drawingMemory
        overlays.onStyleChange = { memory.save($0) }
        overlays.onOverlayWindowsChange = { [weak self] ids in
            self?.drawingWindowIDs = Set(ids)
            self?.updateRecorder()
        }
        self.overlays = overlays
        overlays.show(on: recorded)
        if choice.showsShortcuts, keyDisplay != nil {
            holdsKeyDisplay = true
            holdKeyDisplay()
        }
        followWindow()
        startFollowing()
    }

    /// Holds the key display, or updates the hold, for the recording's screens and anchor.
    private func holdKeyDisplay() {
        guard holdsKeyDisplay, let keyDisplay else { return }
        keyDisplay.acquire(
            .screencast,
            configuration: Self.keyConfiguration(plugin: keystrokesConfiguration(), displays: recordedDisplays, anchor: anchor),
            keepsWindowsOnScreen: true
        ) { [weak self] windows in
            self?.keyWindowIDs = Self.windowIDs(of: windows)
            self?.updateRecorder()
        }
    }

    // MARK: Following a window

    /// Reads the recorded window's frame: the keys move to its new bottom edge, and when most of it
    /// is on another display, the drawing and the keys move to that display. A window that's
    /// closed or off screen leaves everything where it was.
    func followWindow() {
        guard let id = followedWindow, let overlays, let frame = windowFrame(id), frame != anchor else { return }
        anchor = frame
        if let display = Self.display(showingMost: frame, among: displays()), [display.id] != recordedDisplays {
            recordedDisplays = [display.id]
            overlays.move(to: recordedDisplays)
        }
        holdKeyDisplay()
    }

    private func startFollowing() {
        guard followedWindow != nil, followTimer == nil, let followInterval else { return }
        let timer = Timer(timeInterval: followInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.followWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func connectBar() {
        guard let overlays, let bar = bar(), !overlays.isConnected(to: bar) else { return }
        overlays.connect(to: bar)
    }

    private func end() {
        followTimer?.invalidate()
        followTimer = nil
        followedWindow = nil
        anchor = nil
        recordedDisplays = []
        if holdsKeyDisplay {
            holdsKeyDisplay = false
            keyDisplay?.release(.screencast)
        }
        keyWindowIDs = []
        if let overlays {
            overlays.disconnectBar()
            overlays.hide()
            self.overlays = nil
        }
        drawingWindowIDs = []
        updateRecorder()
    }

    /// Gives the recorder the windows it doesn't have yet and takes back the ones that went. Each
    /// update waits for the one before, and the first ones are asked for before the recorder starts.
    private func updateRecorder() {
        let wanted = drawingWindowIDs.union(keyWindowIDs)
        let added = wanted.subtracting(includedWindowIDs).sorted()
        let removed = includedWindowIDs.subtracting(wanted).sorted()
        includedWindowIDs = wanted
        guard !added.isEmpty || !removed.isEmpty else { return }
        let previous = updates
        let include = include, remove = remove
        updates = Task {
            await previous?.value
            for id in added { await include(id) }
            for id in removed { await remove(id) }
        }
    }

    /// Waits for the recorder to have every update asked for so far; tests use it.
    func recorderUpdated() async {
        await updates?.value
    }

    // MARK: Rules

    /// What the key display shows while recording: shortcuts only, on the recorded displays, inside
    /// `anchor` when there is one, with no rings, in the Keystrokes plugin's style while it's on
    /// (`plugin`), or the defaults.
    static func keyConfiguration(
        plugin: KeyDisplayConfiguration?,
        displays: Set<CGDirectDisplayID>,
        anchor: CGRect? = nil
    ) -> KeyDisplayConfiguration {
        var configuration = plugin ?? KeyDisplayConfiguration()
        configuration.keys = .shortcutsOnly
        configuration.showsClicks = false
        configuration.displays = displays
        configuration.anchor = anchor
        return configuration
    }

    /// Where a recording's keys sit (AppKit's global space): the area, or the window's part of its
    /// screen until the window is read; nil for a screen recording, so they sit at the screen's
    /// bottom.
    static func anchor(for choice: ScreencastChoice) -> CGRect? {
        switch choice.target {
        case .area: choice.area?.rect ?? choice.regions.first?.frame
        case .window: choice.regions.first?.frame
        case .display, .everyDisplay: nil
        }
    }

    /// The display showing most of `frame`, if any shows part of it.
    static func display(showingMost frame: CGRect, among displays: [ScreencastOverlayDisplay]) -> ScreencastOverlayDisplay? {
        func shown(_ display: ScreencastOverlayDisplay) -> CGFloat {
            let part = display.frame.intersection(frame)
            return part.isNull ? 0 : part.width * part.height
        }
        guard let most = displays.max(by: { shown($0) < shown($1) }), shown(most) > 0 else { return nil }
        return most
    }

    /// The window numbers the Window Server gave `windows`, which match `SCWindow.windowID`.
    static func windowIDs(of windows: [NSWindow]) -> Set<CGWindowID> {
        Set(windows.compactMap { CGWindowID(exactly: $0.windowNumber).flatMap { $0 > 0 ? $0 : nil } })
    }

    /// The displays a recording's screens are on: each connected one as it is, and a screen that
    /// isn't connected (the UI-test composition's made-up halves of the main screen) by its frame,
    /// within the visible part of the screen it's on.
    static func displays(in layout: ScreencastScreenLayout, connected: [ScreencastOverlayDisplay]) -> [ScreencastOverlayDisplay] {
        layout.screens.map { screen in
            if let display = connected.first(where: { $0.id == screen.id }) { return display }
            let middle = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let visible = connected.first { $0.frame.contains(middle) }?.visibleFrame.intersection(screen.frame)
            return ScreencastOverlayDisplay(
                id: screen.id,
                frame: screen.frame,
                visibleFrame: visible.flatMap { $0.isNull || $0.isEmpty ? nil : $0 } ?? screen.frame
            )
        }
    }
}
