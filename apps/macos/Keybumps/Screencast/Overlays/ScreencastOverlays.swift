import AppKit
import Carbon.HIToolbox
import Observation

/// Where the overlays register the keys that work only while drawing. `GlobalShortcutCoordinator`
/// is the one in the app, as for Dictation's Escape; tests pass a fake.
@MainActor
protocol ScreencastDrawingKeyRegistering: AnyObject {
    @discardableResult
    func register(owner: String, binding: ShortcutBinding, handler: @escaping () -> Void) -> Bool
    func unregister(owner: String)
}

extension GlobalShortcutCoordinator: ScreencastDrawingKeyRegistering {}

/// The keys that work only while drawing. They're taken from every app while drawing, as
/// Dictation's Escape is while it records, and given back when drawing ends.
enum ScreencastDrawingKey: String, CaseIterable {
    /// Escape: stops drawing. The marks stay until they fade or are cleared.
    case end
    /// Delete: clears every mark.
    case clear
    /// ⌘Z: removes the last mark.
    case undo

    var owner: String { "screencast.draw.\(rawValue)" }

    var binding: ShortcutBinding {
        switch self {
        case .end: ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, displayName: "Escape")
        case .clear: ShortcutBinding(keyCode: UInt32(kVK_Delete), modifiers: 0, displayName: "⌫")
        case .undo: ShortcutBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey), displayName: "⌘Z")
        }
    }

    /// The drawing key a key-down in Keybumps's own windows is: exactly its key and modifiers.
    static func matching(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ScreencastDrawingKey? {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        return allCases.first { UInt32(keyCode) == $0.binding.keyCode && held == $0.modifierFlags }
    }

    /// The binding's modifiers as AppKit's flags.
    private var modifierFlags: NSEvent.ModifierFlags {
        let carbon = Int(binding.modifiers)
        var flags: NSEvent.ModifierFlags = []
        if carbon & cmdKey != 0 { flags.insert(.command) }
        if carbon & shiftKey != 0 { flags.insert(.shift) }
        if carbon & optionKey != 0 { flags.insert(.option) }
        if carbon & controlKey != 0 { flags.insert(.control) }
        return flags
    }
}

/// The drawing Screencast shows on screen while recording, for the video (#449).
/// `ScreencastOverlaysWiring` makes one per recording, shows it on the recorded displays as the
/// recording starts, gives the recorder its windows (`overlayWindowIDs` and
/// `onOverlayWindowsChange`, for `ScreencastRecorder.includeOverlayWindow`), connects the control
/// bar's Draw button, and hides it when the recording ends.
///
/// - Drawing is on or off. Off, the drawing layer lets every click through; on, it takes the
///   pointer, a border shows around each recorded display, the drawing tools show above the
///   control bar, and Escape, Delete, and ⌘Z stop drawing, clear, and undo. Those keys are hot keys
///   while drawing; when one can't be registered (Dictation's Escape is taken while it records),
///   it still works while one of Keybumps's own windows has the keyboard, and the Draw button and
///   shortcut always end drawing.
/// - Marks are drawn with the tools' choice of pen, arrow, highlighter, or rectangle, a color, and
///   whether they fade a few seconds after they're drawn or stay until cleared.
/// - The drawing layer's windows are in the video; the border and the tools aren't.
///
/// Click highlights aren't drawn here: ScreenCaptureKit draws them into the video only
/// (`ScreencastOptions.showsMouseClicks`, from Screencast's Highlight clicks setting). Rings on
/// screen, after ClickLight, can come later as another overlay.
@MainActor
@Observable
final class ScreencastOverlays {
    /// Between `show` and `hide`.
    private(set) var isShown = false
    /// Whether the drawing layer takes the pointer.
    private(set) var isDrawing = false
    /// How the next mark is drawn: the drawing tools' choices. Changing them never changes a mark
    /// already drawn.
    var style = ScreencastDrawingStyle() {
        didSet { if style != oldValue { onStyleChange?(style) } }
    }
    /// Whether there's a mark on screen to undo or clear.
    private(set) var hasMarks = false

    /// Called with the drawing layer's windows whenever they change: when the overlays show, when a
    /// recorded display goes or comes back, and with none when they hide.
    @ObservationIgnored var onOverlayWindowsChange: (([CGWindowID]) -> Void)?
    /// Called when drawing starts or stops, however it did: the Draw button, Escape, or `hide`.
    @ObservationIgnored var onDrawingChange: ((Bool) -> Void)?
    /// Called when the tools' choices change, so they can be remembered for the next recording.
    @ObservationIgnored var onStyleChange: ((ScreencastDrawingStyle) -> Void)?

    /// The marks, read at the overlays' clock.
    @ObservationIgnored private(set) var drawing = ScreencastDrawing()
    @ObservationIgnored let layer: ScreencastDrawingLayer
    @ObservationIgnored let toolbar: ScreencastDrawingToolbar

