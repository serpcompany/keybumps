import Foundation

/// Where a plugin is listed in the Store, as Raycast's categories are.
enum PluginCategory: String, CaseIterable, Identifiable {
    case productivity = "Productivity"
    case writing = "Writing"
    case media = "Media"

    var id: String { rawValue }
}

/// The website's Plugins page, which Settings › Plugins links to. It lists every plugin from its own
/// copy of the manifests' facts (`apps/web/src/lib/plugins.ts`). Every plugin ships in the app for
/// now (ADR 0006), so the page only shows them; Settings › Plugins turns them on and off.
enum PluginLinks {
    static let website = URL(string: "https://keybumps.app/plugins")!
}

/// A permission a plugin can use but doesn't need, such as Accessibility to paste, and why it helps.
/// Its Settings page lists it as Optional; it never counts as missing setup.
struct PluginOptionalPermission: Equatable {
    let permission: MacPermission
    /// What it adds, and what happens without it.
    let reason: String
}

/// The one rule for plugins that need a newer macOS than Keybumps does (#322): one whose
/// `minimumMacOS` is newer than this Mac's can't be turned on, and is never on. `AppPreferences`
/// applies it to the plugins that are on, so no module, palette tab, or shortcut of such a plugin
/// ever runs; Settings shows its `requirement`.
struct PluginCompatibility: Equatable {
    /// This Mac's macOS major version, such as 15. Tests pass their own.
    let macOSMajorVersion: Int

    static let current = PluginCompatibility(
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    func supports(_ capability: Capability) -> Bool {
        guard let minimum = capability.descriptor.minimumMacOS else { return true }
        return macOSMajorVersion >= minimum
    }

    /// Why it can't be turned on here, such as "Requires macOS 15"; nil when it can.
    func requirement(for capability: Capability) -> String? {
        guard !supports(capability), let minimum = capability.descriptor.minimumMacOS else { return nil }
        return "Requires macOS \(minimum)"
    }
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
    /// The key of another menu of the same plugin that never has the same value, such as
    /// Translation's two languages. Choosing that one's value swaps the two (`AppPreferences.set`).
    var differsFrom: String?

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

    /// Whether `value` is of this preference's kind, and for a menu one of its options.
    func accepts(_ value: Value) -> Bool {
        switch (kind, value) {
        case (.toggle, .bool): true
        case (.choice(let options, _), .choice(let choice)): options.contains { $0.value == choice }
        default: false
        }
    }

    /// What a stored object reads as, or nil when it doesn't fit, so the default applies. A switch
    /// takes a number or the strings `defaults write` and launch arguments give (YES/NO, true/false,
    /// 1/0), as other Bool settings do.
    func value(fromStored object: Any?) -> Value? {
        switch kind {
        case .toggle:
            if let number = object as? NSNumber { return .bool(number.boolValue) }
            switch (object as? String)?.lowercased() {
            case "yes", "true", "1": return .bool(true)
            case "no", "false", "0": return .bool(false)
            default: return nil
            }
        case .choice:
            guard let string = object as? String, accepts(.choice(string)) else { return nil }
            return .choice(string)
        }
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
