import SwiftUI

extension CapabilityDescriptor {
    static let keystrokes = CapabilityDescriptor(
        capability: .keystrokes,
        title: "Keystrokes",
        systemImage: "command.square",
        iconTint: .pink,
        // The key display hears keys through a listen-only keyboard tap (`KeyTypingMonitor`).
        requiredPermissions: [.inputMonitoring],
        dependencies: [],
        paletteTab: nil,
        settingsPage: CapabilitySettingsPage(
            section: .keystrokes,
            summary: "Show the shortcuts you press on screen, for demos, recordings, and screen sharing.",
            disableExplanation: "Turning this off takes the keys off the screen, stops listening to the keyboard, and releases its global shortcut.",
            content: { AnyView(PluginSettingsPage(capability: .keystrokes)) }
        ),
        criticalOperations: [],
        searchKeywords: ["keys", "keycastr", "demo"],
        category: .media,
        preferences: [
            .keystrokesStyle, .keystrokesPosition, .keystrokesSize, .keystrokesDuration,
            .keystrokesKeys, .keystrokesNamesActions, .keystrokesShowsClicks,
        ],
        isOnByDefault: false
    )
}

extension PluginPreference {
    static let keystrokesStyle = PluginPreference(
        key: "style",
        title: "Style",
        subtitle: "Keycaps shows a key for each key you press. Bezel is KeyCastr’s classic dark bar.",
        group: "Display",
        kind: .choice(
            options: [.init(value: KeyDisplayConfiguration.Style.keycaps.rawValue, title: "Keycaps"),
                      .init(value: KeyDisplayConfiguration.Style.bezel.rawValue, title: "Bezel (classic)")],
            default: KeyDisplayConfiguration.Style.keycaps.rawValue
        )
    )
    static let keystrokesPosition = PluginPreference(
        key: "position",
        title: "Position",
        group: "Display",
        kind: .choice(
            options: [.init(value: KeyDisplayConfiguration.Position.bottomLeft.rawValue, title: "Bottom left"),
                      .init(value: KeyDisplayConfiguration.Position.bottomCenter.rawValue, title: "Bottom center"),
                      .init(value: KeyDisplayConfiguration.Position.bottomRight.rawValue, title: "Bottom right")],
            default: KeyDisplayConfiguration.Position.bottomCenter.rawValue
        )
    )
    static let keystrokesSize = PluginPreference(
        key: "size",
        title: "Size",
        group: "Display",
        kind: .choice(
            options: [.init(value: KeyDisplayConfiguration.Size.small.rawValue, title: "Small"),
                      .init(value: KeyDisplayConfiguration.Size.medium.rawValue, title: "Medium"),
                      .init(value: KeyDisplayConfiguration.Size.large.rawValue, title: "Large")],
            default: KeyDisplayConfiguration.Size.medium.rawValue
        )
    )
    /// How long the keys stay, in seconds.
    static let keystrokesDuration = PluginPreference(
        key: "duration",
        title: "Stays on screen",
        subtitle: "After the last key you press.",
        group: "Display",
        kind: .choice(
            options: [("1", "1 second"), ("1.5", "1.5 seconds"), ("2", "2 seconds"), ("3", "3 seconds"), ("5", "5 seconds")]
                .map { PluginPreference.Choice(value: $0, title: $1) },
            default: "1.5"
        )
    )
    static let keystrokesKeys = PluginPreference(
        key: "keys",
        title: "Show",
        subtitle: "All keys also shows what you type. Nothing shows while you type a password.",
        group: "Keys and clicks",
        kind: .choice(
            options: [.init(value: KeyDisplayConfiguration.Keys.shortcutsOnly.rawValue, title: "Shortcuts only (⌘ ⌃ ⌥)"),
                      .init(value: KeyDisplayConfiguration.Keys.allKeys.rawValue, title: "All keys")],
            default: KeyDisplayConfiguration.Keys.shortcutsOnly.rawValue
        )
    )
    static let keystrokesNamesActions = PluginPreference(
        key: "namesActions",
        title: "Name the action",
        subtitle: "“Copy” with ⌘C, for the shortcuts Keybumps knows: its own, and the standard macOS ones.",
        group: "Keys and clicks",
        kind: .toggle(default: true)
    )
    static let keystrokesShowsClicks = PluginPreference(
        key: "showsClicks",
        title: "Show clicks too",
        subtitle: "A ring where you click.",
        group: "Keys and clicks",
        kind: .toggle(default: false)
    )
}

extension AppPreferences {
    /// The key display as the Keystrokes plugin's settings have it.
    var keystrokesConfiguration: KeyDisplayConfiguration {
        let defaults = KeyDisplayConfiguration()
        return KeyDisplayConfiguration(
            style: .init(rawValue: choice(.keystrokesStyle, for: .keystrokes)) ?? defaults.style,
            position: .init(rawValue: choice(.keystrokesPosition, for: .keystrokes)) ?? defaults.position,
            keys: .init(rawValue: choice(.keystrokesKeys, for: .keystrokes)) ?? defaults.keys,
            namesActions: bool(.keystrokesNamesActions, for: .keystrokes),
            size: .init(rawValue: choice(.keystrokesSize, for: .keystrokes)) ?? defaults.size,
            linger: TimeInterval(choice(.keystrokesDuration, for: .keystrokes)) ?? defaults.linger,
            showsClicks: bool(.keystrokesShowsClicks, for: .keystrokes)
        )
    }
}

/// Keeps the shell's key display (`KeyDisplay`) showing, with this plugin's settings, while the
/// plugin is on, and owns the optional Show & Hide Keystrokes shortcut. It ships off. The display
/// belongs to the shell, so a Screencast recording can hold it with the plugin off; turning the
/// plugin off lets go of the plugin's hold only. Its Settings attention is its missing Input
/// Monitoring.
@MainActor
final class KeystrokesModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.keystrokes
    private let display: KeyDisplay
    private let notices: any PaletteNoticePresenting
    /// Whether Show & Hide Keystrokes hid the keys: until it's pressed again, or the plugin turns off.
    private(set) var isHidden = false

    init(display: KeyDisplay, notices: (any PaletteNoticePresenting)? = nil) {
        self.display = display
        self.notices = notices ?? PaletteHUD.shared
    }

    func apply(_ context: CapabilityContext) {
        let preferences = context.preferences
        context.configureShortcut(
            owner: CapabilityShortcut.keystrokes.ownerID,
            for: capability,
            binding: preferences.capabilityShortcut(for: .keystrokes)
        ) { [weak self] in
            self?.toggleHidden(preferences: preferences)
        }
        update(isOn: context.isEnabled(capability), preferences: preferences)
    }

    func deactivate(_ context: CapabilityContext) {
        isHidden = false
        display.release(.keystrokes)
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    /// Show & Hide Keystrokes, which is registered only while the plugin is on.
    func toggleHidden(preferences: AppPreferences) {
        isHidden.toggle()
        update(isOn: true, preferences: preferences)
        notices.showNotice(isHidden ? "Keystrokes hidden" : "Showing keystrokes", isWarning: false)
    }

    private func update(isOn: Bool, preferences: AppPreferences) {
        if isOn, !isHidden {
            display.acquire(.keystrokes, configuration: preferences.keystrokesConfiguration)
        } else {
            display.release(.keystrokes)
        }
    }
}
