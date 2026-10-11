import AppKit
import Carbon.HIToolbox

/// A press as the key display shows it: a shortcut's modifier keys and key, such as ⇧ ⌘ 4, or what
/// a key typed. Built by `KeystrokeNaming`, kept on screen for a moment, and never logged or stored.
struct Keystroke: Equatable, Sendable {
    /// ⌃ ⌥ ⇧ ⌘ as held, in the order macOS menus write them; empty for typing.
    let modifiers: [String]
    /// A shortcut's key, uppercased as on a keycap ("C") or its symbol ("←", "Space", "F5"); for
    /// typing, what the key typed ("h", "H", "␣", "⌫").
    let key: String
    /// Whether it's a shortcut (`KeyPress.isShortcut`).
    let isShortcut: Bool

    /// One keycap per key.
    var keycaps: [String] { modifiers + [key] }
    /// The keys run together, as KeyCastr's bezel writes them: "⇧⌘4".
    var text: String { (modifiers + [key]).joined() }
}

/// What a key types on the keyboard layout in use. `SystemKeyboardLayout` reads macOS's; tests
/// pass a fixed one.
@MainActor
protocol KeyboardLayoutTranslating: AnyObject {
    /// The character `keyCode` types with these modifiers (only ⇧, Caps Lock, ⌥, and ⌘ are
    /// passed), or nil when it types none.
    func character(for keyCode: UInt16, with modifiers: KeyModifiers) -> String?
}

/// Names a press for the key display, adapted from KeyCastr's `KCEventTransformer`
/// (`keyCapForKeystroke:` and `transformedValue:`):
/// - a shortcut lists ⌃ ⌥ ⇧ ⌘ as held, then its key: a special key's symbol (`KeyboardShortcutRegistry`,
///   the symbols Keybumps's keycaps use everywhere, plus KeyCastr's media and JIS keys), or the
///   character the layout gives the key, uppercased as on a keycap. Like KeyCastr it reads the key
///   without ⇧ (⇧⌘/ rather than ⌘?) and keeps a character whose capital is longer (ß, not SS). Unlike
///   KeyCastr it reads a ⌘ shortcut's key through the layout's ⌘ keys, so ⌘C on a Dvorak – QWERTY ⌘
///   layout is ⌘C;
/// - typing (not a shortcut) is what the key typed with ⇧, Caps Lock, and ⌥ (⌥L is @ on a German
///   layout), a space as ␣, and a special key's symbol, with ⇧ before it when held (⇧⇥ is ⇤, as in
///   KeyCastr).
///
/// It returns nil for a key it can't name, which the display then leaves out.
@MainActor
enum KeystrokeNaming {
    /// `isKeybumpsShortcut` names a press that triggers a registered Keybumps shortcut as a shortcut
    /// whatever its keys: it types nothing, as Dictation's ⌥Space doesn't.
    static func keystroke(for press: KeyPress, layout: any KeyboardLayoutTranslating, isKeybumpsShortcut: Bool = false) -> Keystroke? {
        let modifiers = press.modifiers
        if press.isShortcut || isKeybumpsShortcut {
            guard let key = shortcutKey(press.keyCode, command: modifiers.contains(.command), layout: layout) else { return nil }
            return Keystroke(modifiers: modifierSymbols(modifiers), key: key, isShortcut: true)
        }
        let shift = modifiers.contains(.shift)
        if shift, Int(press.keyCode) == kVK_Tab {
            return Keystroke(modifiers: [], key: "⇤", isShortcut: false)
        }
        if Int(press.keyCode) == kVK_Space {
            return Keystroke(modifiers: [], key: "␣", isShortcut: false)
        }
        if let special = specialKey(press.keyCode) {
            return Keystroke(modifiers: [], key: (shift ? "⇧" : "") + special, isShortcut: false)
        }
        guard let typed = layout.character(for: press.keyCode, with: modifiers.intersection([.shift, .capsLock, .option])),
              isPrintable(typed) else { return nil }
        return Keystroke(modifiers: [], key: typed, isShortcut: false)
    }

    /// ⌃ ⌥ ⇧ ⌘, the order macOS menus and KeyCastr write them.
    static func modifierSymbols(_ modifiers: KeyModifiers) -> [String] {
        [(KeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
    }

    private static func shortcutKey(_ keyCode: UInt16, command: Bool, layout: any KeyboardLayoutTranslating) -> String? {
        if let special = specialKey(keyCode) { return special }
        guard let character = layout.character(for: keyCode, with: command ? .command : []),
              isPrintable(character) else { return nil }
        return keycapCase(character)
    }

    /// A letter as a keycap shows it: uppercased, unless its capital is longer, such as ß's SS.
    static func keycapCase(_ character: String) -> String {
        let upper = character.uppercased()
        return upper.count == character.count ? upper : character
    }

    /// The symbol of a key that types no character: Keybumps's own (`KeyboardShortcutRegistry`),
    /// then the keys only KeyCastr names.
    static func specialKey(_ keyCode: UInt16) -> String? {
        KeyboardShortcutRegistry.specialKey(forVirtualKey: Int(keyCode))?.renderedSymbol ?? keyCastrKeys[keyCode]
    }

    /// From `KCEventTransformer.specialKeys`: the brightness, Mission Control, Launchpad, Spotlight,
    /// Dictation, Focus, and fn keys of newer keyboards, and the JIS keyboard's 英数 and かな.
    private static let keyCastrKeys: [UInt16: String] = [
        145: "🔅", 144: "🔆", 160: "🖥", 131: "🚀", 177: "🔍", 176: "🎤", 178: "⏾", 179: "fn",
        UInt16(kVK_JIS_Eisu): "英数", UInt16(kVK_JIS_Kana): "かな",
    ]

    /// Not a control character, and not one of the private-use characters AppKit reports for arrows
    /// and function keys.
    private static func isPrintable(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xE000...0xF8FF).contains(scalar.value)
        }
    }
}

/// The keyboard layout in use, read through Text Input Sources with `UCKeyTranslate`, as KeyCastr's
/// `KCEventTransformer` does. It reads the layout again after the input source changes.
@MainActor
final class SystemKeyboardLayout: KeyboardLayoutTranslating {
    /// The layout's `uchr` data, until the input source changes.
    private var layoutData: Data?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutData = nil }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    func character(for keyCode: UInt16, with modifiers: KeyModifiers) -> String? {
        if layoutData == nil { layoutData = Self.currentLayoutData() }
        guard let layoutData else { return nil }
        var carbon = Int(modifiers.carbonFlags)
        if modifiers.contains(.capsLock) { carbon |= alphaLock }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), UInt32((carbon >> 8) & 0xFF), UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// The current layout's data, or the ASCII-capable one's for an input method without its own.
    private static func currentLayoutData() -> Data? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(),
                  let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        }
        return nil
    }
}
