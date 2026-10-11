import Foundation

/// The action a shortcut does, for the name the key display shows with it ("Copy" with ⌘C): a
/// Keybumps shortcut while it's registered, then the standard macOS shortcut it is. It stays local
/// and cheap: no Accessibility lookups of other apps' menus, so an app's own shortcuts go unnamed.
enum KeystrokeActionNames {
    /// `palette` is the Command Palette's own key names while it's the key window (`paletteNames`),
    /// where a standard shortcut may do something else (⌘P pastes there), or nil when it isn't.
    static func name(for stroke: Keystroke, keybumps: String?, palette: [String: String]? = nil) -> String? {
        guard stroke.isShortcut else { return nil }
        if let keybumps { return keybumps }
        if let palette { return palette[stroke.text] }
        return standard[stroke.text]
    }

    /// The names a palette tab's footer gives its keys, as the display writes them: "⌘P": "Paste".
    static func paletteNames(_ actions: [PaletteKeyAction]) -> [String: String] {
        Dictionary(actions.map { ($0.keys.joined().replacingOccurrences(of: "↵", with: "↩"), $0.title) }) { first, _ in first }
    }

    /// The Keybumps action a press triggers: a plugin's shortcut (`CapabilityShortcut`) or a Window
    /// Manager action, among the bindings `GlobalShortcutCoordinator` has registered and isn't
    /// holding back (`registeredBindings`), by owner. A binding macOS or another app owns, or one
    /// suspended while a shortcut is being recorded, triggers nothing of Keybumps's, so it isn't named.
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
    ]
}
