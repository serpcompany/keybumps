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
/// `ScreencastModule` attaches it to its `ScreencastController`, after the control bar's
/// `ScreencastRecordingControls`, and it hears the phase after them.
///
/// - When a video's phase leaves `.picking` (counting down or starting), the drawing goes up on the
///   recorded displays (`ScreencastOverlays`) with the tools as they were last left, and its
///   windows go to the recorder (`includeOverlayWindow`) before it starts, so the first frame can
///   have them. The control bar's Draw button and the Draw shortcut toggle it.
/// - With Show shortcuts on for the recording, it holds the key display (`KeyDisplay`) on the
///   recorded displays for the whole recording, showing shortcuts only, in the Keystrokes plugin's
///   style while the plugin is on, and gives the recorder those windows too. With Show shortcuts
///   off it never holds the display, and the display's windows never go to the recorder, so keys
///   the plugin shows (typing included, in All keys) stay out of the video.
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
    private var keys: (any ScreencastDrawingKeyRegistering)?

    private var choice: @MainActor () -> ScreencastChoice? = { nil }
    private var bar: @MainActor () -> ScreencastControlBar? = { nil }
    private var include: @MainActor (CGWindowID) async -> Void = { _ in }
    private var remove: @MainActor (CGWindowID) async -> Void = { _ in }
    private var drawingWindowIDs: Set<CGWindowID> = []
    private var keyWindowIDs: Set<CGWindowID> = []
    /// The recorder's updates, one at a time, in order.
    private var updates: Task<Void, Never>?

    /// - Parameters:
    ///   - keyDisplay: The shell's key display; nil shows no shortcuts.
    ///   - drawingMemory: Where the drawing tools' choices are kept between recordings.
    ///   - keystrokesConfiguration: The Keystrokes plugin's settings while it's on, else nil.
    ///   - displays: The displays a recording can be on, real or the UI-test composition's.
    ///   - ordersWindowsIn: False keeps the drawing's windows off screen, as under the unit-test host.
    ///   - watchesOwnKeys: Whether the drawing keys are also heard in Keybumps's own windows.
    init(
        keyDisplay: KeyDisplay?,
        drawingMemory: ScreencastDrawingMemory,
        keystrokesConfiguration: @escaping @MainActor () -> KeyDisplayConfiguration?,
        displays: @escaping @MainActor () -> [ScreencastOverlayDisplay] = { ScreencastOverlayDisplay.connected },
        ordersWindowsIn: Bool = !UnitTestHost.isActive,
        watchesOwnKeys: Bool = !UnitTestHost.isActive
    ) {
        self.keyDisplay = keyDisplay
        self.drawingMemory = drawingMemory
        self.keystrokesConfiguration = keystrokesConfiguration
        self.displays = displays
        self.ordersWindowsIn = ordersWindowsIn
        self.watchesOwnKeys = watchesOwnKeys
    }

    // MARK: Attaching

    /// Hangs the overlays on `controller`'s phase, after whatever already watches it, and gives
    /// their windows to its recorder. `bar` is the control bar the recording shows.
    @available(macOS 15, *)
    func attach(to controller: ScreencastController, bar: @escaping @MainActor () -> ScreencastControlBar?) {
        let previous = controller.onPhaseChange
        controller.onPhaseChange = { [weak self] phase in
            previous?(phase)
            self?.phaseChanged(phase)
        }
        let recorder = controller.recorder
        attach(
            choice: { [weak controller] in controller?.choice },
            bar: bar,
            include: { [weak recorder] id in await recorder?.includeOverlayWindow(id) },
            remove: { [weak recorder] id in await recorder?.removeOverlayWindow(id) }
        )
        phaseChanged(controller.phase)
    }

    /// The pieces of a capture flow the overlays follow. Its phase changes then come through
    /// `phaseChanged(_:)`.
    func attach(
        choice: @escaping @MainActor () -> ScreencastChoice?,
        bar: @escaping @MainActor () -> ScreencastControlBar?,
        include: @escaping @MainActor (CGWindowID) async -> Void,
        remove: @escaping @MainActor (CGWindowID) async -> Void
    ) {
        end()
        self.choice = choice
        self.bar = bar
        self.include = include
        self.remove = remove
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

    private func begin() {
        guard let choice = choice(), choice.kind == .video else { return }
        let recorded = Set(choice.regions.map(\.display))
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

        guard choice.showsShortcuts, let keyDisplay else { return }
        holdsKeyDisplay = true
        keyDisplay.acquire(
            .screencast,
            configuration: Self.keyConfiguration(plugin: keystrokesConfiguration(), displays: recorded),
            keepsWindowsOnScreen: true
        ) { [weak self] windows in
            self?.keyWindowIDs = Self.windowIDs(of: windows)
            self?.updateRecorder()
        }
    }

    private func connectBar() {
        guard let overlays, let bar = bar(), !overlays.isConnected(to: bar) else { return }
        overlays.connect(to: bar)
    }

    private func end() {
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

    /// What the key display shows while recording: shortcuts only, on the recorded displays, with
    /// no rings, in the Keystrokes plugin's style while it's on (`plugin`), or the defaults.
    static func keyConfiguration(plugin: KeyDisplayConfiguration?, displays: Set<CGDirectDisplayID>) -> KeyDisplayConfiguration {
        var configuration = plugin ?? KeyDisplayConfiguration()
        configuration.keys = .shortcutsOnly
        configuration.showsClicks = false
        configuration.displays = displays
        return configuration
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
