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
    /// A rect the keys sit in, in AppKit's global space, such as the area or window a recording
    /// records: they go along its bottom edge, at `position`, inset, on each of `displays` it's on.
    /// Nil puts them along the bottom of the screen's visible frame.
    var anchor: CGRect?
}

/// Who holds the key display, in the order they took it, what each asked for, and whether its keys
/// are hidden. The display shows while any holder's keys are shown, and only one shows however many
/// do. The configuration in effect is the most recent shown holder's, with these exceptions, each
/// counting shown holders only, so a hidden holder's keys, screens, or anchor never mix in:
/// - Show is Shortcuts only if any shown holder asks for it, so a recording that shows shortcuts
///   only never records typing the plugin was set to show;
/// - while a shown holder keeps the windows on screen (a recording), the screens, the anchor, and
///   whether clicks show are the most recent such holder's, so what's in its video stays its own
///   even if the plugin is turned on after it started;
/// - otherwise the screens and the anchor are the most recent shown holder's that names some.
///
/// The windows stay on screen for the whole hold if any shown holder asks (`keepsWindowsOnScreen`).
/// A holder that acquires again keeps its place, and whether its keys are hidden, and changes only
/// what it asked for. Hide Keystrokes hides every holder's keys (`hide`), until Show Keystrokes
/// (`show`) or each lets go, so a recording hidden now stays hidden until it ends, and one that
/// starts later shows its keys.
struct KeyDisplayHolds: Equatable {
    struct Holder: Equatable {
        let owner: KeyDisplayOwner
        var configuration: KeyDisplayConfiguration
        var keepsWindowsOnScreen: Bool
        var isHidden = false
    }

    private(set) var holders: [Holder] = []
    private var shown: [Holder] { holders.filter { !$0.isHidden } }

    var owners: [KeyDisplayOwner] { holders.map(\.owner) }
    var isHeld: Bool { !holders.isEmpty }
    /// Whether any holder's keys are shown: the display runs only then.
    var isShowing: Bool { holders.contains { !$0.isHidden } }
    var keepsWindowsOnScreen: Bool { shown.contains(where: \.keepsWindowsOnScreen) }

    func holds(_ owner: KeyDisplayOwner) -> Bool { holders.contains { $0.owner == owner } }
    func isHidden(_ owner: KeyDisplayOwner) -> Bool { holders.first { $0.owner == owner }?.isHidden ?? false }

    /// The configuration in effect, or nil while no holder's keys are shown.
    var configuration: KeyDisplayConfiguration? {
        let shown = shown
        guard var configuration = shown.last?.configuration else { return nil }
        if shown.contains(where: { $0.configuration.keys == .shortcutsOnly }) { configuration.keys = .shortcutsOnly }
        if let recording = shown.last(where: \.keepsWindowsOnScreen)?.configuration {
            configuration.displays = recording.displays
            configuration.anchor = recording.anchor
            configuration.showsClicks = recording.showsClicks
        } else {
            configuration.displays = shown.last(where: { $0.configuration.displays != nil })?.configuration.displays
            configuration.anchor = shown.last(where: { $0.configuration.anchor != nil })?.configuration.anchor
        }
        return configuration
    }

    /// Adds `owner`, its keys hidden if `startsHidden`, or changes what it asked for. Returns whether
    /// anything changed.
    @discardableResult
    mutating func acquire(
        _ owner: KeyDisplayOwner,
        configuration: KeyDisplayConfiguration,
        keepsWindowsOnScreen: Bool = false,
        startsHidden: Bool = false
    ) -> Bool {
        if let index = holders.firstIndex(where: { $0.owner == owner }) {
            var holder = holders[index]
            holder.configuration = configuration
            holder.keepsWindowsOnScreen = keepsWindowsOnScreen
            guard holders[index] != holder else { return false }
            holders[index] = holder
        } else {
            holders.append(Holder(owner: owner, configuration: configuration, keepsWindowsOnScreen: keepsWindowsOnScreen, isHidden: startsHidden))
        }
        return true
    }

    /// Hides every holder's keys. Returns whether anything changed.
    @discardableResult
    mutating func hide() -> Bool { setHidden(true) }

