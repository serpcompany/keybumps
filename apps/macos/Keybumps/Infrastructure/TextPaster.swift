import AppKit
import ApplicationServices
import Carbon.HIToolbox

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org's marker for a password or other secret; clipboard managers that follow
    /// the convention don't record items that carry it.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

extension NSPasteboard {
    /// How a text write is offered: a concealed one stays on this Mac, so Universal Clipboard
    /// never hands a secret to the user's other devices.
    static func contentsOptions(concealed: Bool) -> NSPasteboard.ContentsOptions {
        concealed ? .currentHostOnly : []
    }

    /// Replaces the contents with plain text. A concealed write stays on this Mac and is one item
    /// carrying both the text and the ConcealedType marker, written at once, so a clipboard manager
    /// that follows nspasteboard.org's convention never sees the text without the marker.
    @discardableResult
    func writeText(_ text: String, concealed: Bool = false) -> Bool {
        prepareForNewContents(with: Self.contentsOptions(concealed: concealed))
        guard concealed else { return setString(text, forType: .string) }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), item.setData(Data(), forType: .concealed) else { return false }
        return writeObjects([item])
    }
}

enum TextPasteError: Error, Equatable {
    /// This session never synthesizes ⌘V (UI tests and unit tests).
    case unavailable
    /// Keybumps isn't trusted for Accessibility, so no ⌘V was posted.
    case accessibilityRequired
    case pasteboardWriteFailed
    case keystrokeUnavailable
}

/// The one paste step Dictation and Snippets share: put the text on the pasteboard, keep that
/// write out of Clipboard History, and press ⌘V in the app in front. Posting ⌘V into another app
/// needs Accessibility; without it macOS drops the keystroke and shows its own "would like to
/// control this computer" alert. So callers check Accessibility first, and the poster checks again.
protocol TextPasting {
    @MainActor func paste(_ text: String, concealed: Bool) throws
    /// Keyword expansion: deletes the `count` characters just typed (the keyword), before pasting.
    @MainActor func deleteTyped(_ count: Int) throws
}

extension TextPasting {
    @MainActor
    func deleteTyped(_ count: Int) throws {
        throw TextPasteError.unavailable
    }
}

struct SystemTextPaster: TextPasting {
    var pasteboard: @MainActor () -> NSPasteboard = { .keybumps }
    /// Called right after the pasteboard write, so Clipboard History can skip exactly that change.
    var didWritePasteboard: @MainActor () -> Void = {}
    /// Presses ⌘V in the app in front, or refuses without Accessibility. Tests replace it, so they
    /// never post a real keystroke.
    var postCommandV: @MainActor () throws -> Void = { try SystemTextPaster.postSystemCommandV() }
    /// Presses Delete this many times in the app in front, or refuses without Accessibility.
    var postBackspaces: @MainActor (Int) throws -> Void = { try SystemTextPaster.postSystemBackspaces(count: $0) }

    /// Marks every key Keybumps posts (`eventSourceUserData`), so keyword expansion's typing
    /// monitor never mistakes them for the user's typing.
    static let syntheticEventMarker: Int64 = 0x4B42_5053

    @MainActor
    func paste(_ text: String, concealed: Bool) throws {
        guard pasteboard().writeText(text, concealed: concealed) else { throw TextPasteError.pasteboardWriteFailed }
        didWritePasteboard()
        try postCommandV()
    }

    @MainActor
    func deleteTyped(_ count: Int) throws {
        try postBackspaces(count)
    }

    /// The only keyboard-event poster in Keybumps, with `postSystemBackspaces`. macOS delivers
    /// synthesized key events to other apps only while Keybumps is trusted for Accessibility, so the
    /// silent check lives here and no caller can post untrusted. Tests pass a fake trust check and
    /// sender, never macOS.
    @MainActor
    static func postSystemCommandV(
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        send: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) throws {
        try postKeys([(CGKeyCode(kVK_ANSI_V), .maskCommand)], accessibilityTrusted: accessibilityTrusted, send: send)
    }

    /// Deletes the keyword keyword expansion just matched: one Delete per character.
    @MainActor
    static func postSystemBackspaces(
        count: Int,
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        send: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) throws {
        let delete = (CGKeyCode(kVK_Delete), CGEventFlags())
        try postKeys(Array(repeating: delete, count: max(0, count)), accessibilityTrusted: accessibilityTrusted, send: send)
    }

    /// Presses and releases each key in order, marked as Keybumps' own.
    @MainActor
    private static func postKeys(
        _ keys: [(code: CGKeyCode, flags: CGEventFlags)],
        accessibilityTrusted: () -> Bool,
        send: (CGEvent) -> Void
    ) throws {
        guard accessibilityTrusted() else { throw TextPasteError.accessibilityRequired }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw TextPasteError.keystrokeUnavailable }
        source.userData = syntheticEventMarker
        var events: [CGEvent] = []
        for key in keys {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else {
                throw TextPasteError.keystrokeUnavailable
            }
            down.flags = key.flags
            up.flags = key.flags
            events += [down, up]
        }
        events.forEach(send)
    }
}

/// Never touches the pasteboard or synthesizes ⌘V: the UI-test composition, unit tests, and any
/// caller that isn't given the app's paste step.
struct InertTextPaster: TextPasting {
    @MainActor
    func paste(_ text: String, concealed: Bool) throws {
        throw TextPasteError.unavailable
    }
}

extension AppModel {
    /// The paste step Dictation and Snippets share: the real one, whose pasteboard write Clipboard
    /// History skips, or an inert one under unit tests and in the UI-test composition.
    static func makeTextPaster(
        clipboard: ClipboardHistoryService,
        allowsSystemAccess: Bool,
        isUnitTestHost: Bool = UnitTestHost.isActive
    ) -> any TextPasting {
        guard allowsSystemAccess, !isUnitTestHost else { return InertTextPaster() }
        return SystemTextPaster(didWritePasteboard: { [weak clipboard] in clipboard?.suppressCurrentChange() })
    }
}
