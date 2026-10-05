import SwiftUI

/// A plugin's Settings page, drawn from its manifest in one fixed order, as Raycast draws every
/// extension's settings: its header with who makes it, its Commands, the permissions it needs, its
/// declared preferences by group, and last a slot for parts no declaration covers (such as a
/// library to edit). Timer uses it so far; the other plugins move over one at a time.
struct PluginSettingsPage<Custom: View>: View {
    @Environment(AppModel.self) private var model
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
            if !descriptor.requiredPermissions.isEmpty {
                SettingsGroup("Permissions") {
                    ForEach(MacPermission.allCases.filter(descriptor.requiredPermissions.contains), id: \.self) {
                        PermissionRow(permission: $0)
                    }
                }
            }
            ForEach(descriptor.preferenceGroups, id: \.title) { group in
                SettingsGroup(group.title) {
                    ForEach(group.preferences) { PluginPreferenceRow(capability: capability, preference: $0) }
                }
            }
            custom
        }
        .task {
            // Permission rows follow System Settings while the page is open, as other pages' do.
            guard !descriptor.requiredPermissions.isEmpty else { return }
            await model.monitorSystemPermissionChanges()
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
