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
        /// Only shortcuts (`KeyPress.isShortcut`, `KeystrokeFilter`).
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
    /// The screens the keys show on, such as the ones a recording records, and the only ones a click
    /// shows a ring on. Nil means the screen the pointer is on when a key is pressed, and a ring on
    /// whichever screen is clicked.
    var displays: Set<CGDirectDisplayID>?
}

/// Who holds the key display, in the order they took it, and what each asked for. The display
/// shows while anyone holds it, and only one shows however many do. The configuration in effect is
/// the most recent holder's, with two exceptions:
/// - Show is Shortcuts only if any holder asks for it, so a recording that shows shortcuts only
///   never records typing the plugin was set to show;
/// - the screens are the most recent holder's that names some, so a recording's screens win for
///   as long as it holds the display, even if the plugin is turned on after it started.
///
/// The windows stay on screen for the whole hold if any holder asks (`keepsWindowsOnScreen`). A
/// holder that acquires again keeps its place and changes only what it asked for.
struct KeyDisplayHolds: Equatable {
    struct Holder: Equatable {
        let owner: KeyDisplayOwner
        var configuration: KeyDisplayConfiguration
        var keepsWindowsOnScreen: Bool
    }

    private(set) var holders: [Holder] = []

    var owners: [KeyDisplayOwner] { holders.map(\.owner) }
    var isHeld: Bool { !holders.isEmpty }
    var keepsWindowsOnScreen: Bool { holders.contains(where: \.keepsWindowsOnScreen) }

    func holds(_ owner: KeyDisplayOwner) -> Bool { holders.contains { $0.owner == owner } }

    /// The configuration in effect, or nil while nobody holds the display.
    var configuration: KeyDisplayConfiguration? {
        guard var configuration = holders.last?.configuration else { return nil }
        if holders.contains(where: { $0.configuration.keys == .shortcutsOnly }) { configuration.keys = .shortcutsOnly }
        configuration.displays = holders.last(where: { $0.configuration.displays != nil })?.configuration.displays
        return configuration
    }

