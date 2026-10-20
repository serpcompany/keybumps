import SwiftUI

/// Settings › Quick Search's tab list (#553): every tab, in the saved order, with its tab key while
/// it's in the tab bar, buttons that move it up and down, and a show switch while its plugin is on.
enum QuickSearchTabList {
    struct Row: Identifiable, Equatable {
        let tab: CommandPaletteTab
        /// Whether it's in the tab bar while no hidden tab is open (`CommandPaletteTab.shownTabs`).
        let isShown: Bool
        /// Its tab key, its place among the shown tabs (`CommandPaletteTab.tabKey`). Nil while it
        /// isn't shown: keys never skip a tab.
        let key: String?
        /// The plugin that's off, so the tab can't show: its own, or the one whose data it lists,
        /// such as Clipboard History for the ScreenGrabs tab on macOS 14. Nil while it can show.
        let pluginOff: Capability?
        /// Why it can't show, under its name: "<Plugin> is turned off", or the plugin's
        /// "Requires macOS 15" where this Mac's macOS can't run it (`PluginCompatibility`), as its
        /// own page and Settings › Plugins say. Nil while it can show.
        let note: String?
        /// Whether it has a show switch: every tab has one while its plugin is on (#553 decision 3).
        /// The Search tab's took the place of turning Quick Search off, and the Hotkeys tab's was on
        /// Settings › Shortcut Coach.
        let hasShowSwitch: Bool
        /// Whether it's the only tab shown, so its switch can't turn off.
        let isOnlyShownTab: Bool
        /// Whether it's first or last in the order, so it can't move up or down.
        let isFirst: Bool
        let isLast: Bool

        var id: CommandPaletteTab { tab }

        /// Its tab key, and a dash while it has none.
        var tabKey: String { key ?? "—" }
    }

    static func rows(
        hidden: Set<CommandPaletteTab>,
        enabled: Set<Capability>,
        compatibility: PluginCompatibility = .current,
        order: [CommandPaletteTab] = CommandPaletteTab.defaultOrder
    ) -> [Row] {
        let tabs = CommandPaletteTab.ordered(order)
        let available = CommandPaletteTab.availableTabs(enabled: enabled, compatibility: compatibility, order: order)
        let shown = CommandPaletteTab.shownTabs(hidden: hidden, enabled: enabled, compatibility: compatibility, order: order)
        return tabs.enumerated().map { index, tab in
            let canShow = available.contains(tab)
            let pluginOff = canShow ? nil : enabled.contains(tab.owner) ? tab.dataSource : tab.owner
            return Row(
                tab: tab,
                isShown: shown.contains(tab),
                key: CommandPaletteTab.tabKey(for: tab, among: shown),
                pluginOff: pluginOff,
                note: pluginOff.map { compatibility.requirement(for: $0) ?? "\($0.title) is turned off" },
                hasShowSwitch: canShow,
                isOnlyShownTab: shown == [tab],
                isFirst: index == 0,
                isLast: index == tabs.count - 1
            )
        }
    }

    /// What a dragged row carries: its tab, marked as Keybumps', so text dragged in from elsewhere
    /// never moves a tab.
    static func dragPayload(for tab: CommandPaletteTab) -> String {
        dragPrefix + tab.rawValue
    }

    /// The tab a dropped `payload` carries, if it's a dragged row's (`dragPayload`).
    static func tab(fromDragPayload payload: String) -> CommandPaletteTab? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return CommandPaletteTab(rawValue: String(payload.dropFirst(dragPrefix.count)))
    }

    private static let dragPrefix = "keybumps.quickSearchTab:"
}

