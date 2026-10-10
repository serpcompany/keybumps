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
        /// Comes before the others, whatever the registry order: Screencast's while it records.
        var takesPrecedence = false
    }

    private(set) var parts: [Capability: Part] = [:]
    /// Runs whenever the text or a menu section changes, so the status item redraws.
    var onChange: () -> Void = {}

    /// The text beside the icon: the first capability's that has any, those that take precedence
    /// first, then in registry order.
    var title: String? { ordered.lazy.compactMap(\.title).first }

    /// What VoiceOver says for that text.
    var spokenTitle: String? { ordered.first { $0.title != nil }?.spokenTitle }

    /// The menu's sections at its top, those that take precedence first, then in registry order,
    /// leaving out empty ones.
    var sections: [[MenuBarItem]] { ordered.map(\.items).filter { !$0.isEmpty } }

    /// Sets a capability's text and menu section at once, redrawing once if either changed.
    func set(
        title: String?,
        spoken: String?,
        items: [MenuBarItem],
        takesPrecedence: Bool = false,
        for capability: Capability
    ) {
        let old = parts[capability] ?? Part()
        let changed = old.title != title || old.spokenTitle != spoken
            || old.items.map(\.id) != items.map(\.id) || old.items.map(\.title) != items.map(\.title)
            || old.items.map(\.systemImage) != items.map(\.systemImage)
            || old.takesPrecedence != takesPrecedence
        parts[capability] = Part(title: title, spokenTitle: spoken, items: items, takesPrecedence: takesPrecedence)
        if changed { onChange() }
    }

    func clear(_ capability: Capability) {
        guard parts.removeValue(forKey: capability) != nil else { return }
        onChange()
    }

    private var ordered: [Part] {
        let inRegistryOrder = CapabilityCatalog.descriptors.compactMap { parts[$0.capability] }
        return inRegistryOrder.filter(\.takesPrecedence) + inRegistryOrder.filter { !$0.takesPrecedence }
    }
}

/// A capability module's view of `MenuBarStatus`, limited to its own part.
@MainActor
struct CapabilityMenuBarStatus {
    let status: MenuBarStatus
    let capability: Capability

    /// Shows `title` beside the icon (nil for none), which VoiceOver says as `spoken`, and `items`
    /// as the capability's section at the top of the Keybumps menu (empty for none). A part that
    /// `takesPrecedence` comes before the other capabilities', as a recording's does.
    func set(title: String?, spoken: String?, items: [MenuBarItem], takesPrecedence: Bool = false) {
        status.set(title: title, spoken: spoken, items: items, takesPrecedence: takesPrecedence, for: capability)
    }

    func clear() {
        status.clear(capability)
    }
}
