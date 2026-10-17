import SwiftUI

/// A plugin's Settings page, drawn from its manifest in one fixed order, as Raycast draws every
/// extension's settings: its header with who makes it, any preference placed at the top, its
/// Commands, the permissions it needs and then the ones it can use (marked Optional), a slot for
/// parts of its own that come before its declared preferences (such as ScreenGrabs' Screenshots
/// group), its other declared preferences by group, each ending with any rows the page adds to it
/// (such as ScreenGrabs' recordings folder under Recordings), and last a slot for parts no
/// declaration covers (such as a library to edit). The slots are empty unless the page fills them.
/// The other plugins move over one at a time.
struct PluginSettingsPage<AbovePreferences: View, GroupRows: View, Custom: View>: View {
    let capability: Capability
    /// The headings of declared groups whose preferences can't change now, such as ScreenGrabs'
    /// Recordings where it can't record.
    let unavailableGroups: Set<String>
    let abovePreferences: AbovePreferences
    /// The rows the page adds at the end of one of its declared groups, by the group's heading.
    let groupRows: (String) -> GroupRows
    let custom: Custom

    init(
        capability: Capability,
        unavailableGroups: Set<String> = [],
        @ViewBuilder abovePreferences: () -> AbovePreferences,
        @ViewBuilder groupRows: @escaping (String) -> GroupRows,
        @ViewBuilder custom: () -> Custom
    ) {
        self.capability = capability
        self.unavailableGroups = unavailableGroups
        self.abovePreferences = abovePreferences()
        self.groupRows = groupRows
        self.custom = custom()
    }

    var body: some View {
        let descriptor = capability.descriptor
        SettingsPage {
            CapabilityControl(capability: capability, shortcuts: descriptor.shortcuts, byline: Self.byline(descriptor))
            PluginPermissionsGroup(capability: capability)
            abovePreferences
            PluginPreferenceGroups(capability: capability, unavailable: unavailableGroups, rows: groupRows)
            custom
        }
    }

    /// "Official plugin by Keybumps · Productivity"
    static func byline(_ descriptor: CapabilityDescriptor) -> String {
        let kind = descriptor.publisher.isOfficial ? "Official plugin" : "Plugin"
        return "\(kind) by \(descriptor.publisher.name) · \(descriptor.category.rawValue)"
    }
}

extension PluginSettingsPage where GroupRows == EmptyView {
    init(
        capability: Capability,
        @ViewBuilder abovePreferences: () -> AbovePreferences,
        @ViewBuilder custom: () -> Custom
    ) {
        self.init(capability: capability, abovePreferences: abovePreferences, groupRows: { _ in EmptyView() }, custom: custom)
    }
}

extension PluginSettingsPage where AbovePreferences == EmptyView, GroupRows == EmptyView {
    init(capability: Capability, @ViewBuilder custom: () -> Custom) {
        self.init(capability: capability, abovePreferences: { EmptyView() }, custom: custom)
    }
}

extension PluginSettingsPage where AbovePreferences == EmptyView, GroupRows == EmptyView, Custom == EmptyView {
    init(capability: Capability) {
        self.init(capability: capability, abovePreferences: { EmptyView() }, custom: { EmptyView() })
    }
}

/// A plugin page's Permissions group: a `PermissionRow` for each permission its manifest declares,
/// the ones it needs and then the ones it can use, marked Optional with why. Every plugin page shows
/// its optional permissions here (#379). A required permission's row stays after it's granted, and
/// offers Open System Settings…, then Restart Keybumps once macOS needs a restart to apply it. The
/// rows follow System Settings while the page is open, as the Permissions page's do.
struct PluginPermissionsGroup: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        let descriptor = capability.descriptor
        let required = MacPermission.allCases.filter(descriptor.requiredPermissions.contains)
        if !required.isEmpty || !descriptor.optionalPermissions.isEmpty {
            SettingsGroup("Permissions") {
                ForEach(required, id: \.self) {
                    PermissionRow(permission: $0)
                }
                ForEach(descriptor.optionalPermissions, id: \.permission) {
                    PermissionRow(permission: $0.permission, optionalReason: $0.reason)
                }
            }
            .task { await model.monitorSystemPermissionChanges() }
        }
    }
}

/// A plugin's declared preferences, a `SettingsGroup` for each of their groups, each ending with the
/// rows its page adds to it. A page drawn by hand, as Dictation's is, lists them here too, so they
/// move to the template unchanged. Those placed at the top are drawn by `CapabilityControl` instead.
struct PluginPreferenceGroups<Rows: View>: View {
    let capability: Capability
    /// The headings of groups whose preferences can't change now.
    var unavailable: Set<String> = []
    let rows: (String) -> Rows

    var body: some View {
        ForEach(capability.descriptor.preferenceGroups, id: \.title) { group in
            SettingsGroup(group.title) {
                ForEach(group.preferences) { PluginPreferenceRow(capability: capability, preference: $0) }
                    .disabled(unavailable.contains(group.title))
                rows(group.title)
            }
        }
    }
}

extension PluginPreferenceGroups where Rows == EmptyView {
    init(capability: Capability) {
        self.init(capability: capability, rows: { _ in EmptyView() })
    }
}

/// One declared preference: a switch or a menu. A change applies the capabilities again, so the
/// plugin's module picks it up at once. Each row reports its key through `Shown`, and through
/// `Disabled` while it can't change, so a test can lay out every plugin's page and check it draws
/// each declared preference once, and which can't change.
struct PluginPreferenceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    let capability: Capability
    let preference: PluginPreference

    var body: some View {
        control
            .preference(key: Shown.self, value: [preference.key])
            .preference(key: Disabled.self, value: isEnabled ? [] : [preference.key])
    }

    @ViewBuilder
    private var control: some View {
        switch preference.kind {
        case .toggle:
            Toggle(isOn: Binding(
                get: { model.preferences.bool(preference, for: capability) },
                set: { update(.bool($0)) }
            )) {
                SettingsRowLabel(title: preference.title, subtitle: preference.subtitle)
            }
            .toggleStyle(SettingsSwitchToggleStyle())
            .accessibilityIdentifier(identifier)
        case .choice(let options, _):
            Picker(selection: Self.selection(of: preference, for: capability, in: model)) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            } label: {
                SettingsRowLabel(title: preference.title, subtitle: preference.subtitle)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    private var identifier: String { preference.storageKey(for: capability) }

    /// The keys of the rows a page draws, in order.
    struct Shown: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
    }

    /// The keys of the rows a page draws that can't change now, in order.
    struct Disabled: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
    }

    private func update(_ value: PluginPreference.Value) {
        model.setPluginPreference(preference, to: value, for: capability)
    }

    /// A menu row's selection: the value stored, or the default, and choosing one sets it as any
    /// change on the page does (`AppModel.setPluginPreference`). Tests drive it as the menu does.
    static func selection(of preference: PluginPreference, for capability: Capability, in model: AppModel) -> Binding<String> {
        Binding(
            get: {
                if case .choice(let value) = model.preferences.value(of: preference, for: capability) { return value }
                return ""
            },
            set: { model.setPluginPreference(preference, to: .choice($0), for: capability) }
        )
    }
}
