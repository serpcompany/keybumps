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
            .keystrokesShowing, .keystrokesStyle, .keystrokesPosition, .keystrokesSize, .keystrokesDuration,
            .keystrokesKeys, .keystrokesNamesActions, .keystrokesShowsClicks,
        ],
        isOnByDefault: false
    )
}

extension PluginPreference {
    /// Whether the keys show while the plugin is on: hiding them doesn't turn the plugin off. Drawn
    /// at the top of its page, under the header.
    static let keystrokesShowing = PluginPreference(
        key: "showing",
        title: "Show keystrokes",
        subtitle: "Turn this off to take the keys off the screen without turning Keystrokes off. Show Keystrokes in the menu bar menu and the Show & Hide Keystrokes shortcut do the same.",
        group: "Keys on screen",
        kind: .toggle(default: true),
        placement: .top
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
/// plugin is on, and owns the optional Show & Hide Keystrokes shortcut. It ships off.
///
/// Shown or hidden is its own remembered state (`plugin.keystrokes.showing`), apart from on or off,
/// and acts on what's on screen now: hiding takes every holder's keys off the screen, a Screencast
/// recording's included, for the rest of that recording, and showing brings them back, a
/// recording's in its own look. While hidden, the plugin keeps holding the display with its keys
/// hidden, so it keeps its place behind a recording that started later; no keyboard tap runs
/// unless another holder shows keys. A recording that starts later shows its keys whatever Hidden
/// says. Turning the plugin on shows the keys (`willTurnOn`); a relaunch keeps them hidden.
///
/// The menu bar's Show Keystrokes item, the shortcut, and Quick Search's actions go through
/// `setShowing`. Settings' Show keystrokes switch writes the preference through
/// `AppModel.setPluginPreference`, which applies the capabilities again. Both reach `update`, which
/// shows or hides the keys on screen when the preference changed. The display belongs to the
/// shell, so a recording holds it with the plugin off or hidden; turning the plugin off lets go of
/// only its own hold. Its Settings attention is its missing Input Monitoring.
@MainActor
final class KeystrokesModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.keystrokes
    private let display: KeyDisplay
    private let preferences: AppPreferences
    private let menuBar: CapabilityMenuBarStatus?
    private let notices: any PaletteNoticePresenting
    /// Whether the plugin is on, as last applied.
    private var isOn = false
    /// Whether its keys were shown when it last applied while on; nil while it's off.
    private var appliedShowing: Bool?

    init(
        display: KeyDisplay,
        preferences: AppPreferences,
        menuBar: CapabilityMenuBarStatus? = nil,
        notices: (any PaletteNoticePresenting)? = nil
    ) {
        self.display = display
        self.preferences = preferences
        self.menuBar = menuBar
        self.notices = notices ?? PaletteHUD.shared
    }

    /// Whether the keys show while the plugin is on. Remembered across launches; on by default.
    var isShowing: Bool { preferences.bool(.keystrokesShowing, for: .keystrokes) }

    /// Shows or hides the keys on screen now, a recording's included, and remembers it. While the
    /// plugin is off it's only remembered. `announces` confirms it with a notch notice, as the
    /// shortcut does, which says why when the keys can't show.
    func setShowing(_ showing: Bool, announces: Bool = false) {
        preferences.set(.bool(showing), of: .keystrokesShowing, for: .keystrokes)
        update(actsOnScreen: true)
        if announces {
            let notice = Self.notice(showing: showing, isListening: display.isListening, isSecureInputOn: display.isSecureInputOn)
            notices.showNotice(notice.message, isWarning: notice.isWarning)
        }
    }

    /// Shows the keys if they're hidden, or hides them.
    func toggleShowing(announces: Bool = false) {
        setShowing(!isShowing, announces: announces)
    }

    /// What Show & Hide Keystrokes says: shown or hidden, or why shown keys can't appear.
    static func notice(showing: Bool, isListening: Bool, isSecureInputOn: Bool) -> (message: String, isWarning: Bool) {
        guard showing else { return ("Keystrokes hidden", false) }
        if !isListening { return ("Keystrokes can't show keys without Input Monitoring", true) }
        if isSecureInputOn { return ("Keystrokes can't show keys while secure input is on", true) }
        return ("Keystrokes shown", false)
    }

    /// Turning the plugin on shows the keys, even if they were hidden when it was turned off.
    func willTurnOn(_ context: CapabilityContext) {
        preferences.set(.bool(true), of: .keystrokesShowing, for: .keystrokes)
        display.showKeys()
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
        appliedShowing = nil
        display.release(.keystrokes)
        menuBar?.clear()
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    /// Holds the display while the plugin is on, its keys hidden while they are, and lists Show
    /// Keystrokes, checked while the keys show, in the menu bar menu. Showing or hiding acts on every
    /// holder's keys on screen when `actsOnScreen`, or when the preference changed since the last
    /// apply, as Settings' switch changes it.
    private func update(actsOnScreen: Bool = false) {
        guard isOn else {
            appliedShowing = nil
            display.release(.keystrokes)
            menuBar?.clear()
            return
        }
        let showing = isShowing
        if actsOnScreen || appliedShowing.map({ $0 != showing }) == true {
            if showing { display.showKeys() } else { display.hideKeys() }
        }
        appliedShowing = showing
        display.acquire(.keystrokes, configuration: preferences.keystrokesConfiguration, startsHidden: !showing)
        menuBar?.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "keystrokes.showing", title: "Show Keystrokes", systemImage: nil, isChecked: showing) { [weak self] in
                self?.toggleShowing()
            },
        ])
    }
}
