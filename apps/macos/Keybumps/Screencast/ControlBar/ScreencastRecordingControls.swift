import AppKit
import Observation

/// What Screencast offers while it records: the control bar on the recorded screen, the time beside
/// the menu bar icon with Stop and Pause at the top of its menu, and the recording shortcuts (Pause
/// & Resume, Stop, Discard, and Draw), which are registered only while it records, so their keys
/// work normally the rest of the time. `ScreencastModule` holds one and attaches it to its
/// `ScreencastController` once it makes it; everything here acts through the controller.
///
/// The bar goes up as the recording starts (`.starting`), before the recorder reads what's on
/// screen, so it's already there when the recorder decides what to leave out. Its buttons wait until
/// it's recording. It stays hidden during the countdown.
@MainActor
final class ScreencastRecordingControls {
    /// The shortcuts that act on a recording, in the order Settings lists them.
    static let shortcuts: [CapabilityShortcut] = [.screencastPause, .screencastStop, .screencastDiscard, .screencastDraw]

    private let menuBar: CapabilityMenuBarStatus?
    private let placement: ScreencastControlBarPlacement
    private let barDisplay: @MainActor (ScreencastChoice.Region) -> ScreencastBarDisplay?
    private let ordersPanelIn: Bool
    private let confirmationTimeout: Duration
    /// The bar, once attached to a recording.
    private(set) var bar: ScreencastControlBar?
    /// The screens being recorded, and the area when only part of one is: where the bar goes.
    private var recordedRegions: @MainActor () -> [ScreencastChoice.Region] = { [] }
    private var recordedArea: @MainActor () -> CGRect? = { nil }

    private var registrar: GlobalShortcutCoordinator?
    private var bindings: [CapabilityShortcut: ShortcutBinding] = [:]
    private var isEnabled = false
    /// Whether the menu bar is watching the recording for changes now.
    private var watchesMenuBar = false

    /// - Parameters:
    ///   - menuBar: Screencast's part of the menu bar item; nil leaves it alone.
    ///   - placement: Where the bar's positions are kept.
    ///   - barDisplay: The display to show the bar on for a recorded screen; tests pass their own.
    ///   - ordersPanelIn: False keeps the bar's panel off screen, as under the unit-test host.
    ///   - confirmationTimeout: How long Restart's and Discard's questions wait for an answer.
    init(
        menuBar: CapabilityMenuBarStatus?,
        placement: ScreencastControlBarPlacement,
        barDisplay: @escaping @MainActor (ScreencastChoice.Region) -> ScreencastBarDisplay = ScreencastRecordingControls.display(for:),
        ordersPanelIn: Bool = !UnitTestHost.isActive,
        confirmationTimeout: Duration = ScreencastControlBarModel.confirmationTimeout
    ) {
        self.menuBar = menuBar
        self.placement = placement
        self.barDisplay = barDisplay
        self.ordersPanelIn = ordersPanelIn
        self.confirmationTimeout = confirmationTimeout
    }

    // MARK: Attaching

    /// Hangs the controls on `controller`'s phase, as one of its phase observers, so whatever else
    /// watches the phase, added before or after, is told too.
    @available(macOS 15, *)
    func attach(to controller: ScreencastController) {
        controller.addPhaseObserver { [weak self] phase in self?.phaseChanged(phase) }
        attach(
            to: controller,
            regions: { [weak controller] in controller?.choice?.regions ?? [] },
            area: { [weak controller] in controller?.choice?.area?.rect }
        )
    }

    /// Makes the bar for `recording`. Its phase changes then come through `phaseChanged(_:)`.
    func attach(
        to recording: any ScreencastBarRecording,
        regions: @escaping @MainActor () -> [ScreencastChoice.Region],
        area: @escaping @MainActor () -> CGRect?
    ) {
        bar?.hide()
        bar = ScreencastControlBar(
            recording: recording,
            placement: placement,
            ordersPanelIn: ordersPanelIn,
            confirmationTimeout: confirmationTimeout
        )
        recordedRegions = regions
        recordedArea = area
        phaseChanged(recording.phase)
    }

    /// From the start until the recording ends, the bar shows; while recording or paused, the
    /// shortcuts work and the menu bar has the time.
    func phaseChanged(_ phase: ScreencastPhase) {
        guard let bar else { return }
        if Self.showsBar(in: phase) {
            if !bar.isShown, let display = displayForBar() {
                bar.show(on: display, avoiding: recordedArea())
            }
        } else if bar.isShown {
            bar.hide()
        }
        updateShortcuts()
        refreshMenuBar()
    }