/// Settings › Quick Search, the window's page (#553). Quick Search is always on, so the page has
/// no switch: it holds ⌘Space and the tab list, where a row drags or moves to reorder the tabs and
/// its show switch takes its tab out of the tab bar.
struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        SettingsPage {
            CapabilityControl(capability: .quickSearch, shortcuts: [.quickSearch])
            if let manualRecovery = model.quickSearchSpotlightRecovery {
                // After the update couldn't take ⌘Space from Spotlight (#553), as first-time setup shows it.
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Quick Search still needs attention.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(manualRecovery)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Keyboard Shortcuts…") { model.openKeyboardShortcutSettings() }
                            Button("Check Again") { model.checkQuickSearchSpotlightAgain() }
                        }
                    }
                }
            }
            SettingsGroup {
                LabeledContent {
                    Button("Open") { model.showQuickSearch() }
                        .accessibilityIdentifier("settings.quickSearch.open")
                } label: {
                    SettingsRowLabel(title: "Open Quick Search", subtitle: "On the first tab shown.")
                }
            }
            SettingsGroup(
                "Tabs",
                subtitle: "Drag a tab, or use the arrows. ⌘1 is the first tab shown, ⌘2 the second, and so on, "
                    + "and Quick Search opens on the first. One tab always stays shown."
            ) {
                ForEach(QuickSearchTabList.rows(
                    hidden: preferences.hiddenTabs,
                    enabled: preferences.enabledCapabilities,
                    compatibility: preferences.compatibility,
                    order: preferences.tabOrder
                )) { row in
                    QuickSearchTabRow(row: row)
                }
            } accessory: {
                // Disabled while the order is already the default, so it never looks like it did nothing.
                Button("Reset Order") { preferences.resetTabOrder() }
                    .disabled(preferences.isDefaultTabOrder)
                    .help("Puts the tabs back in their original order. Which tabs show stays as it is.")
                    .accessibilityIdentifier("settings.quickSearch.resetOrder")
            }
        }
        .navigationTitle("Quick Search")
    }
}

/// A tab's row: a grip to drag it by, its tab key, icon, and name, why it can't show while its
/// plugin is off, buttons that move it up and down, and its show switch while its plugin is on.
private struct QuickSearchTabRow: View {
    @Environment(AppModel.self) private var model
    let row: QuickSearchTabList.Row
    /// Whether a dragged row is over this one, which it moves to on drop.
    @State private var isDropTarget = false

    var body: some View {
        let tab = row.tab
        HStack(spacing: 11) {
            // The grip, key, icon, and name drag the row; the buttons and switch stay clickable.
            HStack(spacing: 11) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
                Text(row.tabKey)
                    .monospacedDigit()
                    .foregroundStyle(row.isShown ? .secondary : .tertiary)
                    .frame(width: 30, alignment: .leading)
                    .help(row.isShown ? "Its tab key" : "Not in the tab bar")
                    .accessibilityLabel(row.key.map { "Tab key \($0)" } ?? "Not in the tab bar")
                    .accessibilityIdentifier("settings.quickSearch.key.\(tab.rawValue)")
                SettingsIconTile(systemImage: tab.systemImage, tint: tab.owner.descriptor.iconTint, size: 22)
                    .opacity(row.isShown ? 1 : 0.45)
                    .accessibilityHidden(true)
                SettingsRowLabel(title: tab.title, subtitle: row.note)
                    .foregroundStyle(row.isShown ? .primary : .secondary)
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
            .draggable(QuickSearchTabList.dragPayload(for: tab)) {
                Label(tab.title, systemImage: tab.systemImage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous))
            }
            HStack(spacing: 4) {
                Button { model.preferences.moveTab(tab, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(row.isFirst)
                .help("Move Up")
                .accessibilityLabel("Move \(tab.title) Up")
                .accessibilityIdentifier("settings.quickSearch.moveUp.\(tab.rawValue)")
                Button { model.preferences.moveTab(tab, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(row.isLast)
                .help("Move Down")
                .accessibilityLabel("Move \(tab.title) Down")
                .accessibilityIdentifier("settings.quickSearch.moveDown.\(tab.rawValue)")
            }
            .buttonStyle(TabMoveButtonStyle())
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
            } else {
                // A switch's room, kept empty while the plugin is off, so every row's move buttons line up.
                Toggle("", isOn: .constant(false))
                    .settingsCompactSwitch()
                    .labelsHidden()
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .background(
            isDropTarget ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
        )
        .dropDestination(for: String.self) { payloads, _ in
            guard let dragged = payloads.lazy.compactMap(QuickSearchTabList.tab(fromDragPayload:)).first,
                  dragged != tab else { return false }
            model.preferences.moveTab(dragged, to: tab)
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.quickSearch.tab.\(tab.rawValue)")
    }
}

/// The small square buttons that move a tab up or down.
private struct TabMoveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold))
            .frame(width: 20, height: 20)
            .background(
                SettingsTheme.control.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}
