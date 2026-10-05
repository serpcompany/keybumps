import Foundation

/// One item a capability adds to the Keybumps menu.
struct MenuBarItem: Identifiable {
    /// Stable while the item stands for the same thing, so an open menu can update it in place.
    let id: String
    let title: String
    /// An SF Symbol name.
    let systemImage: String?
    let action: @MainActor () -> Void
}

/// What capabilities show on the Keybumps menu bar item besides its icon and red dot: short text
/// beside the icon, and a section at the top of its menu. The shell owns the one status item
/// (`NativeStatusItemController`); a module sets its own part through `CapabilityMenuBarStatus`.
@MainActor
final class MenuBarStatus {
    struct Part {
        var title: String?
        var spokenTitle: String?
        var items: [MenuBarItem] = []
    }

    private(set) var parts: [Capability: Part] = [:]
    /// Runs whenever the text or a menu section changes, so the status item redraws.
    var onChange: () -> Void = {}

    /// The text beside the icon: the first capability's in registry order that has any.
    var title: String? { ordered.lazy.compactMap(\.title).first }

    /// What VoiceOver says for that text.
    var spokenTitle: String? { ordered.first { $0.title != nil }?.spokenTitle }

    /// The menu's sections at its top, in registry order, leaving out empty ones.
    var sections: [[MenuBarItem]] { ordered.map(\.items).filter { !$0.isEmpty } }

    func setTitle(_ title: String?, spoken: String?, for capability: Capability) {
        guard parts[capability]?.title != title || parts[capability]?.spokenTitle != spoken else { return }
        parts[capability, default: Part()].title = title
        parts[capability, default: Part()].spokenTitle = spoken
        onChange()
    }

    func setItems(_ items: [MenuBarItem], for capability: Capability) {
        let old = parts[capability]?.items ?? []
        guard old.map(\.id) != items.map(\.id) || old.map(\.title) != items.map(\.title) else { return }
        parts[capability, default: Part()].items = items
        onChange()
    }

    func clear(_ capability: Capability) {
        guard parts.removeValue(forKey: capability) != nil else { return }
        onChange()
    }

    private var ordered: [Part] {
        CapabilityCatalog.descriptors.compactMap { parts[$0.capability] }
    }
}

/// A capability module's view of `MenuBarStatus`, limited to its own part.
@MainActor
struct CapabilityMenuBarStatus {
    let status: MenuBarStatus
    let capability: Capability

    /// Shows `title` beside the icon (nil for none); VoiceOver says `spoken`.
    func setTitle(_ title: String?, spoken: String?) {
        status.setTitle(title, spoken: spoken, for: capability)
    }

    /// The capability's section at the top of the Keybumps menu; empty for none.
    func setItems(_ items: [MenuBarItem]) {
        status.setItems(items, for: capability)
    }

    func clear() {
        status.clear(capability)
    }
}