    @ObservationIgnored private let keys: (any ScreencastDrawingKeyRegistering)?
    @ObservationIgnored private let connectedDisplays: @MainActor () -> [ScreencastOverlayDisplay]
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let tickInterval: TimeInterval?
    @ObservationIgnored private let watchesOwnKeys: Bool
    /// Hears the drawing keys pressed in Keybumps's own windows, while drawing.
    @ObservationIgnored private var ownKeyMonitor: Any?
    /// The recorded displays, whichever of them are connected.
    @ObservationIgnored private var recordedDisplays: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private weak var bar: ScreencastControlBar?
    /// Moves the tools with the bar while drawing.
    @ObservationIgnored private var barMoveObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - keys: Where Escape, Delete, and ⌘Z are registered while drawing; nil for none.
    ///   - displays: The connected displays, which the recorded ones are found among.
    ///   - clock: Seconds that only go forward, which fading is timed by.
    ///   - tickInterval: How often fading marks are redrawn; nil for no timer (tests call `tick()`).
    ///   - ordersWindowsIn: False keeps every window off screen, as under the unit-test host.
    ///   - watchesOwnKeys: Whether the drawing keys are also heard in Keybumps's own windows; never
    ///     under the unit-test host.
    init(
        keys: (any ScreencastDrawingKeyRegistering)? = nil,
        displays: @escaping @MainActor () -> [ScreencastOverlayDisplay] = { ScreencastOverlayDisplay.connected },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        tickInterval: TimeInterval? = 1.0 / 30,
        ordersWindowsIn: Bool = !UnitTestHost.isActive,
        watchesOwnKeys: Bool = !UnitTestHost.isActive
    ) {
        self.keys = keys
        connectedDisplays = displays
        self.clock = clock
        self.tickInterval = tickInterval
        self.watchesOwnKeys = watchesOwnKeys
        layer = ScreencastDrawingLayer(ordersWindowsIn: ordersWindowsIn)
        toolbar = ScreencastDrawingToolbar(ordersPanelIn: ordersWindowsIn)
        layer.delegate = self
        layer.onWindowsChange = { [weak self] ids in self?.onOverlayWindowsChange?(ids) }
        toolbar.overlays = self
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let barMoveObserver { NotificationCenter.default.removeObserver(barMoveObserver) }
        if let ownKeyMonitor { NSEvent.removeMonitor(ownKeyMonitor) }
    }

    /// The drawing layer's windows, which the recorder shows in the video. Stable from `show` to
    /// `hide` while the recorded displays stay connected.
    var overlayWindowIDs: [CGWindowID] { layer.windowIDs }

    // MARK: Showing

    /// Puts the overlays on `displays`, the ones being recorded, for the whole recording. The
    /// drawing layer lets clicks through until drawing starts.
    func show(on displays: Set<CGDirectDisplayID>) {
        recordedDisplays = displays
        isShown = true
        toolbar.show()
        refreshDisplays()
        observeScreens()
    }

    /// Takes everything off screen when the recording ends: drawing stops and every mark goes.
    func hide() {
        endDrawing()
        clearMarks()
        stopTicking()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        disconnectBar()
        layer.hide()
        toolbar.hide()
        recordedDisplays = []
        isShown = false
    }

    /// Moves the overlays to other recorded displays, as when a recorded window moves to another
    /// screen. Marks on a display that's left go with its window, so Undo and Clear count only
    /// marks that show.
    func move(to displays: Set<CGDirectDisplayID>) {
        guard isShown else { return }
        recordedDisplays = displays
        refreshDisplays()
    }