    /// Shows every holder's keys again. Returns whether anything changed.
    @discardableResult
    mutating func show() -> Bool { setHidden(false) }

    private mutating func setHidden(_ isHidden: Bool) -> Bool {
        guard holders.contains(where: { $0.isHidden != isHidden }) else { return false }
        for index in holders.indices { holders[index].isHidden = isHidden }
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
    /// Shows `content`. Without `animated`, what leaves goes at once, with no fade, and so does
    /// whatever is still fading out from an earlier show, as when typing must not reach a
    /// recording's first frames, or old keys a restarted recording's new take.
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
/// configuration and `release`s it when done; it runs while any holder's keys are shown
/// (`KeyDisplayHolds` decides whose configuration applies). Show and Hide Keystrokes act on every
/// holder's keys at once (`showKeys`, `hideKeys`).
///
/// While it runs it listens to the keyboard through `KeyPressMonitoring`, which needs Input
/// Monitoring, and, while the configuration shows clicks, to the pointer through
/// `PointerEventMonitoring`. Hidden keys need neither, so neither runs for them. Nothing it hears
/// is logged or stored: a keystroke stays in memory only while it's on screen.
///
/// The keys show on the configuration's screens, or the pointer's. An overlay window covers each
/// screen that has something to show, and goes after it fades. A holder that records the screen
/// passes `keepsWindowsOnScreen`, which keeps a window on each of its screens for the whole hold,
/// even before the first key: Screencast records with ScreenCaptureKit, which excludes Keybumps's
/// own windows, and adds these back with `SCContentFilter(…exceptingWindows:)`, matching each
/// `SCWindow.windowID` to `overlayWindowIDs`. A holder hears when they're put up or replaced
/// through the handler it passes to `acquire`.
///
/// A screenshot shortcut it knows never shows: macOS's as the person has them, and Screenshot
/// Tools' while they're registered. It clears the screen at once (`pauseForScreenshot`), and
/// nothing shows until a key that isn't part of taking the screenshot. Other apps' screenshot
/// shortcuts aren't known.
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
    /// Screenshot Tools' hotkeys while they're registered. `AppModel` sets it.
    var keybumpsScreenshotBindings: () -> [ShortcutBinding] = { [] }
    /// macOS's symbolic hotkeys, read through `SymbolicHotKeyPreferences` (never written), or nil
    /// when they can't be read. `AppModel` sets it; it's inert under the unit-test host.
    var symbolicHotKeys: () -> [String: Any]? = { nil }
    /// The screen the pointer is on.
    var pointerDisplay: () -> CGDirectDisplayID? = { KeyDisplayScreen.pointerDisplay() }
    /// The main display's height, to turn the pointer tap's top-left coordinates into AppKit's.
    var mainDisplayHeight: () -> CGFloat = { NSScreen.screens.first?.frame.height ?? 0 }
    /// Called after `isShowing` or `isListening` changes: a holder acquiring or letting go, Show or
    /// Hide Keystrokes, or the keyboard tap starting once Input Monitoring is granted. The Keystrokes
    /// module sets it, so Show Keystrokes in the menu bar menu is checked while keys can be on screen
    /// (`isOnScreen`), a recording's included.
    var onShowingChange: () -> Void = {}

    private let keys: any KeyPressMonitoring
    private let pointer: any PointerEventMonitoring
    private let presenter: any KeyDisplayPresenting
    private let layout: any KeyboardLayoutTranslating
    private let now: () -> Date
    private let scheduler: any TimerScheduling
    private let secureInput: () -> Bool
    private var windowHandlers: [KeyDisplayOwner: ([NSWindow]) -> Void] = [:]
    /// `isShowing` and `isListening` when `onShowingChange` was last called.
    private var reported = (isShowing: false, isListening: false)
    private var wakeUp: (any TimerScheduledAction)?
    /// The pointer's screen at the newest key.
    private var lastPointerDisplay: CGDirectDisplayID?
    /// macOS's screenshot shortcuts, when they were read, and Screenshot Tools' hotkeys then. They're
    /// read again when the display starts or changes; on a key once they're older than
    /// `screenshotKeysLifetime`, or once Screenshot Tools' hotkeys differ, since Keybumps turns
    /// macOS's ⇧⌘3 and ⇧⌘4 off and on with them; and on the next key after Keybumps writes macOS's
    /// shortcuts (`systemScreenshotShortcutsDidChange`).
    private var systemScreenshotKeys = KeystrokeFilter.systemScreenshotKeys(symbolicHotKeys: nil)
    private var systemScreenshotKeysRead: Date?
    private var keybumpsScreenshotBindingsRead: [ShortcutBinding] = []
    static let screenshotKeysLifetime: TimeInterval = 10
    /// Until when lines that expired may still be fading off the screen.
    private var fadesUntil: Date?

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
    /// Whether any holder's keys are shown, so the display runs.
    var isShowing: Bool { holds.isShowing }
    /// Whether keys can be on screen now: some holder's are shown and the keyboard tap is listening.
    /// Without Input Monitoring macOS refuses the tap, so no key can appear though a holder shows
    /// them. Secure input doesn't count: it's brief, and macOS gives no notice when it ends.
    var isOnScreen: Bool { holds.isShowing && isListening }
    /// The configuration in effect, or nil while no holder's keys are shown.
    var configuration: KeyDisplayConfiguration? { holds.configuration }
    func holds(_ owner: KeyDisplayOwner) -> Bool { holds.holds(owner) }
    func isHidden(_ owner: KeyDisplayOwner) -> Bool { holds.isHidden(owner) }
    /// Whether secure input is on now, so nothing shows.
    var isSecureInputOn: Bool { secureInput() }

    /// Holds the display for `owner` with its configuration, showing it if it wasn't, or with its
    /// keys hidden if `startsHidden`, as the Keystrokes plugin does while its keys are hidden. With
    /// `keepsWindowsOnScreen`, as a recording passes, a window covers each of its screens for the
    /// whole hold; otherwise windows come and go with what there is to show. Acquiring again changes
    /// those two and replaces the handler, keeping the owner's place and whether its keys are hidden.
    /// `onOverlayWindowsChange` is called at once with `overlayWindows`, then whenever they're put up
    /// or replaced, until `owner` releases the display.
    func acquire(
        _ owner: KeyDisplayOwner,
        configuration: KeyDisplayConfiguration,
        keepsWindowsOnScreen: Bool = false,
        startsHidden: Bool = false,
        onOverlayWindowsChange: (([NSWindow]) -> Void)? = nil
    ) {
        let changed = holds.acquire(owner, configuration: configuration, keepsWindowsOnScreen: keepsWindowsOnScreen, startsHidden: startsHidden)
        if changed { apply() }
        windowHandlers[owner] = onOverlayWindowsChange
        onOverlayWindowsChange?(overlayWindows)
    }

    /// Hide Keystrokes: takes every holder's keys off the screen at once, a recording's included,
    /// until `showKeys` or each holder lets go. With nothing shown, the keyboard and pointer taps
    /// stop and the windows close. A holder that acquires afterwards, such as a new recording,
    /// shows its keys.
    func hideKeys() {
        if holds.hide() { apply() }
    }

    /// Show Keystrokes: shows every holder's keys again, each holder keeping its place, so a
    /// recording's look still applies while it holds the display.
    func showKeys() {
        if holds.show() { apply() }
    }

    /// Lets go for `owner`. The display keeps running for anyone else holding it, and stops, closing
    /// its windows, once nobody does.
    func release(_ owner: KeyDisplayOwner) {
        windowHandlers[owner] = nil
        guard holds.release(owner) else { return }
        apply()
    }

    /// Starts the keyboard tap that macOS refused earlier, once Input Monitoring may have been
    /// granted, and tells `onShowingChange` if it did. `AppModel` calls it whenever it re-reads
    /// permissions.
    func permissionsDidRefresh() {
        defer { reportShowingChange() }
        guard let configuration = holds.configuration else { return }
        if !isListening { isListening = keys.start() }
        if configuration.showsClicks, !isWatchingClicks { isWatchingClicks = pointer.start() }
    }

    /// Clears the screen at once, with no fade, and keeps it clear, rings included, until a key
    /// that isn't part of taking a screenshot: a screenshot shouldn't show the keys that took it.
    /// A screenshot shortcut heard by the tap calls it, and so does Screenshot Tools before it
    /// captures, in case the tap never hears a hotkey Keybumps registered.
    func pauseForScreenshot() {
        guard holds.isShowing else { return }
        isPausedForScreenshot = true
        timeline.removeAll()
        present(animated: false)
    }

    /// Takes every line and ring off the screen at once, with no fade, and draws that, as when a
    /// recording restarts and its new take must start with none. Unlike `pauseForScreenshot()`, the
    /// next key shows. Returns whether anything was on screen: a line or a ring, or a line still
    /// fading out, which goes at once too. With every holder's keys hidden there's nothing to clear.
    @discardableResult
    func clearLines() -> Bool {
        guard holds.isShowing else { return false }
        let wasShown = !timeline.entries.isEmpty || !timeline.clicks.isEmpty || fadesUntil.map { now() < $0 } == true
        timeline.removeAll()
        present(animated: false)
        return wasShown
    }

    /// Whether `press` takes a screenshot, by the shortcuts macOS and Keybumps have now.
    func isScreenshotShortcut(_ press: KeyPress) -> Bool {
        let keybumps = keybumpsScreenshotBindings()
        let isOld = systemScreenshotKeysRead.map { now().timeIntervalSince($0) >= Self.screenshotKeysLifetime } ?? true
        if isOld || keybumps != keybumpsScreenshotBindingsRead { readSystemScreenshotKeys(keybumps: keybumps) }
        return KeystrokeFilter.isScreenshotShortcut(press, system: systemScreenshotKeys, keybumps: keybumps)
    }

    /// Reads macOS's screenshot shortcuts again at the next key. Screenshot Tools' takeover calls it
    /// after it turns macOS's ⇧⌘3 or ⇧⌘4 off or on, also when its own hotkeys didn't register.
    func systemScreenshotShortcutsDidChange() {
        systemScreenshotKeysRead = nil
    }

    private func readSystemScreenshotKeys(keybumps: [ShortcutBinding]? = nil) {
        systemScreenshotKeys = KeystrokeFilter.systemScreenshotKeys(symbolicHotKeys: symbolicHotKeys())
        systemScreenshotKeysRead = now()
        keybumpsScreenshotBindingsRead = keybumps ?? keybumpsScreenshotBindings()
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
        defer { reportShowingChange() }
        guard let configuration = holds.configuration else {
            keys.stop()
            pointer.stop()
            isListening = false
            isWatchingClicks = false
            isPausedForScreenshot = false
            timeline.removeAll()
            fadesUntil = nil
            wakeUp?.cancel()
            wakeUp = nil
            presenter.hide()
            return
        }
        if !isListening { isListening = keys.start() }
        readSystemScreenshotKeys()
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

    /// Calls `onShowingChange` if `isShowing` or `isListening` changed since the last call.
    private func reportShowingChange() {
        let current = (isShowing: holds.isShowing, isListening: isListening)
        guard current != reported else { return }
        reported = current
        onShowingChange()
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
        let keybumpsName = registeredShortcutName(press)
        guard KeystrokeFilter.shows(press, keys: configuration.keys, secureInput: secureInput(), isKeybumpsShortcut: keybumpsName != nil),
              let stroke = KeystrokeNaming.keystroke(for: press, layout: layout, isKeybumpsShortcut: keybumpsName != nil) else { return }
        let name = configuration.namesActions
            ? KeystrokeActionNames.name(for: stroke, keybumps: keybumpsName, palette: paletteKeyNames())
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
        let before = timeline
        timeline.expire(at: now(), linger: configuration.linger)
        if timeline != before { fadesUntil = now().addingTimeInterval(KeyDisplayOverlayController.fadeDuration) }
        present()
    }

    private func present(animated: Bool = true) {
        guard let configuration = holds.configuration else { return }
        // Without animation, the presenter ends every fade too.
        if !animated { fadesUntil = nil }
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
