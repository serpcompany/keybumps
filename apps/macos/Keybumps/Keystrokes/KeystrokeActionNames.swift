import Foundation

/// The action a shortcut does, for the name the key display shows with it ("Copy" with ⌘C): a
/// Keybumps shortcut while it's registered, then the standard macOS shortcut it is. It stays local
/// and cheap: no Accessibility lookups of other apps' menus, so an app's own shortcuts go unnamed.
enum KeystrokeActionNames {
    static func name(for stroke: Keystroke, keybumps: String?) -> String? {
        guard stroke.isShortcut else { return nil }
        return keybumps ?? standard[stroke.text]
    }

    /// The Keybumps action a press triggers: a plugin's shortcut (`CapabilityShortcut`) or a Window
    /// Manager action, among the bindings `GlobalShortcutCoordinator` has registered, by owner.
    static func keybumpsName(for press: KeyPress, bindings: [String: ShortcutBinding]) -> String? {
        func matches(_ owner: String) -> Bool {
            guard let binding = bindings[owner] else { return false }
            return binding.keyCode == UInt32(press.keyCode) && binding.modifiers == press.modifiers.carbonFlags
        }
        if let shortcut = CapabilityShortcut.allCases.first(where: { matches($0.ownerID) }) { return shortcut.title }
        return WindowAction.allCases.first { matches("window.\($0.rawValue)") }?.title
    }

    /// Shortcuts that do the same thing in every app, from Apple’s “Mac keyboard shortcuts”
    /// support article (HT201236), as the display writes them (`Keystroke.text`). Shortcuts whose
    /// action depends on the app, such as ⌘R or ⌘L, aren't named.
    static let standard: [String: String] = [
        "⌘X": "Cut",
        "⌘C": "Copy",
        "⌘V": "Paste",
        "⌥⇧⌘V": "Paste and Match Style",
        "⌘Z": "Undo",
        "⇧⌘Z": "Redo",
        "⌘A": "Select All",
        "⌘F": "Find",
        "⌘G": "Find Next",
        "⇧⌘G": "Find Previous",
        "⌘H": "Hide",
        "⌥⌘H": "Hide Others",
        "⌘M": "Minimize",
        "⌥⌘M": "Minimize All",
        "⌘N": "New",
        "⌘O": "Open",
        "⌘P": "Print",
        "⌘S": "Save",
        "⇧⌘S": "Save As",
        "⌘T": "New Tab",
        "⌘W": "Close Window",
        "⌥⌘W": "Close All Windows",
        "⌘Q": "Quit",
        "⌘,": "Settings",
        "⇧⌘/": "Help",
        "⌘B": "Bold",
        "⌘I": "Italic",
        "⌘U": "Underline",
        "⌘Space": "Spotlight",
        "⌃⌘Space": "Emoji & Symbols",
        "⌃⌘F": "Full Screen",
        "⌃⌘Q": "Lock Screen",
        "⌥⌘⎋": "Force Quit",
        "⌥⌘D": "Show or Hide the Dock",
        "⌘⇥": "Switch Apps",
        "⌘`": "Next Window",
        "⇧⌘3": "Screenshot",
        "⇧⌘4": "Screenshot Area",
        "⇧⌘5": "Screenshot and Recording",
    ]
}
