import AppKit
import Carbon.HIToolbox

/// Who holds the key display (`KeyDisplay.acquire`). The Keystrokes plugin is one; a Screencast
/// recording adds its own (`extension KeyDisplayOwner { static let screencast = … }`).
struct KeyDisplayOwner: Hashable, Sendable, CustomStringConvertible {
    let id: String
    init(_ id: String) { self.id = id }

    static let keystrokes = KeyDisplayOwner("keystrokes")

    var description: String { id }
}

/// How the key display looks and what it shows. Each holder passes its own; `KeyDisplayHolds`
/// decides which applies.
struct KeyDisplayConfiguration: Equatable, Sendable {
    enum Style: String, CaseIterable, Sendable {
        /// Keybumps-style keycaps, one per key, with the action's name under them.
        case keycaps
        /// KeyCastr's dark rounded bezel.
        case bezel
    }

    enum Position: String, CaseIterable, Sendable {
        case bottomLeft, bottomCenter, bottomRight
    }

    enum Keys: String, CaseIterable, Sendable {
        /// Only presses with ⌘, ⌃, or ⌥ (`KeystrokeFilter`).
        case shortcutsOnly = "shortcuts"
        /// Typing too, except while secure input is on.
        case allKeys = "all"
    }

    enum Size: String, CaseIterable, Sendable {
        case small, medium, large
    }

    var style = Style.keycaps
    var position = Position.bottomCenter
    var keys = Keys.shortcutsOnly
    /// Whether a shortcut shows its action's name ("Copy" with ⌘C).
    var namesActions = true
    var size = Size.medium
    /// How long a line stays on screen after its last press.
    var linger: TimeInterval = 1.5
    /// Whether a ring shows where the pointer clicks.
    var showsClicks = false
}

/// Who holds the key display, in the order they took it, and what each asked for. The display
/// shows while anyone holds it, and only one shows however many do. The configuration in effect
/// is the most recent holder's, with one exception: Show is Shortcuts only if any holder asks for
/// it, so starting a recording that shows shortcuts only never records typing the plugin was set
/// to show. A holder that acquires again keeps its place and changes only what it asked for.
struct KeyDisplayHolds: Equatable {
    private(set) var holders: [(owner: KeyDisplayOwner, configuration: KeyDisplayConfiguration)] = []

    var owners: [KeyDisplayOwner] { holders.map(\.owner) }
    var isHeld: Bool { !holders.isEmpty }

    func holds(_ owner: KeyDisplayOwner) -> Bool { holders.contains { $0.owner == owner } }

    /// The configuration in effect, or nil while nobody holds the display.
    var configuration: KeyDisplayConfiguration? {
        guard var configuration = holders.last?.configuration else { return nil }
        if holders.contains(where: { $0.configuration.keys == .shortcutsOnly }) { configuration.keys = .shortcutsOnly }
        return configuration
    }

    /// Adds `owner`, or changes what it asked for. Returns whether anything changed.
    @discardableResult
    mutating func acquire(_ owner: KeyDisplayOwner, configuration: KeyDisplayConfiguration) -> Bool {
        if let index = holders.firstIndex(where: { $0.owner == owner }) {
            guard holders[index].configuration != configuration else { return false }
            holders[index].configuration = configuration
        } else {
            holders.append((owner, configuration))
        }
        return true
    }

    /// Removes `owner`. Returns whether it held the display.
    @discardableResult
    mutating func release(_ owner: KeyDisplayOwner) -> Bool {
        guard let index = holders.firstIndex(where: { $0.owner == owner }) else { return false }
        holders.remove(at: index)
        return true
    }

    static func == (lhs: KeyDisplayHolds, rhs: KeyDisplayHolds) -> Bool {
        lhs.owners == rhs.owners && lhs.holders.map(\.configuration) == rhs.holders.map(\.configuration)
    }
}

/// What the overlay draws: the configuration in effect, the lines on screen, oldest first, and the
/// clicks' rings.
struct KeyDisplayContent: Equatable {
    var configuration: KeyDisplayConfiguration
    var entries: [KeystrokeTimeline.Entry]
    var clicks: [KeystrokeTimeline.Click]
}

/// Draws the key display. `KeyDisplayOverlayController` puts one overlay window on each display;
/// unit tests use `InertKeyDisplayPresenter` or a fake, so nothing appears on screen.
@MainActor
protocol KeyDisplayPresenting: AnyObject {
    /// The overlay windows, one per display, while the display shows; empty otherwise.
    var windows: [NSWindow] { get }
    /// Called after `windows` changes: created, replaced as displays come and go, or closed.
    var onWindowsChange: (() -> Void)? { get set }
    /// Shows `content`, putting the windows on screen first if they aren't.
    func show(_ content: KeyDisplayContent)
    /// Closes the windows.
    func hide()
}

