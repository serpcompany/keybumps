import SwiftUI

/// Settings › Quick Search's tab list (#553): every tab, in tab-key order, with its tab key while
/// it's in the tab bar, and a show switch on the tabs that have one.
enum QuickSearchTabList {
    /// The tabs with a show switch: the Search tab, whose switch took the place of turning Quick
    /// Search off, and the Hotkeys tab, whose switch was on Settings › Shortcut Coach.
    static let tabsWithShowSwitch: Set<CommandPaletteTab> = [.search, .keyboardShortcutter]

    struct Row: Identifiable, Equatable {
        let tab: CommandPaletteTab
        /// Whether it's in the tab bar while no hidden tab is open (`CommandPaletteTab.shownTabs`).
        let isShown: Bool
        /// The plugin that's off, so the tab can't show: its own, or the one whose data it lists,
        /// such as Clipboard History for the ScreenGrabs tab on macOS 14. Nil while it can show.
        let pluginOff: Capability?
        /// Whether it has a show switch: one of `tabsWithShowSwitch` whose plugin is on.
        let hasShowSwitch: Bool
        /// Whether it's the only tab shown, so its switch can't turn off.
        let isOnlyShownTab: Bool

        var id: CommandPaletteTab { tab }

        /// Its tab key while it's in the tab bar, and a dash while it isn't.
        var tabKey: String { isShown ? tab.shortcutLabel : "—" }
    }

    static func rows(
        hidden: Set<CommandPaletteTab>,
        enabled: Set<Capability>,
        compatibility: PluginCompatibility = .current
    ) -> [Row] {
        let available = CommandPaletteTab.availableTabs(enabled: enabled, compatibility: compatibility)
        let shown = CommandPaletteTab.shownTabs(hidden: hidden, enabled: enabled, compatibility: compatibility)
        return CommandPaletteTab.allCases.map { tab in
            let canShow = available.contains(tab)
            return Row(
                tab: tab,
                isShown: shown.contains(tab),
                pluginOff: canShow ? nil : enabled.contains(tab.owner) ? tab.dataSource : tab.owner,
                hasShowSwitch: canShow && tabsWithShowSwitch.contains(tab),
                isOnlyShownTab: shown == [tab]
            )
        }
    }
}

/// Settings › Quick Search, the window's page (#553). Quick Search is always on, so the page has
/// no switch: it holds ⌘Space and the tab list, where a show switch takes its tab out of the tab bar.
struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        SettingsPage {
            CapabilityControl(capability: .quickSearch, shortcuts: [.quickSearch])
            SettingsGroup {
                LabeledContent {
                    Button("Open") { model.showQuickSearch() }
                } label: {
                    SettingsRowLabel(title: "Open Quick Search", subtitle: "On the first tab shown.")
                }
            }
            SettingsGroup("Tabs", subtitle: "Quick Search opens on the first tab shown, and one tab always stays shown.") {
                ForEach(QuickSearchTabList.rows(
                    hidden: preferences.hiddenTabs,
                    enabled: preferences.enabledCapabilities,
                    compatibility: preferences.compatibility
                )) { row in
                    QuickSearchTabRow(row: row)
                }
            }
        }
        .navigationTitle("Quick Search")
    }
}

/// A tab's row: its tab key, icon, and name, why it can't show while its plugin is off, and its
/// show switch, if it has one.
private struct QuickSearchTabRow: View {
    @Environment(AppModel.self) private var model
    let row: QuickSearchTabList.Row

    var body: some View {
        let tab = row.tab
        HStack(spacing: 11) {
            Text(row.tabKey)
                .monospacedDigit()
                .foregroundStyle(row.isShown ? .secondary : .tertiary)
                .frame(width: 30, alignment: .leading)
                .help(row.isShown ? "Its tab key" : "Not in the tab bar")
                .accessibilityLabel(row.isShown ? "Tab key \(row.tabKey)" : "Not in the tab bar")
            SettingsIconTile(systemImage: tab.systemImage, tint: tab.owner.descriptor.iconTint, size: 22)
                .opacity(row.isShown ? 1 : 0.45)
                .accessibilityHidden(true)
            SettingsRowLabel(title: tab.title, subtitle: row.pluginOff.map { "\($0.title) is turned off" })
                .foregroundStyle(row.isShown ? .primary : .secondary)
            Spacer(minLength: 12)
            if row.hasShowSwitch {
                Toggle("Show \(tab.title) tab", isOn: Binding(
                    get: { row.isShown },
                    set: { model.preferences.setShowsTab(tab, $0) }
                ))
                .settingsCompactSwitch()
                .labelsHidden()
                .disabled(row.isOnlyShownTab)
                .help(row.isOnlyShownTab ? "One tab always stays shown" : row.isShown ? "Hide the \(tab.title) tab" : "Show the \(tab.title) tab")
                .accessibilityIdentifier("settings.quickSearch.show.\(tab.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.quickSearch.tab.\(tab.rawValue)")
    }
}
