import AppKit
import Carbon.HIToolbox

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org's marker for a password or other secret; clipboard managers that follow
    /// the convention don't record items that carry it.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

extension NSPasteboard {
    /// Replaces the contents with plain text. A concealed write also carries the ConcealedType
    /// marker, so clipboard managers that follow nspasteboard.org's convention skip it.
    @discardableResult
    func writeText(_ text: String, concealed: Bool = false) -> Bool {
        clearContents()
        guard setString(text, forType: .string) else { return false }
        if concealed { setData(Data(), forType: .concealed) }
        return true
    }
}

enum TextPasteError: Error, Equatable {
    /// This session never synthesizes ⌘V (UI tests and unit tests).
    case unavailable
    case pasteboardWriteFailed
    case keystrokeUnavailable
}

/// The one paste step Dictation and Snippets share: put the text on the pasteboard, keep that
/// write out of Clipboard History, and press ⌘V in the app in front. Posting ⌘V into another app
/// needs Accessibility; without it macOS drops the keystroke without an error, so callers check
/// Accessibility first.
protocol TextPasting {
    @MainActor func paste(_ text: String, concealed: Bool) throws
}

struct SystemTextPaster: TextPasting {
    var pasteboard: @MainActor () -> NSPasteboard = { .keybumps }
    /// Called right after the pasteboard write, so Clipboard History can skip exactly that change.
    var didWritePasteboard: @MainActor () -> Void = {}

    @MainActor
    func paste(_ text: String, concealed: Bool) throws {
        guard pasteboard().writeText(text, concealed: concealed) else { throw TextPasteError.pasteboardWriteFailed }
        didWritePasteboard()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw TextPasteError.keystrokeUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Never touches the pasteboard or synthesizes ⌘V: the UI-test composition and unit tests.
struct InertTextPaster: TextPasting {
    @MainActor
    func paste(_ text: String, concealed: Bool) throws {
        throw TextPasteError.unavailable
    }
}
