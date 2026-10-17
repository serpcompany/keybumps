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

/// Something a plugin does that Quick Search offers, with the kind Action, while the plugin is on
/// (#468): Record Screen, or Show or Hide Keystrokes. The manifest declares it; the plugin's
/// module runs it (`CapabilityModule.perform(_:_:)`) and can name it after its state
/// (`CapabilityModule.title(for:_:)`).
struct PluginAction: Hashable, Identifiable {
    /// Unique across plugins and never changed once shipped: it names the row's accessibility
    /// identifier (`quickSearch.action.<id>`) and its learned usage (`action:<id>`).
    let id: String
    /// Its name when the module doesn't give one for its state.
    let title: String
    /// Other words that find it, as a capability's search keywords do.
    var keywords: [String] = []
    let systemImage: String
    /// The plugin's shortcut that does the same, whose keycaps its row shows while one is assigned.
    var shortcut: CapabilityShortcut?
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
/// ever runs; Settings shows its `requirement`. Within a plugin, Screengrabs' recording needs
/// macOS 15 (`supportsRecording`, ADR 0010), where its screenshots don't.
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

    /// Whether Screengrabs can record here: ScreenCaptureKit records the screen, the microphone, and
    /// the Mac's sound in one stream from macOS 15. Settings, Quick Search's Record Screen, its
    /// shortcut, and the menu bar read this, never `#available`, which a test can't fake; on macOS 14
    /// Screengrabs takes screenshots only, and macOS keeps ⇧⌘5.
    var supportsRecording: Bool { macOSMajorVersion >= Self.recordingMacOS }

    /// The oldest macOS Screengrabs records on.
    static let recordingMacOS = 15

    /// What Settings says in place of recording where it isn't supported.
    static let recordingRequirement = "Recording needs macOS \(recordingMacOS)"
}

/// Who makes a plugin. For now every plugin is official, built by Keybumps (ADR 0006).
enum PluginPublisher: Equatable {
    case keybumps

    var name: String { "Keybumps" }
    var isOfficial: Bool { true }
}

/// A setting a plugin declares in its manifest. The shell draws it on the plugin's Settings page
/// and stores it under the plugin's own name (`plugin.<capability>.<key>`), as Raycast draws and
/// keeps an extension's declared preferences. One that moved from a retired plugin keeps that
/// plugin's name (`storageName`), so nothing is copied: Screengrabs' recording settings are still
/// `plugin.screencast.<key>` (ADR 0010).
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

    /// Where the plugin's Settings page draws it.
    enum Placement: Equatable {
        /// Under its group's heading (`CapabilityDescriptor.preferenceGroups`).
        case inGroup
        /// Under the page's header, before its Commands, with no heading, for a switch that governs
        /// the rest of the page, such as Keystrokes' Show keystrokes. Its `group` isn't drawn, and
        /// it can't change while the plugin is off.
        case top
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
    var placement = Placement.inGroup
    /// The plugin name it's stored under when that isn't its plugin's ID: the retired plugin it
    /// came from. Never changed once shipped.
    var storageName: String?

    var id: String { key }

    var defaultValue: Value {
        switch kind {
        case .toggle(let value): .bool(value)
        case .choice(_, let value): .choice(value)
        }
    }

    /// The name it's stored under, also its row's accessibility identifier.
    func storageKey(for capability: Capability) -> String {
        "plugin.\(storageName ?? capability.rawValue).\(key)"
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

    /// Its declared preferences placed at the top of its page, in the order they're declared.
    var topPreferences: [PluginPreference] {
        preferences.filter { $0.placement == .top }
    }

    /// Its other declared preferences in groups, in the order they're declared.
    var preferenceGroups: [(title: String, preferences: [PluginPreference])] {
        preferences.filter { $0.placement == .inGroup }.reduce(into: []) { groups, preference in
            if let index = groups.firstIndex(where: { $0.title == preference.group }) {
                groups[index].preferences.append(preference)
            } else {
                groups.append((preference.group, [preference]))
            }
        }
    }
}
