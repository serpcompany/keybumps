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

/// Settings › Plugins, like Raycast's Extensions tab: a searchable table of every plugin with its
/// switch, and the selected plugin's page beside it. Opening Plugins selects the
/// first plugin.
struct PluginsSettingsView: View {
    @Environment(AppModel.self) private var model
    let selection: SettingsSection
    let select: (SettingsSection) -> Void
    @State private var query = ""

    private var selected: SettingsSection {
        selection.capability != nil ? selection : (PluginsTable.sections.first?.plugins.first ?? .search)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Narrow, so each plugin's page keeps at least the width it had as its own sidebar page.
            table
                .frame(width: 260)
                .background(SettingsTheme.sidebarBackground)
            Divider()
            Group {
                if let page = selected.capability?.descriptor.settingsPage {
                    page.content()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSearchField(text: $query, prompt: "Search plugins…", identifier: "plugins.search")
                .padding(.horizontal, 10)
                .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PluginsTable.sections(matching: query), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.system(size: SettingsTheme.subtitleSize, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                            ForEach(section.plugins) { page in
                                PluginsTableRow(page: page, isSelected: page == selected) { select(page) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }
}

/// A plugin's row: its icon and name (selecting it shows its page), whether it needs attention, and
/// its switch.
private struct PluginsTableRow: View {
    @Environment(AppModel.self) private var model
    let page: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        if let capability = page.capability {
            let descriptor = capability.descriptor
            HStack(spacing: 8) {
                Button(action: select) {
                    HStack(spacing: 9) {
                        SettingsIconTile(systemImage: descriptor.systemImage, tint: descriptor.iconTint, size: 22)
                        Text(descriptor.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if model.settingsAttentionCount(for: page) > 0 {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Needs attention")
                        }
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsSidebarButtonStyle(isSelected: isSelected))
                .accessibilityIdentifier("plugins.row.\(page.launchToken)")
                Toggle("Turn \(descriptor.title) on or off", isOn: CapabilityToggleBinding(model: model, capability: capability).value)
                    .settingsCompactSwitch()
                    .labelsHidden()
                    .accessibilityIdentifier("plugins.toggle.\(capability.rawValue)")
            }
            .padding(.trailing, 6)
        }
    }
}
