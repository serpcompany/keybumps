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
            content: { AnyView(KeystrokesSettingsPage()) }
        ),
        criticalOperations: [],
        searchKeywords: ["keys", "keycastr", "demo"],
        actions: [.toggleKeystrokes],
        category: .media,
        preferences: [
            .keystrokesShowing, .keystrokesStyle, .keystrokesPosition, .keystrokesSize, .keystrokesDuration,
            .keystrokesKeys, .keystrokesNamesActions, .keystrokesShowsClicks,
        ],
        isOnByDefault: false
    )
}

extension PluginAction {
    /// Quick Search's Show Keystrokes or Hide Keystrokes, named for what it does now, which does
    /// what the Show & Hide Keystrokes shortcut does (`KeystrokesModule.perform`).
    static let toggleKeystrokes = PluginAction(
        id: "toggleKeystrokes",
        title: "Show & Hide Keystrokes",
        keywords: ["show keystrokes", "hide keystrokes", "keys", "keycastr", "toggle"],
        systemImage: "eye",
        shortcut: .keystrokes
    )
}

extension PluginPreference {
    /// Whether the keys show while the plugin is on: hiding them doesn't turn the plugin off.
    static let keystrokesShowing = PluginPreference(
        key: "showing",
        title: "Show keys on screen",
        subtitle: "Turn this off to take the keys off the screen without turning Keystrokes off. Show Keystrokes in the menu bar menu, and the Show & Hide Keystrokes shortcut, do the same.",
        group: "Keys on screen",
        kind: .toggle(default: true)
    )
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
/// plugin is on and its keys are shown, and owns the optional Show & Hide Keystrokes shortcut. It
/// ships off. Shown or hidden is its own remembered state (`plugin.keystrokes.showing`), apart from
/// turning the plugin on or off: Settings' Show keys on screen switch, the menu bar's Show
/// Keystrokes item, the shortcut, and Quick Search's actions all go through `setShowing`. Hidden
/// lets go of the plugin's hold, so no keyboard tap runs for it. The display belongs to the shell,
/// so a Screencast recording holds it with the plugin off or hidden; the plugin lets go of only its
/// own hold. Its Settings attention is its missing Input Monitoring.
@MainActor
final class KeystrokesModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.keystrokes
    private let display: KeyDisplay
    private let preferences: AppPreferences
    private let menuBar: CapabilityMenuBarStatus?
    private let notices: any PaletteNoticePresenting
    /// Opens Settings on a page; nothing unless the app passes it, so tests never open Settings.
    private let openSettings: @MainActor (SettingsSection) -> Void
    /// Whether the plugin is on, as last applied.
    private var isOn = false

    init(
        display: KeyDisplay,
        preferences: AppPreferences,
        menuBar: CapabilityMenuBarStatus? = nil,
        notices: (any PaletteNoticePresenting)? = nil,
        openSettings: @escaping @MainActor (SettingsSection) -> Void = { _ in }
    ) {
        self.display = display
        self.preferences = preferences
        self.menuBar = menuBar
        self.notices = notices ?? PaletteHUD.shared
        self.openSettings = openSettings
    }

    /// Whether the keys show while the plugin is on. Remembered across launches; on by default.
    var isShowing: Bool { preferences.bool(.keystrokesShowing, for: .keystrokes) }

    /// Shows or hides the keys and remembers it. While the plugin is off it's only remembered.
    /// `announces` confirms it with a notch notice, as the shortcut does.
    func setShowing(_ showing: Bool, announces: Bool = false) {
        preferences.set(.bool(showing), of: .keystrokesShowing, for: .keystrokes)
        update()
        if announces { notices.showNotice(showing ? "Showing keystrokes" : "Keystrokes hidden", isWarning: false) }
    }

    /// Shows the keys if they're hidden, or hides them.
    func toggleShowing(announces: Bool = false) {
        setShowing(!isShowing, announces: announces)
    }

    func apply(_ context: CapabilityContext) {
        isOn = context.isEnabled(capability)
        context.configureShortcut(
            owner: CapabilityShortcut.keystrokes.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .keystrokes)
        ) { [weak self] in
            self?.toggleShowing(announces: true)
        }
        update()
    }

    func deactivate(_ context: CapabilityContext) {
        isOn = false
        display.release(.keystrokes)
        menuBar?.clear()
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    func title(for action: PluginAction, _ context: CapabilityContext) -> String? {
        guard action == .toggleKeystrokes else { return nil }
        return isShowing ? "Hide Keystrokes" : "Show Keystrokes"
    }

    /// Quick Search's Show or Hide Keystrokes does what the shortcut does, with its notch notice.
    /// Without Input Monitoring no keys could show, so Show Keystrokes opens Keystrokes' page,
    /// which asks for it, as Start Screencast opens Screencast's.
    func perform(_ action: PluginAction, _ context: CapabilityContext) {
        guard action == .toggleKeystrokes else { return }
        if !isShowing, context.permissionReadiness([capability]).missingCount > 0 {
            openSettings(.keystrokes)
            return
        }
        toggleShowing(announces: true)
    }

    /// Holds the display while the plugin is on and showing, and lists Show Keystrokes, checked
    /// while the keys show, in the menu bar menu while the plugin is on.
    private func update() {
        if isOn, isShowing {
            display.acquire(.keystrokes, configuration: preferences.keystrokesConfiguration)
        } else {
            display.release(.keystrokes)
        }
        guard isOn else {
            menuBar?.clear()
            return
        }
        menuBar?.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "keystrokes.showing", title: "Show Keystrokes", systemImage: nil, isChecked: isShowing) { [weak self] in
                self?.toggleShowing()
            },
        ])
    }
}

/// Keystrokes' Settings page: the plugin template (`PluginSettingsPage`'s parts, in its order),
/// with the Show keys on screen switch first, under the header, so the keys can be hidden without
/// turning the plugin off.
private struct KeystrokesSettingsPage: View {
    var body: some View {
        let descriptor = CapabilityDescriptor.keystrokes
        SettingsPage {
            CapabilityControl(capability: .keystrokes, byline: PluginSettingsPage<EmptyView>.byline(descriptor))
            SettingsGroup {
                PluginPreferenceRow(capability: .keystrokes, preference: .keystrokesShowing)
            }
            SettingsGroup("Commands") {
                ForEach(descriptor.shortcuts) { CapabilityShortcutEditor(shortcut: $0) }
            }
            PluginPermissionsGroup(capability: .keystrokes)
            PluginPreferenceGroups(capability: .keystrokes, excluding: [PluginPreference.keystrokesShowing.key])
        }
    }
}
