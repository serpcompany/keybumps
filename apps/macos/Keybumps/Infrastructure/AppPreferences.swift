import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        /// Retired: the old presentation-channel list. Removed on load.
        static let retiredSelectedChannels = "selectedNotificationChannels"
        static let showInDockAndSwitcher = "showInDockAndSwitcher"
        static let enabledCapabilities = "enabledCapabilities"
        static let knownCapabilities = "knownCapabilities"
        static let dictationLanguage = "dictationLanguage"
        static let dictationDurationLimit = "dictationDurationLimit"
        static let dictationTranscriptionEngine = "dictationTranscriptionEngine"
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let capabilityShortcuts = "capabilityShortcuts"
        static let knownCapabilityShortcuts = "knownCapabilityShortcuts"
        static let takenOverSystemShortcuts = "takenOverSystemShortcuts"
        static let windowShortcuts = "windowShortcuts"
        static let showsHotkeysTab = "showsHotkeysTab"
        static let didRequestScreenRecording = "didRequestScreenRecording"
        static let copiesScreenshotsToClipboard = "copiesScreenshotsToClipboard"
        static let expandsSnippetKeywords = "expandsSnippetKeywords"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let didFillSettingsWindow = "didFillSettingsWindow"
        static let sendsCrashReports = "sendsCrashReports"
    }

    private let defaults: UserDefaults
    /// Which plugins this Mac's macOS runs (#322).
    let compatibility: PluginCompatibility

    var showInDockAndSwitcher: Bool {
        didSet { defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher) }
    }

    /// The plugins that are on. A plugin this Mac's macOS can't run is never among them, even when
    /// saved on or set here (`PluginCompatibility`), so its module, tab, and shortcuts never run.
    var enabledCapabilities: Set<Capability> {
        get { storedEnabledCapabilities }
        set { storedEnabledCapabilities = newValue.filter(compatibility.supports) }
    }

    private var storedEnabledCapabilities: Set<Capability> {
        didSet { defaults.set(storedEnabledCapabilities.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities) }
    }

    var dictationLanguage: String {
        didSet { defaults.set(dictationLanguage, forKey: Key.dictationLanguage) }
    }

    var dictationDurationLimit: DictationDurationLimit {
        didSet { defaults.set(dictationDurationLimit.rawValue, forKey: Key.dictationDurationLimit) }
    }

    var dictationTranscriptionEngine: DictationTranscriptionEngine {
        didSet { defaults.set(dictationTranscriptionEngine.rawValue, forKey: Key.dictationTranscriptionEngine) }
    }

    var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Key.didCompleteOnboarding) }
    }

    /// Whether the Settings window has opened filling the screen once. After that, macOS keeps the
    /// size the person leaves it at.
    var didFillSettingsWindow: Bool {
        didSet { defaults.set(didFillSettingsWindow, forKey: Key.didFillSettingsWindow) }
    }

    private(set) var capabilityShortcuts: [String: ShortcutBinding] {
        didSet { persistCapabilityShortcuts() }
    }

    private(set) var windowShortcuts: [String: ShortcutBinding] {
        didSet { persistWindowShortcuts() }
    }

    /// Shortcuts Keybumps took off an action since launch, by the action that lost them, so its
    /// row can say where they went (#334). Not saved: after a restart the row is just empty.
    private(set) var movedShortcuts: [ShortcutOwner: ShortcutMove] = [:]

    /// macOS symbolic hotkey IDs Keybumps turned off for its screenshot hotkeys, to restore later.
    var takenOverSystemShortcuts: Set<String> {
        didSet { defaults.set(takenOverSystemShortcuts.sorted(), forKey: Key.takenOverSystemShortcuts) }
    }

    /// Whether the Command Palette shows Shortcut Coach's Hotkeys tab. Off by default.
    var showsHotkeysTab: Bool {
        didSet { defaults.set(showsHotkeysTab, forKey: Key.showsHotkeysTab) }
    }

    /// Whether a screenshot hotkey has already shown macOS's Screen Recording request, which
    /// opens System Settings on recent macOS and so must happen only once.
    var didRequestScreenRecording: Bool {
        didSet { defaults.set(didRequestScreenRecording, forKey: Key.didRequestScreenRecording) }
    }

    /// Whether each new screenshot also goes on the clipboard, ready to paste. On by default.
    var copiesScreenshotsToClipboard: Bool {
        didSet { defaults.set(copiesScreenshotsToClipboard, forKey: Key.copiesScreenshotsToClipboard) }
    }

    /// Whether typing a snippet's keyword in another app replaces it with the snippet (keyword
    /// auto-expansion, ADR 0004). Off by default.
    var expandsSnippetKeywords: Bool {
        didSet { defaults.set(expandsSnippetKeywords, forKey: Key.expandsSnippetKeywords) }
    }

    /// Whether crashes and freezes are reported to Keybumps's developers (ADR 0007). On by default.
    var sendsCrashReports: Bool {
        didSet { defaults.set(sendsCrashReports, forKey: Key.sendsCrashReports) }
    }

    /// The same setting, read at launch before anything else is set up.
    static func sendsCrashReports(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.sendsCrashReports) == nil || defaults.bool(forKey: Key.sendsCrashReports)
    }

    /// Plugins' declared preferences (`PluginPreference`) that were set, by storage key
    /// (`plugin.<capability>.<key>`). One never set reads as its default through `value(of:for:)`.
    private var pluginValues: [String: PluginPreference.Value] = [:]

    /// A plugin's declared preference: what was set, or its default.
    func value(of preference: PluginPreference, for capability: Capability) -> PluginPreference.Value {
        pluginValues[preference.storageKey(for: capability)] ?? preference.defaultValue
    }

    func bool(_ preference: PluginPreference, for capability: Capability) -> Bool {
        if case .bool(let value) = value(of: preference, for: capability) { return value }
        return false
    }

    /// A menu preference's chosen value, or "" for a switch.
    func choice(_ preference: PluginPreference, for capability: Capability) -> String {
        if case .choice(let value) = value(of: preference, for: capability) { return value }
        return ""
    }

    /// Sets a preference `capability` declares, to a value of its kind; anything else is ignored.
    /// Choosing the value of the menu it `differsFrom` swaps the two, so they never match.
    func set(_ value: PluginPreference.Value, of preference: PluginPreference, for capability: Capability) {
        let declared = capability.descriptor.preferences
        guard declared.contains(preference), preference.accepts(value) else { return }
        if let key = preference.differsFrom, let counterpart = declared.first(where: { $0.key == key }),
           self.value(of: counterpart, for: capability) == value {
            store(self.value(of: preference, for: capability), of: counterpart, for: capability)
        }
        store(value, of: preference, for: capability)
    }

    private func store(_ value: PluginPreference.Value, of preference: PluginPreference, for capability: Capability) {
        let key = preference.storageKey(for: capability)
        pluginValues[key] = value
        switch value {
        case .bool(let bool): defaults.set(bool, forKey: key)
        case .choice(let choice): defaults.set(choice, forKey: key)
        }
    }

    /// Reads every declared preference that was set, ignoring a stored value of the wrong kind.
    private func loadPluginValues() {
        for descriptor in CapabilityCatalog.descriptors {
            for preference in descriptor.preferences {
                let key = preference.storageKey(for: descriptor.capability)
                if let value = preference.value(fromStored: defaults.object(forKey: key)) {
                    pluginValues[key] = value
                }
            }
        }
    }

    /// The version that last launched, so What's New shows once after an update (#225).
    var lastLaunchedVersion: String? {
        didSet { defaults.set(lastLaunchedVersion, forKey: Key.lastLaunchedVersion) }
    }

    /// The plugins that start on: in a new install every one but those that ship off; in an existing
    /// install the ones it had on, plus any an update added since (not in `known`) that ship on.
    static func initialCapabilities(stored: [String]?, known: [String]?, shippingOff: Set<Capability>) -> Set<Capability> {
        guard let stored else { return Set(Capability.allCases).subtracting(shippingOff) }
        let knownSet = known.map { Set($0.compactMap(Capability.init(rawValue:))) } ?? Capability.originalCapabilities
        let introduced = Set(Capability.allCases).subtracting(knownSet).subtracting(shippingOff)
        return Set(stored.compactMap(Capability.init(rawValue:))).union(introduced)
    }

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: [UserDefaults] = [],
        compatibility: PluginCompatibility = .current
    ) {
        self.defaults = defaults
        self.compatibility = compatibility
        let stored = defaults.array(forKey: Key.enabledCapabilities) as? [String]
        let initial = Self.initialCapabilities(
            stored: stored,
            known: defaults.array(forKey: Key.knownCapabilities) as? [String],
            shippingOff: Set(CapabilityCatalog.descriptors.filter { !$0.isOnByDefault }.map(\.capability))
        ).filter(compatibility.supports)
        storedEnabledCapabilities = initial
        if stored != nil {
            defaults.set(initial.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities)
        }
        defaults.set(Capability.allCases.map(\.rawValue).sorted(), forKey: Key.knownCapabilities)
        dictationLanguage = defaults.string(forKey: Key.dictationLanguage) ?? "en-US"
        if defaults.object(forKey: Key.dictationDurationLimit) != nil,
           let storedLimit = DictationDurationLimit(rawValue: defaults.integer(forKey: Key.dictationDurationLimit)) {
            dictationDurationLimit = storedLimit
        } else {
            dictationDurationLimit = .fiveMinutes
        }
        dictationTranscriptionEngine = defaults.string(forKey: Key.dictationTranscriptionEngine)
            .flatMap(DictationTranscriptionEngine.init(rawValue:))
            ?? .appleSpeech
        didCompleteOnboarding = defaults.bool(forKey: Key.didCompleteOnboarding)
        didFillSettingsWindow = defaults.bool(forKey: Key.didFillSettingsWindow)
        takenOverSystemShortcuts = Set(defaults.stringArray(forKey: Key.takenOverSystemShortcuts) ?? [])
        showsHotkeysTab = defaults.bool(forKey: Key.showsHotkeysTab)
        didRequestScreenRecording = defaults.bool(forKey: Key.didRequestScreenRecording)
        copiesScreenshotsToClipboard = defaults.object(forKey: Key.copiesScreenshotsToClipboard) == nil
            || defaults.bool(forKey: Key.copiesScreenshotsToClipboard)
        expandsSnippetKeywords = defaults.bool(forKey: Key.expandsSnippetKeywords)
        sendsCrashReports = Self.sendsCrashReports(in: defaults)
        lastLaunchedVersion = defaults.string(forKey: Key.lastLaunchedVersion)
        var introducedShortcuts = false
        if let data = defaults.data(forKey: Key.capabilityShortcuts),
           var decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            // A shortcut introduced after this install gets its default once, unless those keys
            // are already taken; the owner's later choices (including clearing it) are kept.
            let known = (defaults.array(forKey: Key.knownCapabilityShortcuts) as? [String])
                .map { Set($0.compactMap(CapabilityShortcut.init(rawValue:))) } ?? CapabilityShortcut.originalShortcuts
            for shortcut in CapabilityShortcut.allCases where !known.contains(shortcut) {
                guard let binding = shortcut.defaultBinding,
                      !decoded.values.contains(where: { $0.usesSameKeys(as: binding) }) else { continue }
                decoded[shortcut.rawValue] = binding
                introducedShortcuts = true
            }
            capabilityShortcuts = decoded
        } else {
            capabilityShortcuts = Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.compactMap { shortcut in
                shortcut.defaultBinding.map { (shortcut.rawValue, $0) }
            })
        }
        defaults.set(CapabilityShortcut.allCases.map(\.rawValue).sorted(), forKey: Key.knownCapabilityShortcuts)
        if let data = defaults.data(forKey: Key.windowShortcuts),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            windowShortcuts = decoded
        } else {
            windowShortcuts = Dictionary(uniqueKeysWithValues: WindowAction.allCases.compactMap { action in
                action.defaultShortcut.map { (action.rawValue, $0) }
            })
        }
        if defaults.object(forKey: Key.showInDockAndSwitcher) != nil {
            showInDockAndSwitcher = defaults.bool(forKey: Key.showInDockAndSwitcher)
        } else if let legacyPresenceDefaults = legacyDefaults.first(where: {
            $0.object(forKey: Key.showInDockAndSwitcher) != nil
        }) {
            showInDockAndSwitcher = legacyPresenceDefaults.bool(forKey: Key.showInDockAndSwitcher)
        } else {
            showInDockAndSwitcher = true
        }

        defaults.removeObject(forKey: Key.retiredSelectedChannels)
        if introducedShortcuts {
            persistCapabilityShortcuts()
        }
        if defaults.object(forKey: Key.showInDockAndSwitcher) == nil,
           legacyDefaults.contains(where: { $0.object(forKey: Key.showInDockAndSwitcher) != nil }) {
            defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher)
        }
        normalizeShortcutConflictsFavoringExistingWindowBindings()
        loadPluginValues()
    }

    /// Turns a plugin on or off. One this Mac's macOS can't run stays off.
    func setCapability(_ capability: Capability, enabled: Bool) {
        if enabled { enabledCapabilities.insert(capability) }
        else { enabledCapabilities.remove(capability) }
    }

    func windowShortcut(for action: WindowAction) -> ShortcutBinding? {
        windowShortcuts[action.rawValue]
    }

    func capabilityShortcut(for shortcut: CapabilityShortcut) -> ShortcutBinding? {
        capabilityShortcuts[shortcut.rawValue]
    }

    func shortcut(for owner: ShortcutOwner) -> ShortcutBinding? {
        switch owner {
        case .capability(let shortcut): capabilityShortcut(for: shortcut)
        case .window(let action): windowShortcut(for: action)
        }
    }

    /// The other action already using `binding`'s keys, which setting it for `owner` would take
    /// them from (#334).
    func shortcutConflict(for binding: ShortcutBinding, assigningTo owner: ShortcutOwner) -> ShortcutOwner? {
        ShortcutConflict.find(binding, for: owner, capabilityShortcuts: capabilityShortcuts, windowShortcuts: windowShortcuts)
    }

    /// Sets an action's shortcut. Another action using the same keys loses them, and its row says
    /// where they went (`movedShortcuts`). Returns the actions that lost them.
    @discardableResult
    func setShortcut(_ binding: ShortcutBinding?, for owner: ShortcutOwner) -> [ShortcutOwner] {
        var moved: [ShortcutOwner] = []
        if let binding {
            while let other = shortcutConflict(for: binding, assigningTo: owner) {
                clear(other, movingTo: owner)
                moved.append(other)
            }
        }
        store(binding, for: owner)
        movedShortcuts[owner] = nil
        return moved
    }

    @discardableResult
    func setCapabilityShortcut(_ binding: ShortcutBinding?, for shortcut: CapabilityShortcut) -> [ShortcutOwner] {
        setShortcut(binding, for: .capability(shortcut))
    }

    func restoreDefaultCapabilityShortcut(_ shortcut: CapabilityShortcut) {
        setCapabilityShortcut(shortcut.defaultBinding, for: shortcut)
    }

    @discardableResult
    func setWindowShortcut(_ binding: ShortcutBinding?, for action: WindowAction) -> [ShortcutOwner] {
        setShortcut(binding, for: .window(action))
    }

    /// Resets every window shortcut. A plugin shortcut using a window default's keys loses them,
    /// and its row says so; returns the plugin shortcuts that lost them.
    @discardableResult
    func restoreDefaultWindowShortcuts() -> [ShortcutOwner] {
        var moved: [ShortcutOwner] = []
        for shortcut in CapabilityShortcut.allCases {
            guard let existing = capabilityShortcuts[shortcut.rawValue],
                  let action = WindowAction.allCases.first(where: { $0.defaultShortcut?.usesSameKeys(as: existing) == true })
            else { continue }
            clear(.capability(shortcut), movingTo: .window(action))
            moved.append(.capability(shortcut))
        }
        windowShortcuts = Dictionary(uniqueKeysWithValues: WindowAction.allCases.compactMap { action in
            action.defaultShortcut.map { (action.rawValue, $0) }
        })
        for action in WindowAction.allCases {
            movedShortcuts[.window(action)] = nil
        }
        return moved
    }

    /// Where `owner`'s shortcut went, while the action it went to still has those keys; after
    /// that, the note would point the wrong way.
    func movedShortcut(for owner: ShortcutOwner) -> ShortcutMove? {
        guard let move = movedShortcuts[owner], shortcut(for: move.to)?.usesSameKeys(as: move.binding) == true else { return nil }
        return move
    }

    /// Takes `owner`'s shortcut away because `destination` now has its keys, noting where it went.
    private func clear(_ owner: ShortcutOwner, movingTo destination: ShortcutOwner) {
        if let binding = shortcut(for: owner) {
            movedShortcuts[owner] = ShortcutMove(binding: binding, to: destination)
        }
        store(nil, for: owner)
    }

    private func store(_ binding: ShortcutBinding?, for owner: ShortcutOwner) {
        switch owner {
        case .capability(let shortcut): capabilityShortcuts[shortcut.rawValue] = binding
        case .window(let action): windowShortcuts[action.rawValue] = binding
        }
    }

    private func persistWindowShortcuts() {
        guard let data = try? JSONEncoder().encode(windowShortcuts) else { return }
        defaults.set(data, forKey: Key.windowShortcuts)
    }

    private func persistCapabilityShortcuts() {
        guard let data = try? JSONEncoder().encode(capabilityShortcuts) else { return }
        defaults.set(data, forKey: Key.capabilityShortcuts)
    }

    private func normalizeShortcutConflictsFavoringExistingWindowBindings() {
        for action in WindowAction.allCases {
            guard let windowBinding = windowShortcuts[action.rawValue] else { continue }
            for shortcut in CapabilityShortcut.allCases
                where capabilityShortcuts[shortcut.rawValue]?.usesSameKeys(as: windowBinding) == true {
                clear(.capability(shortcut), movingTo: .window(action))
            }
        }
    }
}
