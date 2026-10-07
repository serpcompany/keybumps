import Foundation

/// A Keybumps action a global shortcut can be set for: a plugin's command, or a Window Manager
/// command.
enum ShortcutOwner: Hashable, Identifiable {
    case capability(CapabilityShortcut)
    case window(WindowAction)

    var id: String {
        switch self {
        case .capability(let shortcut): "capability.\(shortcut.rawValue)"
        case .window(let action): "window.\(action.rawValue)"
        }
    }

    /// Where the action is and what it's called, as in "Emoji Picker › Open Emoji Picker".
    var displayName: String {
        switch self {
        case .capability(let shortcut): "\(shortcut.capability.descriptor.title) › \(shortcut.title)"
        case .window(let action): "\(Capability.windowManagement.descriptor.title) › \(action.title)"
        }
    }

    /// Every action, plugins' first, in a fixed order, so a conflict check always names the same one.
    static let all: [ShortcutOwner] = CapabilityShortcut.allCases.map(ShortcutOwner.capability)
        + WindowAction.allCases.map(ShortcutOwner.window)
}

/// Finds the other Keybumps action that already uses a shortcut's keys (#334). Conflicts with
/// other apps and macOS shortcuts aren't checked here.
enum ShortcutConflict {
    /// The action other than `owner` whose shortcut uses the same keys as `binding`, or nil.
    /// Keys match on key and modifiers alone, so the order the modifiers were pressed in, and how
    /// the name was written, don't matter.
    static func find(
        _ binding: ShortcutBinding,
        for owner: ShortcutOwner,
        capabilityShortcuts: [String: ShortcutBinding],
        windowShortcuts: [String: ShortcutBinding]
    ) -> ShortcutOwner? {
        ShortcutOwner.all.first { other in
            guard other != owner else { return false }
            let existing = switch other {
            case .capability(let shortcut): capabilityShortcuts[shortcut.rawValue]
            case .window(let action): windowShortcuts[action.rawValue]
            }
            return existing?.usesSameKeys(as: binding) == true
        }
    }
}

/// A shortcut Keybumps took off one action and gave to another: by Replace, by restoring
/// defaults, or by the launch-time cleanup. The action that lost it says so on its row (#334).
struct ShortcutMove: Equatable {
    /// The shortcut, as the action that lost it had it.
    let binding: ShortcutBinding
    let to: ShortcutOwner

    var keys: String { binding.displayName }
    var note: String { "\(keys) moved to \(to.displayName)." }
}

/// A recorded or restored shortcut another action already uses, waiting for Replace or Cancel.
struct PendingShortcutReplacement: Equatable {
    /// The recorder field it was recorded in.
    let identifier: String
    let binding: ShortcutBinding
    /// The action that has the keys now.
    let owner: ShortcutOwner

    var message: String { "\(binding.displayName) is used by \(owner.displayName)." }

    /// What VoiceOver hears when the question appears (#345): the message with the keys as words,
    /// then the choice.
    var announcement: String {
        let keys = KeyboardShortcutRegistry.accessibilityDescription(for: binding.displayName) ?? binding.displayName
        return "\(keys) is used by \(owner.displayName). Replace or Cancel."
    }
}

extension ShortcutMove {
    /// What restoring defaults took from other actions, for a note beside the button, or nil when
    /// it took nothing.
    static func restoreNote(for owners: [ShortcutOwner], in moves: [ShortcutOwner: ShortcutMove]) -> String? {
        let taken = owners.compactMap { owner in moves[owner].map { "\($0.keys) from \(owner.displayName)" } }
        guard !taken.isEmpty else { return nil }
        return "Restoring the defaults took \(taken.joined(separator: ", "))."
    }
}
