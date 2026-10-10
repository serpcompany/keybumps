import AppKit
import Carbon.HIToolbox

/// A key that went down, as the key display hears it (`KeyDisplay`): which key, and the modifiers
/// held. It carries no characters; what the key types is worked out from the keyboard layout only
/// when the display shows it (`KeystrokeNaming`). Never logged or stored.
struct KeyPress: Equatable, Sendable {
    /// The virtual key code, as `kVK_ANSI_C`.
    let keyCode: UInt16
    let modifiers: KeyModifiers
    /// macOS repeating a held key.
    var isRepeat = false
    /// Keybumps posted it itself, such as its paste step's ⌘V (`SystemTextPaster.syntheticEventMarker`).
    var isSynthetic = false

    /// Whether it's a shortcut, which "Shortcuts only" shows: ⌘ or ⌃ held, or ⌥ with a key that
    /// types nothing (`typesNothing`). KeyCastr's "command keys" (`isCommand` in `KCKeycastrEvent.m`)
    /// are ⌃ and ⌘. Keybumps counts ⌥ too (#443), but only for those keys: with a letter, digit, or
    /// symbol, ⌥ types a character on most layouts (a German @ is ⌥L, Polish ż is ⌥Z), so it's typing.
    var isShortcut: Bool {
        if !modifiers.isDisjoint(with: [.command, .control]) { return true }
        return modifiers.contains(.option) && Self.typesNothing(keyCode)
    }

    /// Arrows, ⌫, ⌦, Return, Enter, Tab, Escape, Home, End, Page Up and Down, and the function keys:
    /// keys that type no character with ⌥ held on any layout.
    static func typesNothing(_ keyCode: UInt16) -> Bool {
        switch KeyboardShortcutRegistry.specialKey(forVirtualKey: Int(keyCode))?.semanticKey {
        case .upArrow, .downArrow, .leftArrow, .rightArrow, .delete, .forwardDelete, .returnKey, .enter, .tabRight,
             .escape, .home, .end, .pageUp, .pageDown, .function:
            true
        default:
            false
        }
    }
}

extension KeyPress {
    /// Reads a key-down from a listen-only tap. Only the key's code, its flags, and Keybumps' own
    /// marker are read, never its characters.
    init(event: CGEvent) {
        self.init(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: KeyModifiers(event.flags),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SystemTextPaster.syntheticEventMarker
        )
    }
}

/// The modifier keys held with a press. Fn isn't one: macOS sets it for arrows and function keys
/// whether or not it's held, so the display never shows it.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
    static let capsLock = KeyModifiers(rawValue: 1 << 4)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ flags: CGEventFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        self = modifiers
    }

    /// The Carbon mask a `ShortcutBinding` stores; Caps Lock isn't part of a shortcut.
    var carbonFlags: UInt32 {
        var flags = 0
        if contains(.control) { flags |= controlKey }
        if contains(.option) { flags |= optionKey }
        if contains(.shift) { flags |= shiftKey }
        if contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }
}

/// Where the key display hears keys. The real one is `KeyTypingMonitor`, the listen-only tap that
/// Snippets' keyword expansion also uses (each listener has its own); unit tests and the UI-test
/// composition use `InertKeyTypingMonitor`, which never listens, so no test hears the keyboard.
protocol KeyPressMonitoring: AnyObject {
    /// Every key that goes down, on the main thread.
    var onPress: ((KeyPress) -> Void)? { get set }
    /// Starts listening; false when macOS refuses (Input Monitoring isn't granted).
    func start() -> Bool
    func stop()
}

/// Which presses the key display shows (#443):
/// - nothing while secure input is on (a password field, or an app that asked for it), whatever
///   Show is set to, ⌘ and ⌃ shortcuts included (the owner's decision, 2026-10-10);
/// - nothing Keybumps posted itself;
/// - never a screenshot shortcut (`isScreenshotShortcut`), which `KeyDisplay` answers by clearing
///   the screen instead;
/// - with Shortcuts only, a press only when it's a shortcut (`KeyPress.isShortcut`). Plain typing,
///   ⇧ alone, and ⌥ with a key that types a character never show then.
enum KeystrokeFilter {
    static func shows(_ press: KeyPress, keys: KeyDisplayConfiguration.Keys, secureInput: Bool) -> Bool {
        guard !secureInput, !press.isSynthetic else { return false }
        switch keys {
        case .shortcutsOnly: return press.isShortcut
        case .allKeys: return true
        }
    }

    /// macOS's screenshot shortcuts, by key code so they match on any layout: ⇧⌘3, ⇧⌘4, ⇧⌘5, and
    /// ⇧⌘6 (the Touch Bar), and each with ⌃, which copies the shot instead of saving it.
    static let systemScreenshotKeys: Set<Int> = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]

    /// Whether `press` takes a screenshot: one of macOS's (`systemScreenshotKeys`), or one of
    /// `keybumps`, Screenshot Tools' hotkeys as they're set now. Caps Lock doesn't matter.
    static func isScreenshotShortcut(_ press: KeyPress, keybumps: [ShortcutBinding] = []) -> Bool {
        let modifiers = press.modifiers.subtracting(.capsLock)
        if systemScreenshotKeys.contains(Int(press.keyCode)),
           modifiers == [.shift, .command] || modifiers == [.control, .shift, .command] {
            return true
        }
        return keybumps.contains { $0.keyCode == UInt32(press.keyCode) && $0.modifiers == modifiers.carbonFlags }
    }

    /// Keys of macOS's own screenshot controls, which keep the display clear after a screenshot
    /// shortcut: Escape cancels, Space switches ⇧⌘4 to a window, and Return or Enter takes ⇧⌘5's shot.
    static func continuesScreenshot(_ press: KeyPress) -> Bool {
        guard press.modifiers.subtracting([.capsLock, .shift]).isEmpty else { return false }
        return [kVK_Escape, kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(press.keyCode))
    }
}