    /// Whether the bar is up: from `.starting`, so it's on screen before the recorder reads what to
    /// leave out, through recording and paused. Not while picking or counting down.
    static func showsBar(in phase: ScreencastPhase) -> Bool {
        phase == .starting || phase.isRecording
    }

    /// The recorded screen under the pointer, or the first one recorded.
    private func displayForBar() -> ScreencastBarDisplay? {
        let regions = recordedRegions()
        let pointer = NSEvent.mouseLocation
        guard let region = regions.first(where: { $0.frame.contains(pointer) }) ?? regions.first else { return nil }
        return barDisplay(region)
    }

    /// The screen a region is on: the display it names, or, for the UI-test composition's made-up
    /// displays, the screen holding its middle. Without one, the region's own frame stands in.
    static func display(for region: ScreencastChoice.Region) -> ScreencastBarDisplay {
        let screens = NSScreen.screens
        let middle = CGPoint(x: region.frame.midX, y: region.frame.midY)
        let screen = screens.first { ScreencastBarDisplay.displayID(of: $0) == region.display }
            ?? screens.first { $0.frame.contains(middle) }
        return screen.flatMap(ScreencastBarDisplay.init(screen:))
            ?? ScreencastBarDisplay(key: ScreencastBarDisplay.key(for: region.display), visibleFrame: region.frame)
    }

    // MARK: Shortcuts

    /// Takes the recording shortcuts' bindings and whether Screencast is on, from `apply`.
    func apply(_ context: CapabilityContext) {
        registrar = context.shortcuts
        isEnabled = context.isEnabled(.screencast)
        bindings = [:]
        for shortcut in Self.shortcuts {
            bindings[shortcut] = context.preferences.capabilityShortcut(for: shortcut)
        }
        updateShortcuts()
    }

    /// Screencast is turning off: its recording shortcuts go now.
    func deactivate() {
        isEnabled = false
        updateShortcuts()
    }

    private func updateShortcuts() {
        let isRecording = isEnabled && (bar?.model.recording.phase.isRecording ?? false)
        for shortcut in Self.shortcuts {
            guard isRecording, let binding = bindings[shortcut] else {
                registrar?.unregister(owner: shortcut.ownerID)
                continue
            }
            registrar?.register(owner: shortcut.ownerID, binding: binding) { [weak self] in
                self?.perform(shortcut)
            }
        }
    }

    /// A recording shortcut, acting as the bar's button does. Discard asks on the bar, and discards
    /// when pressed again while it asks; Draw does nothing until drawing is supplied (#449).
    func perform(_ shortcut: CapabilityShortcut) {
        guard let model = bar?.model else { return }
        switch shortcut {
        case .screencastPause: model.togglePause()
        case .screencastStop: Task { await model.stop() }
        case .screencastDiscard: Task { await model.discardFromShortcut() }
        case .screencastDraw: model.toggleDrawing()
        default: break
        }
    }

    // MARK: Menu bar

    /// Shows the time recorded beside the menu bar icon, and Stop and Pause or Resume at the top of
    /// its menu, while recording, and keeps them up to date as the recording changes.
    private func refreshMenuBar() {
        guard let menuBar else { return }
        guard !watchesMenuBar else {
            updateMenuBar(menuBar)
            return
        }
        watchesMenuBar = true
        withObservationTracking {
            updateMenuBar(menuBar)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchesMenuBar = false
                self.refreshMenuBar()
            }
        }
    }

    private func updateMenuBar(_ menuBar: CapabilityMenuBarStatus) {
        guard let model = bar?.model, model.recording.phase.isRecording else {
            menuBar.clear()
            return
        }
        // Ahead of Timer's countdown and timers: what's recording is what to see.
        menuBar.set(title: model.timerText, spoken: model.spokenTime, items: Self.menuItems(for: model), takesPrecedence: true)
    }

    /// Stop Recording, then Pause or Resume Recording.
    static func menuItems(for model: ScreencastControlBarModel) -> [MenuBarItem] {
        [
            MenuBarItem(id: "screencast.stop", title: "Stop Recording", systemImage: "stop.circle") { [weak model] in
                Task { await model?.stop() }
            },
            MenuBarItem(
                id: "screencast.pause",
                title: model.isPaused ? "Resume Recording" : "Pause Recording",
                systemImage: model.isPaused ? "play.circle" : "pause.circle"
            ) { [weak model] in
                model?.togglePause()
            },
        ]
    }
}
