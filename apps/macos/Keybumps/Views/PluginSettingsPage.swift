import SwiftUI

/// A plugin's Settings page, drawn from its manifest in one fixed order, as Raycast draws every
/// extension's settings: its header with who makes it, its Commands, the permissions it needs and
/// then the ones it can use (marked Optional), its
/// declared preferences by group, and last a slot for parts no declaration covers (such as a
/// library to edit). Timer uses it so far; the other plugins move over one at a time.
struct PluginSettingsPage<Custom: View>: View {
    let capability: Capability
    let custom: Custom

    init(capability: Capability, @ViewBuilder custom: () -> Custom) {
        self.capability = capability
        self.custom = custom()
    }

    var body: some View {
        let descriptor = capability.descriptor
        SettingsPage {
            CapabilityControl(capability: capability, shortcuts: descriptor.shortcuts, byline: Self.byline(descriptor))
            PluginPermissionsGroup(capability: capability)
            ForEach(descriptor.preferenceGroups, id: \.title) { group in
                SettingsGroup(group.title) {
                    ForEach(group.preferences) { PluginPreferenceRow(capability: capability, preference: $0) }
                }
            }
            custom
        }
    }

    /// "Official plugin by Keybumps · Productivity"
    static func byline(_ descriptor: CapabilityDescriptor) -> String {
        let kind = descriptor.publisher.isOfficial ? "Official plugin" : "Plugin"
        return "\(kind) by \(descriptor.publisher.name) · \(descriptor.category.rawValue)"
    }
}

extension PluginSettingsPage where Custom == EmptyView {
    init(capability: Capability) {
        self.init(capability: capability) { EmptyView() }
    }
}

/// A plugin page's Permissions group: a `PermissionRow` for each permission its manifest declares,
/// the ones it needs and then the ones it can use, marked Optional with why. Every plugin page shows
/// its optional permissions here (#379). A page drawn by hand that already explains its required
/// permissions in rows of its own, as Screenshot Tools does Screen Recording, passes
/// `includesRequired: false`, so they aren't shown twice. The rows follow System Settings while the
/// page is open, as the Permissions page's do.
struct PluginPermissionsGroup: View {
    @Environment(AppModel.self) private var model
    let capability: Capability
    var includesRequired = true

    var body: some View {
        let descriptor = capability.descriptor
        let required = includesRequired ? MacPermission.allCases.filter(descriptor.requiredPermissions.contains) : []
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

/// One declared preference: a switch or a menu. A change applies the capabilities again, so the
/// plugin's module picks it up at once.
private struct PluginPreferenceRow: View {
    @Environment(AppModel.self) private var model
    let capability: Capability
    let preference: PluginPreference

    var body: some View {
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
            Picker(selection: Binding(
                get: {
                    if case .choice(let value) = model.preferences.value(of: preference, for: capability) { return value }
                    return ""
                },
                set: { update(.choice($0)) }
            )) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            } label: {
                SettingsRowLabel(title: preference.title, subtitle: preference.subtitle)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    private var identifier: String { "plugin.\(capability.rawValue).\(preference.key)" }

    private func update(_ value: PluginPreference.Value) {
        model.setPluginPreference(preference, to: value, for: capability)
    }
}
