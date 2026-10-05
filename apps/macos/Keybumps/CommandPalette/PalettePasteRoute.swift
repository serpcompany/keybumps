import AppKit

/// An app ⌘V could go to: the process, and whether it's Keybumps itself.
struct PasteTarget: Equatable {
    let processIdentifier: pid_t
    let isKeybumps: Bool

    /// The app in front now.
    @MainActor
    static func frontmost() -> PasteTarget? {
        NSWorkspace.shared.frontmostApplication.map {
            PasteTarget(
                processIdentifier: $0.processIdentifier,
                isKeybumps: $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
            )
        }
    }
}

/// Whether ⌘Return pastes a snippet, or copies it and says why. It pastes only into the app that
/// was in front when the palette opened (`CommandPaletteController.pasteTarget`; the non-activating
/// palette never takes it over), and only while that app is still in front after the palette closes
/// and a short wait, with the palette not reopened. Posting ⌘V into another app needs
/// Accessibility, which is optional for Snippets: without it ⌘Return copies, and the permission
/// assistant offers the usual setup. The paste itself is `TextPasting`, the step Dictation shares.
enum PalettePasteRoute: Equatable {
    enum Reason: Equatable {
        /// Posting ⌘V into another app needs Accessibility.
        case needsAccessibility
        /// Keybumps itself was in front (the palette opened from the Dock, or over Settings), or no app was.
        case noOtherApp
        /// That app isn't in front any more, or the palette opened again while the paste waited.
        case targetChanged
        /// The paste step itself failed.
        case pasteFailed

        var notice: String {
            switch self {
            case .needsAccessibility: "Copied · Paste needs Accessibility"
            case .noOtherApp: "Copied · No app to paste into"
            case .targetChanged, .pasteFailed: "Copied · Couldn’t paste"
            }
        }
    }

    case paste
    case copy(Reason)

    var notice: String? {
        guard case .copy(let reason) = self else { return nil }
        return reason.notice
    }

    /// Decided when ⌘Return is pressed, before the palette closes.
    static func beforeClosing(canPaste: Bool, target: PasteTarget?) -> PalettePasteRoute {
        guard let target, !target.isKeybumps else { return .copy(.noOtherApp) }
        guard canPaste else { return .copy(.needsAccessibility) }
        return .paste
    }

    /// Checked after the short wait, right before ⌘V.
    static func canPasteNow(
        into target: PasteTarget,
        frontmost: PasteTarget?,
        paletteIsVisible: Bool,
        isStillWanted: Bool
    ) -> Bool {
        isStillWanted && !paletteIsVisible && frontmost == target && !target.isKeybumps
    }
}