    /// Adds `owner`, or changes what it asked for. Returns whether anything changed.
    @discardableResult
    mutating func acquire(_ owner: KeyDisplayOwner, configuration: KeyDisplayConfiguration, keepsWindowsOnScreen: Bool = false) -> Bool {
        let holder = Holder(owner: owner, configuration: configuration, keepsWindowsOnScreen: keepsWindowsOnScreen)
        if let index = holders.firstIndex(where: { $0.owner == owner }) {
            guard holders[index] != holder else { return false }
            holders[index] = holder
        } else {
            holders.append(holder)
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
}

/// A screen the overlay can cover, in AppKit's screen coordinates.
struct KeyDisplayScreen: Equatable {
    let display: CGDirectDisplayID
    let frame: CGRect
    /// The part the menu bar and the Dock leave.
    let visibleFrame: CGRect

    /// Every screen, in `NSScreen.screens` order.
    @MainActor
    static func current() -> [KeyDisplayScreen] {
        NSScreen.screens.compactMap { screen in
            guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return KeyDisplayScreen(display: display, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    /// The screen the pointer is on.
    @MainActor
    static func pointerDisplay() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        return current().first { NSMouseInRect(location, $0.frame, false) }?.display
    }

    /// A screen point in the overlay's own coordinates, from its top left.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }
}

/// What the overlay draws: the configuration in effect, the lines on screen, oldest first, the
/// clicks' rings, and which screens show them.
struct KeyDisplayContent: Equatable {
    var configuration: KeyDisplayConfiguration
    var entries: [KeystrokeTimeline.Entry]
    var clicks: [KeystrokeTimeline.Click]
    /// The screen the pointer was on at the newest key, for a configuration that names no screens.
    var pointerDisplay: CGDirectDisplayID?
    /// Whether a holder keeps the windows on screen for the whole hold.
    var keepsWindowsOnScreen = false

    /// The screens the lines show on.
    var lineDisplays: Set<CGDirectDisplayID> {
        configuration.displays ?? Set(pointerDisplay.map { [$0] } ?? [])
    }

    /// Whether a ring may show on `display`.
    func showsClicks(on display: CGDirectDisplayID) -> Bool {
        configuration.displays?.contains(display) ?? true
    }

    /// The screens that need an overlay window now: every screen the configuration names (all of
    /// them if it names none) while a holder keeps the windows up; otherwise only the screens with
    /// lines or rings to show.
    func displaysNeedingWindows(on screens: [KeyDisplayScreen]) -> Set<CGDirectDisplayID> {
        let all = Set(screens.map(\.display))
        if keepsWindowsOnScreen { return all.intersection(configuration.displays ?? all) }
        var needed: Set<CGDirectDisplayID> = entries.isEmpty ? [] : lineDisplays
        for click in clicks {
            if let screen = screens.first(where: { $0.frame.contains(click.location) }), showsClicks(on: screen.display) {
                needed.insert(screen.display)
            }
        }
        return needed.intersection(all)
    }
}

/// Draws the key display. `KeyDisplayOverlayController` puts an overlay window on each screen that
/// needs one; unit tests use `InertKeyDisplayPresenter` or a fake, so nothing appears on screen.
@MainActor
protocol KeyDisplayPresenting: AnyObject {
    /// The overlay windows on screen now.
    var windows: [NSWindow] { get }
    /// Called after `windows` changes: put up, taken down, or replaced as displays come and go.
    var onWindowsChange: (() -> Void)? { get set }
    /// Shows `content`. Without `animated`, what leaves goes at once, with no fade, as when typing
    /// must not reach a recording's first frames.
    func show(_ content: KeyDisplayContent, animated: Bool)
    /// Closes the windows.
    func hide()
}

/// Draws nothing and has no windows: the unit-test host and the UI-test composition.
@MainActor
final class InertKeyDisplayPresenter: KeyDisplayPresenting {
    var windows: [NSWindow] { [] }
    var onWindowsChange: (() -> Void)?
    func show(_ content: KeyDisplayContent, animated: Bool) {}
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
/// The keys show on the configuration's screens, or the pointer's. An overlay window covers each
/// screen that has something to show, and goes after it fades. A holder that records the screen
/// passes `keepsWindowsOnScreen`, which keeps a window on each of its screens for the whole hold,
/// even before the first key: Screencast records with ScreenCaptureKit, which excludes Keybumps's
/// own windows, and adds these back with `SCContentFilter(…exceptingWindows:)`, matching each
/// `SCWindow.windowID` to `overlayWindowIDs`. A holder hears when they're put up or replaced
/// through the handler it passes to `acquire`.
///
/// A screenshot shortcut never shows: it clears the screen at once (`pauseForScreenshot`), and
/// nothing shows until a key that isn't part of taking the screenshot.
@MainActor
final class KeyDisplay {
    private(set) var holds = KeyDisplayHolds()
    private(set) var timeline = KeystrokeTimeline()
    /// Whether the keyboard tap is running: false while nobody holds the display, and while macOS
    /// refuses it (Input Monitoring isn't granted).
    private(set) var isListening = false
    /// Whether the pointer tap is running, while the configuration shows clicks.
    private(set) var isWatchingClicks = false
    /// Whether a screenshot shortcut cleared the screen, which stays clear until a key that isn't
    /// part of taking the screenshot (`KeystrokeFilter.continuesScreenshot`).
    private(set) var isPausedForScreenshot = false
    /// The name of the Keybumps shortcut a press triggers, while it's registered. `AppModel` sets it.
    var registeredShortcutName: (KeyPress) -> String? = { _ in nil }
    /// The Command Palette's own key names while it's the key window, or nil. `AppModel` sets it.
    var paletteKeyNames: () -> [String: String]? = { nil }
    /// Whether a press takes a screenshot. `AppModel` adds Screenshot Tools' hotkeys.
    var isScreenshotShortcut: (KeyPress) -> Bool = { KeystrokeFilter.isScreenshotShortcut($0) }
    /// The screen the pointer is on.
    var pointerDisplay: () -> CGDirectDisplayID? = { KeyDisplayScreen.pointerDisplay() }
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
    /// The pointer's screen at the newest key.
    private var lastPointerDisplay: CGDirectDisplayID?

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

    /// Holds the display for `owner` with its configuration, showing it if it wasn't. With
    /// `keepsWindowsOnScreen`, as a recording passes, a window covers each of its screens for the
    /// whole hold; otherwise windows come and go with what there is to show. Acquiring again changes
    /// all of these and replaces the handler, keeping the owner's place. `onOverlayWindowsChange` is
    /// called at once with `overlayWindows`, then whenever they're put up or replaced, until `owner`
    /// releases the display.
    func acquire(
        _ owner: KeyDisplayOwner,
        configuration: KeyDisplayConfiguration,
        keepsWindowsOnScreen: Bool = false,
        onOverlayWindowsChange: (([NSWindow]) -> Void)? = nil
    ) {
        let changed = holds.acquire(owner, configuration: configuration, keepsWindowsOnScreen: keepsWindowsOnScreen)
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

    /// Clears the screen at once, with no fade, and keeps it clear, rings included, until a key
    /// that isn't part of taking a screenshot: a screenshot shouldn't show the keys that took it.
    /// A screenshot shortcut heard by the tap calls it, and so does Screenshot Tools before it
    /// captures, in case the tap never hears a hotkey Keybumps registered.
    func pauseForScreenshot() {
        guard holds.isHeld else { return }
        isPausedForScreenshot = true
        timeline.removeAll()
        present(animated: false)
    }

    // MARK: Overlay windows

    /// The overlay windows on screen now.
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
            isPausedForScreenshot = false
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
        // What the new configuration wouldn't show leaves at once, with no fade, so a recording
        // that starts now never has it in its first frames.
        let before = timeline
        if configuration.keys == .shortcutsOnly { timeline.removeTyping() }
        if !configuration.showsClicks { timeline.removeClicks() }
        present(animated: timeline == before)
    }

    func receive(_ press: KeyPress) {
        guard let configuration = holds.configuration else { return }
        if isScreenshotShortcut(press) {
            pauseForScreenshot()
            return
        }
        if isPausedForScreenshot {
            if KeystrokeFilter.continuesScreenshot(press) { return }
            isPausedForScreenshot = false
        }
        guard KeystrokeFilter.shows(press, keys: configuration.keys, secureInput: secureInput()),
              let stroke = KeystrokeNaming.keystroke(for: press, layout: layout) else { return }
        let name = configuration.namesActions
            ? KeystrokeActionNames.name(for: stroke, keybumps: registeredShortcutName(press), palette: paletteKeyNames())
            : nil
        lastPointerDisplay = pointerDisplay()
        timeline.record(stroke, name: name, at: now(), linger: configuration.linger)
        present()
    }

    func receive(_ sample: PointerSample) {
        guard let configuration = holds.configuration, configuration.showsClicks, !isPausedForScreenshot,
              sample.phase == .down else { return }
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

    private func present(animated: Bool = true) {
        guard let configuration = holds.configuration else { return }
        presenter.show(
            KeyDisplayContent(
                configuration: configuration,
                entries: timeline.entries,
                clicks: timeline.clicks,
                pointerDisplay: lastPointerDisplay,
                keepsWindowsOnScreen: holds.keepsWindowsOnScreen
            ),
            animated: animated
        )
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
