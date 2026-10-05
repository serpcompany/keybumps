import Foundation

/// Where a plugin is listed in the Store, as Raycast's categories are.
enum PluginCategory: String, CaseIterable, Identifiable {
    case productivity = "Productivity"
    case writing = "Writing"
    case media = "Media"

    var id: String { rawValue }
}

/// Who makes a plugin. For now every plugin is official, built by Keybumps (ADR 0006).
enum PluginPublisher: Equatable {
    case keybumps

    var name: String { "Keybumps" }
    var isOfficial: Bool { true }
}

/// A setting a plugin declares in its manifest. The shell draws it on the plugin's Settings page
/// and stores it under the plugin's own name (`plugin.<capability>.<key>`), as Raycast draws and
/// keeps an extension's declared preferences.
struct PluginPreference: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A switch.
        case toggle(default: Bool)
        /// A menu of choices, by value.
        case choice(options: [Choice], default: String)
    }

    struct Choice: Equatable {
        let value: String
        let title: String
    }

    /// A stored value.
    enum Value: Equatable {
        case bool(Bool)
        case choice(String)
    }

    /// Unique within its plugin, and part of its stored name, so it never changes once shipped.
    let key: String
    let title: String
    var subtitle: String?
    /// The heading it's listed under; preferences that share one are drawn together.
    var group: String
    let kind: Kind

    var id: String { key }

    var defaultValue: Value {
        switch kind {
        case .toggle(let value): .bool(value)
        case .choice(_, let value): .choice(value)
        }
    }

    /// The name it's stored under.
    func storageKey(for capability: Capability) -> String {
        "plugin.\(capability.rawValue).\(key)"
    }
}

extension CapabilityDescriptor {
    /// The plugin's shortcuts, in the order Settings lists them.
    var shortcuts: [CapabilityShortcut] {
        CapabilityShortcut.allCases.filter { $0.capability == capability }
    }

    /// Its declared preferences in groups, in the order they're declared.
    var preferenceGroups: [(title: String, preferences: [PluginPreference])] {
        preferences.reduce(into: []) { groups, preference in
            if let index = groups.firstIndex(where: { $0.title == preference.group }) {
                groups[index].preferences.append(preference)
            } else {
                groups.append((preference.group, [preference]))
            }
        }
    }
}
