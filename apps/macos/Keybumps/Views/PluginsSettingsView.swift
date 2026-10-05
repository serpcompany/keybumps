import SwiftUI

/// The Plugins table's sections: the default plugins (Quick Search first, then by name), then
/// added ones by name (ADR 0006).
enum PluginsTable {
    struct Section: Equatable {
        let title: String
        let plugins: [SettingsSection]
    }

    static var sections: [Section] {
        let pages = CapabilityCatalog.descriptors.compactMap(\.settingsPage?.section)
            .sorted { lhs, rhs in
                if (lhs == .search) != (rhs == .search) { return lhs == .search }
                return lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
            }
        let isDefault: (SettingsSection) -> Bool = { $0.capability.map(CapabilityCatalog.defaultCapabilities.contains) ?? false }
        return [
            Section(title: "Default", plugins: pages.filter(isDefault)),
            Section(title: "Added", plugins: pages.filter { !isDefault($0) }),
        ].filter { !$0.plugins.isEmpty }
    }

    /// A plugin's palette tab Command-number, while the tab can be shown; the Hotkeys tab only
    /// while its Settings page shows it.
    static func tabKey(for descriptor: CapabilityDescriptor, showsHotkeysTab: Bool) -> String {
        guard let tab = descriptor.paletteTab?.tab, tab != .keyboardShortcutter || showsHotkeysTab else { return "" }
        return tab.shortcutLabel
    }

    /// A plugin's first assigned shortcut, and how many more it has, such as "⇧⌘2 +2".
    static func shortcutText(for descriptor: CapabilityDescriptor, binding: (CapabilityShortcut) -> ShortcutBinding?) -> String {
        let assigned = descriptor.shortcuts.compactMap { binding($0)?.displayName }
        guard let first = assigned.first else { return "" }
        return assigned.count > 1 ? "\(first) +\(assigned.count - 1)" : first
    }

    /// The sections, keeping plugins whose name or Quick Search keywords contain `query`.
    static func sections(matching query: String) -> [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        return sections.map { section in
            Section(title: section.title, plugins: section.plugins.filter { page in
                guard let descriptor = page.capability?.descriptor else { return false }
                return ([descriptor.title] + (descriptor.searchKeywords ?? [])).contains {
                    $0.localizedCaseInsensitiveContains(trimmed)
                }
            })
        }.filter { !$0.plugins.isEmpty }
    }
}

/// Settings › Plugins, like Raycast's Extensions list: every plugin, the default ones then added
/// ones, with its palette tab, its shortcut, and its switch. Clicking one opens its own page, which
/// has its own row in the sidebar.
struct PluginsSettingsView: View {
    let open: (SettingsSection) -> Void
    @State private var query = ""

    var body: some View {
        let sections = PluginsTable.sections(matching: query)
        SettingsPage {
            SettingsSearchField(text: $query, prompt: "Search plugins…", identifier: "plugins.search")
            if sections.isEmpty {
                SettingsNote("No plugins match.")
            }
            ForEach(sections, id: \.title) { section in
                SettingsGroup(section.title) {
                    ForEach(section.plugins) { page in
                        PluginsListRow(page: page) { open(page) }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
    }
}

/// A plugin's row: its icon, name, and summary (clicking them opens its page), whether it needs
/// attention, its palette tab and shortcut, and its switch.
private struct PluginsListRow: View {
    @Environment(AppModel.self) private var model
    let page: SettingsSection
    let open: () -> Void

    var body: some View {
        if let capability = page.capability {
            let descriptor = capability.descriptor
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 11) {
                        SettingsIconTile(systemImage: descriptor.systemImage, tint: descriptor.iconTint, size: 26)
                            .accessibilityHidden(true)
                        SettingsRowLabel(title: descriptor.title, subtitle: descriptor.settingsPage?.summary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if model.settingsAttentionCount(for: page) > 0 {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Needs attention")
                        }
                        let tabKey = PluginsTable.tabKey(for: descriptor, showsHotkeysTab: model.preferences.showsHotkeysTab)
                        Text(tabKey)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            .help("Its Command Palette tab")
                            .accessibilityLabel(tabKey.isEmpty ? "" : "Command Palette tab \(tabKey)")
                        let shortcut = PluginsTable.shortcutText(for: descriptor) { model.preferences.capabilityShortcut(for: $0) }
                        Text(shortcut)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 96, alignment: .trailing)
                            .help("Its shortcuts")
                            .accessibilityLabel(shortcut.isEmpty ? "" : "Shortcut \(shortcut)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens its settings")
                .accessibilityIdentifier("plugins.row.\(page.launchToken)")
                CapabilityToggle(capability: capability)
            }
        }
    }
}
