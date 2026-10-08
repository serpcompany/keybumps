import Foundation

/// Why the menu bar icon shows its red dot. One dot stands for every reason; VoiceOver names each.
enum MenuBarAttentionReason: Hashable {
    /// A newer version is available, downloading, or waiting for a restart (#225, #416).
    case update
    /// A capability has something waiting for you.
    case capability(Capability)
}

/// The shell's one source for the menu bar icon's red dot. The status item shows the dot while any
/// reason is active. Updates set their own reason, and a capability module sets its own through
/// `CapabilityMenuBarAttention`.
@MainActor
final class MenuBarAttention {
    /// What VoiceOver says for each active reason, after the app's name.
    private(set) var phrases: [MenuBarAttentionReason: String] = [:]
    /// Runs whenever the dot or what VoiceOver says changes, so the status item redraws.
    var onChange: () -> Void = {}

    var showsDot: Bool { !phrases.isEmpty }

    /// Whether the update state needs the dot: a newer version was found and hasn't installed or been
    /// skipped, through checks and failures (#420), or a restart is ready.
    static func updateIsWaiting(_ snapshot: UpdateSnapshot) -> Bool {
        snapshot.canRestart || snapshot.newerVersion != nil
    }

    /// What VoiceOver says for the update's dot.
    static func updatePhrase(_ snapshot: UpdateSnapshot) -> String {
        snapshot.canRestart ? "update ready" : "update available"
    }

    func show(_ reason: MenuBarAttentionReason, saying phrase: String) {
        guard phrases[reason] != phrase else { return }
        phrases[reason] = phrase
        onChange()
    }

    func clear(_ reason: MenuBarAttentionReason) {
        guard phrases.removeValue(forKey: reason) != nil else { return }
        onChange()
    }

    /// The icon's VoiceOver name: the app's name, then each reason, updates first and then
    /// capabilities in registry order.
    func accessibilityLabel(productName: String) -> String {
        let reasons = phrases.keys.sorted { Self.rank($0) < Self.rank($1) }
        return ([productName] + reasons.compactMap { phrases[$0] }).joined(separator: ", ")
    }

    private static func rank(_ reason: MenuBarAttentionReason) -> Int {
        switch reason {
        case .update: -1
        case .capability(let capability):
            CapabilityCatalog.descriptors.firstIndex { $0.capability == capability } ?? Int.max
        }
    }
}

/// A capability module's view of the menu bar dot, limited to its own reason.
@MainActor
struct CapabilityMenuBarAttention {
    let attention: MenuBarAttention
    let capability: Capability

    /// Shows the dot until `clear()`; VoiceOver says `phrase` after the app's name.
    func show(saying phrase: String) {
        attention.show(.capability(capability), saying: phrase)
    }

    func clear() {
        attention.clear(.capability(capability))
    }
}