/// Draws nothing and has no windows: the unit-test host and the UI-test composition.
@MainActor
final class InertKeyDisplayPresenter: KeyDisplayPresenting {
    var windows: [NSWindow] { [] }
    var onWindowsChange: (() -> Void)?
    func show(_ content: KeyDisplayContent) {}
    func hide() {}
}

/// The on-screen key display (#443): the shortcuts someone presses, shown as they press them, and
/// optionally where they click. One display serves everything that wants it, so only one ever
/// shows: the Keystrokes plugin holds it while it's on, and a Screencast recording holds it for the
/// recording (#449), with the plugin on or off. Each holder `acquire`s it with its own
/// configuration and `release`s it when done; it runs while anyone holds it (`KeyDisplayHolds`
/// decides whose configuration applies).
///
/// While held it listens to the keyboard through `KeyPressMonitoring`, which needs Input
/// Monitoring, and, while the configuration shows clicks, to the pointer through
/// `PointerEventMonitoring`. Nothing it hears is logged or stored: a keystroke stays in memory only
/// while it's on screen.
///
/// It puts one overlay window on each display, covering it, for as long as anyone holds it, even
/// before the first key: Screencast records with ScreenCaptureKit, which excludes Keybumps's own
/// windows, and adds these back with `SCContentFilter(…exceptingWindows:)`, matching each
/// `SCWindow.windowID` to `overlayWindowIDs`. A holder hears when they're created or replaced
/// through the handler it passes to `acquire`.
@MainActor
final class KeyDisplay {
    private(set) var holds = KeyDisplayHolds()
    private(set) var timeline = KeystrokeTimeline()
    /// Whether the keyboard tap is running: false while nobody holds the display, and while macOS
    /// refuses it (Input Monitoring isn't granted).
    private(set) var isListening = false
    /// Whether the pointer tap is running, while the configuration shows clicks.
    private(set) var isWatchingClicks = false
    /// The name of the Keybumps shortcut a press triggers, while it's registered. `AppModel` sets it.
    var registeredShortcutName: (KeyPress) -> String? = { _ in nil }
    /// The main display's height, to turn the pointer tap's top-left coordinates into AppKit's.
    var mainDisplayHeight: () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 }

    private let keys: any KeyPressMonitoring
    private let pointer: any PointerEventMonitoring
    private let presenter: any KeyDisplayPresenting
    private let layout: any KeyboardLayoutTranslating
    private let now: () -> Date
    private let scheduler: any TimerScheduling
    private let secureInput: () -> Bool
    private var windowHandlers: [KeyDisplayOwner: ([NSWindow]) -> Void] = [:]
    private var wakeUp: (any TimerScheduledAction)?

    init(
        keys: any KeyPressMonitoring,
        pointer: any PointerEventMonitoring,
        presenter: (any KeyDisplayPresenting)? = nil,
        layout: (any KeyboardLayoutTranslating)? = nil,
        now: @escaping () -> Date = Date.init,
        scheduler: (any TimerScheduling)? = nil,
        secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.keys = keys
        self.pointer = pointer
        let presenter = presenter ?? InertKeyDisplayPresenter()
        self.presenter = presenter
        self.layout = layout ?? SystemKeyboardLayout()
        self.now = now
        self.scheduler = scheduler ?? MonotonicTickScheduler()
        self.secureInput = secureInput
        // Both taps deliver on the main run loop.
        keys.onPress = { [weak self] press in MainActor.assumeIsolated { self?.receive(press) } }
        pointer.onSample = { [weak self] sample in MainActor.assumeIsolated { self?.receive(sample) } }
        presenter.onWindowsChange = { [weak self] in self?.windowsDidChange() }
    }

    /// The production display, or one that never listens or draws under the unit-test host.
    static func makeDefault() -> KeyDisplay {
        if UnitTestHost.isActive {
            return KeyDisplay(keys: InertKeyTypingMonitor(), pointer: InertPointerEventMonitor())
        }
        return KeyDisplay(keys: KeyTypingMonitor(), pointer: PointerEventMonitor(), presenter: KeyDisplayOverlayController())
    }

    // MARK: Holding

    var owners: [KeyDisplayOwner] { holds.owners }
    var isShowing: Bool { holds.isHeld }
    /// The configuration in effect, or nil while nobody holds the display.
    var configuration: KeyDisplayConfiguration? { holds.configuration }
    func holds(_ owner: KeyDisplayOwner) -> Bool { holds.holds(owner) }

    /// Holds the display for `owner` with its configuration, showing it if it wasn't. Acquiring
    /// again changes the configuration and replaces the handler, keeping the owner's place.
    /// `onOverlayWindowsChange` is called at once with `overlayWindows`, then whenever they're
    /// created or replaced, until `owner` releases the display.
    func acquire(
        _ owner: KeyDisplayOwner,
        configuration: KeyDisplayConfiguration,
        onOverlayWindowsChange: (([NSWindow]) -> Void)? = nil
    ) {
        let changed = holds.acquire(owner, configuration: configuration)
        if changed { apply() }
        windowHandlers[owner] = onOverlayWindowsChange
        onOverlayWindowsChange?(overlayWindows)
    }

    /// Lets go for `owner`. The display keeps running for anyone else holding it, and stops, closing
    /// its windows, once nobody does.
    func release(_ owner: KeyDisplayOwner) {
        windowHandlers[owner] = nil
        guard holds.release(owner) else { return }
        apply()
    }

    /// Starts the keyboard tap that macOS refused earlier, once Input Monitoring may have been
    /// granted. `AppModel` calls it whenever it re-reads permissions.
    func permissionsDidRefresh() {
        guard let configuration = holds.configuration else { return }
        if !isListening { isListening = keys.start() }
        if configuration.showsClicks, !isWatchingClicks { isWatchingClicks = pointer.start() }
    }

    // MARK: Overlay windows

    /// The overlay windows while anyone holds the display: one per display, each covering it.
    var overlayWindows: [NSWindow] { presenter.windows }
    /// Their window numbers, as ScreenCaptureKit's `SCWindow.windowID`. A window the Window Server
    /// hasn't made yet has none.
    var overlayWindowIDs: [CGWindowID] { overlayWindows.compactMap { CGWindowID(exactly: $0.windowNumber).flatMap { $0 > 0 ? $0 : nil } } }

    private func windowsDidChange() {
        let windows = overlayWindows
        for handler in windowHandlers.values { handler(windows) }
    }

    // MARK: Showing

    private func apply() {
        guard let configuration = holds.configuration else {
            keys.stop()
            pointer.stop()
            isListening = false
            isWatchingClicks = false
            timeline.removeAll()
            wakeUp?.cancel()
            wakeUp = nil
            presenter.hide()
            return
        }
        if !isListening { isListening = keys.start() }
        if configuration.showsClicks, !isWatchingClicks {
            isWatchingClicks = pointer.start()
        } else if !configuration.showsClicks, isWatchingClicks {
            pointer.stop()
            isWatchingClicks = false
        }
        // What the new configuration wouldn't show leaves at once.
        if configuration.keys == .shortcutsOnly { timeline.removeTyping() }
        if !configuration.showsClicks { timeline.removeClicks() }
        present()
    }

    func receive(_ press: KeyPress) {
        guard let configuration = holds.configuration,
              KeystrokeFilter.shows(press, keys: configuration.keys, secureInput: secureInput()),
              let stroke = KeystrokeNaming.keystroke(for: press, layout: layout) else { return }
        let name = configuration.namesActions
            ? KeystrokeActionNames.name(for: stroke, keybumps: registeredShortcutName(press))
            : nil
        timeline.record(stroke, name: name, at: now(), linger: configuration.linger)
        present()
    }

    func receive(_ sample: PointerSample) {
        guard let configuration = holds.configuration, configuration.showsClicks, sample.phase == .down else { return }
        timeline.recordClick(at: Self.appKitLocation(of: sample.location, mainDisplayHeight: mainDisplayHeight()), time: now())
        present()
    }

    /// Drops what has been on screen long enough. The scheduled wake-up calls it; tests call it with
    /// their own clock.
    func expire() {
        guard let configuration = holds.configuration else { return }
        timeline.expire(at: now(), linger: configuration.linger)
        present()
    }

    private func present() {
        guard let configuration = holds.configuration else { return }
        presenter.show(KeyDisplayContent(configuration: configuration, entries: timeline.entries, clicks: timeline.clicks))
        wakeUp?.cancel()
        wakeUp = timeline.nextExpiry(linger: configuration.linger).map { date in
            scheduler.schedule(at: date) { [weak self] in self?.expire() }
        }
    }

    /// The pointer tap's location (from the top left of the main display) in AppKit's screen
    /// coordinates (from its bottom left).
    static func appKitLocation(of location: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: location.x, y: mainDisplayHeight - location.y)
    }
}