    /// Matches the drawing layer to the recorded displays that are connected now: a display that
    /// went loses its windows and its marks, and one that came back gets new windows.
    func refreshDisplays() {
        guard isShown else { return }
        let displays = connectedDisplays().filter { recordedDisplays.contains($0.id) }
        layer.show(on: displays)
        if !drawing.removeMarks(notOn: Set(displays.map(\.id))).isEmpty { marksChanged() }
        if displays.isEmpty, isDrawing { endDrawing() }
        if isDrawing { placeToolbar() }
    }

    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
    }

    // MARK: The control bar

    /// Gives the bar its Draw button, which toggles drawing, and keeps the button showing whether
    /// drawing is on. The drawing tools show just above the bar.
    func connect(to bar: ScreencastControlBar) {
        disconnectBar()
        self.bar = bar
        bar.isDrawing = isDrawing
        bar.onToggleDrawing = { [weak self] in self?.toggleDrawing() }
        barMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: bar.panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.barMoved() }
        }
    }

    /// Takes the Draw button off the bar again.
    func disconnectBar() {
        if let barMoveObserver { NotificationCenter.default.removeObserver(barMoveObserver) }
        barMoveObserver = nil
        guard let bar else { return }
        bar.onToggleDrawing = nil
        bar.isDrawing = false
        self.bar = nil
    }

    /// The bar was dragged, or moved itself: while drawing, the tools go with it.
    func barMoved() {
        guard isDrawing else { return }
        placeToolbar()
    }

    /// Whether the control bar's Draw button is these overlays'.
    func isConnected(to bar: ScreencastControlBar) -> Bool { self.bar === bar }

    // MARK: Drawing

    func toggleDrawing() {
        if isDrawing { endDrawing() } else { startDrawing() }
    }

    /// Starts drawing, while the overlays are on a display.
    func startDrawing() {
        guard isShown, layer.isShown, !isDrawing else { return }
        setDrawing(true)
    }

    /// Stops drawing: clicks go through again, and a mark being drawn is dropped. The marks stay
    /// until they fade or are cleared.
    func endDrawing() {
        guard isDrawing else { return }
        if let mark = drawing.cancel() { layer.redraw(mark.bounds, on: mark.display) }
        setDrawing(false)
    }

    private func setDrawing(_ on: Bool) {
        isDrawing = on
        layer.setDrawing(on)
        toolbar.setShowing(on)
        if on {
            placeToolbar()
            registerKeys()
        } else {
            unregisterKeys()
        }
        bar?.isDrawing = on
        onDrawingChange?(on)
    }

    /// Puts the drawing tools just above the control bar, on its display, or with no bar near the
    /// bottom of the first recorded display.
    private func placeToolbar() {
        let anchor = bar.flatMap { $0.isShown ? $0.panel.frame : nil }
        let barDisplay = anchor.flatMap { anchor in
            let middle = CGPoint(x: anchor.midX, y: anchor.midY)
            let screens = connectedDisplays()
            return screens.first { $0.frame.contains(middle) } ?? screens.first { $0.frame.intersects(anchor) }
        }
        guard let visibleFrame = barDisplay?.visibleFrame ?? layer.displays.first?.visibleFrame else { return }
        toolbar.place(above: anchor, within: visibleFrame)
    }

    /// Clears every mark.
    func clear() {
        clearMarks()
    }

    /// Removes the last mark drawn.
    func undo() {
        guard let mark = drawing.undo() else { return }
        layer.redraw(mark.bounds, on: mark.display)
        marksChanged()
    }

    private func clearMarks() {
        let removed = drawing.clear()
        for display in Set(removed.map(\.display)) { layer.redraw(on: display) }
        marksChanged()
    }

    // MARK: Keys

    private func registerKeys() {
        if let keys {
            for key in ScreencastDrawingKey.allCases {
                keys.register(owner: key.owner, binding: key.binding) { [weak self] in self?.press(key) }
            }
        }
        // A hot key never reaches Keybumps's own windows' handlers, so this hears only what the
        // hot keys didn't take: a key that couldn't be registered, or with hot keys turned off.
        guard watchesOwnKeys, ownKeyMonitor == nil else { return }
        ownKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = ScreencastDrawingKey.matching(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isDrawing else { return false }
                self.press(key)
                return true
            }
            return handled ? nil : event
        }
    }

    private func unregisterKeys() {
        if let keys {
            for key in ScreencastDrawingKey.allCases { keys.unregister(owner: key.owner) }
        }
        if let ownKeyMonitor { NSEvent.removeMonitor(ownKeyMonitor) }
        ownKeyMonitor = nil
    }

    /// What a drawing key does.
    func press(_ key: ScreencastDrawingKey) {
        guard isDrawing else { return }
        switch key {
        case .end: endDrawing()
        case .clear: clear()
        case .undo: undo()
        }
    }

    // MARK: Fading

    /// Removes the marks that have faded out and redraws the ones fading; stops ticking once
    /// nothing fades.
    func tick() {
        let now = clock()
        let expired = drawing.removeExpired(at: now)
        for mark in expired + drawing.fadingMarks(at: now) {
            layer.redraw(mark.bounds, on: mark.display)
        }
        if !expired.isEmpty { marksChanged() }
        if !drawing.needsTicking(at: now) { stopTicking() }
    }

    private func marksChanged() {
        let marks = !drawing.marks.isEmpty
        if hasMarks != marks { hasMarks = marks }
        if drawing.needsTicking(at: clock()) { startTicking() } else { stopTicking() }
    }

    private func startTicking() {
        guard timer == nil, let tickInterval else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether fading marks are being redrawn as time passes.
    var isTicking: Bool { timer != nil }
}

// MARK: - The pointer

extension ScreencastOverlays: ScreencastDrawingCanvasDelegate {
    func visibleMarks(on display: CGDirectDisplayID) -> [ScreencastVisibleMark] {
        drawing.visibleMarks(on: display, at: clock())
    }

    func pointerDown(at point: CGPoint, on display: CGDirectDisplayID) {
        guard isDrawing else { return }
        if let dropped = drawing.cancel() { layer.redraw(dropped.bounds, on: dropped.display) }
        drawing.begin(at: point, on: display, style: style)
        if let mark = drawing.current { layer.redraw(mark.bounds, on: display) }
    }

    func pointerDragged(to point: CGPoint, on display: CGDirectDisplayID) {
        guard isDrawing, let mark = drawing.current, mark.display == display else { return }
        if let changed = drawing.extend(to: point) { layer.redraw(changed, on: display) }
    }

    func pointerUp(at point: CGPoint, on display: CGDirectDisplayID) {
        guard isDrawing, let mark = drawing.current, mark.display == display else { return }
        drawing.extend(to: point)
        if let ended = drawing.finish(at: clock()) { layer.redraw(ended.bounds, on: display) }
        marksChanged()
    }
}
