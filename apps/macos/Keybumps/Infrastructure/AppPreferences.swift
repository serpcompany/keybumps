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
    }

    private let defaults: UserDefaults

    var showInDockAndSwitcher: Bool {
        didSet { defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher) }
    }

    var enabledCapabilities: Set<Capability> {
        didSet { defaults.set(enabledCapabilities.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities) }
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

    private(set) var capabilityShortcuts: [String: ShortcutBinding] {
        didSet { persistCapabilityShortcuts() }
    }

    private(set) var windowShortcuts: [String: ShortcutBinding] {
        didSet { persistWindowShortcuts() }
    }

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

    init(defaults: UserDefaults = .standard, legacyDefaults: [UserDefaults] = []) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Key.enabledCapabilities) as? [String] {
            let known = (defaults.array(forKey: Key.knownCapabilities) as? [String])
                .map { Set($0.compactMap(Capability.init(rawValue:))) } ?? Capability.originalCapabilities
            let introduced = Set(Capability.allCases).subtracting(known)
            let migrated = Set(raw.compactMap(Capability.init(rawValue:))).union(introduced)
            enabledCapabilities = migrated
            defaults.set(migrated.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities)
        } else {
            enabledCapabilities = Set(Capability.allCases)
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
        takenOverSystemShortcuts = Set(defaults.stringArray(forKey: Key.takenOverSystemShortcuts) ?? [])
        showsHotkeysTab = defaults.bool(forKey: Key.showsHotkeysTab)
        didRequestScreenRecording = defaults.bool(forKey: Key.didRequestScreenRecording)
        copiesScreenshotsToClipboard = defaults.object(forKey: Key.copiesScreenshotsToClipboard) == nil
            || defaults.bool(forKey: Key.copiesScreenshotsToClipboard)
        var introducedShortcuts = false
        if let data = defaults.data(forKey: Key.capabilityShortcuts),
           var decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            // A shortcut introduced after this install gets its default once, unless those keys
            // are already taken; the owner's later choices (including clearing it) are kept.
            let known = (defaults.array(forKey: Key.knownCapabilityShortcuts) as? [String])
                .map { Set($0.compactMap(CapabilityShortcut.init(rawValue:))) } ?? CapabilityShortcut.originalShortcuts
            for shortcut in CapabilityShortcut.allCases where !known.contains(shortcut)
                && !decoded.values.contains(where: { $0.usesSameKeys(as: shortcut.defaultBinding) }) {
                decoded[shortcut.rawValue] = shortcut.defaultBinding
                introducedShortcuts = true
            }
            capabilityShortcuts = decoded
        } else {
            capabilityShortcuts = Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.map {
                ($0.rawValue, $0.defaultBinding)
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
    }

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

    func setCapabilityShortcut(_ binding: ShortcutBinding?, for shortcut: CapabilityShortcut) {
        if let binding {
            for (key, existing) in capabilityShortcuts
                where existing.usesSameKeys(as: binding) && key != shortcut.rawValue {
                capabilityShortcuts[key] = nil
            }
            for (key, existing) in windowShortcuts where existing.usesSameKeys(as: binding) {
                windowShortcuts[key] = nil
            }
            capabilityShortcuts[shortcut.rawValue] = binding
        } else {
            capabilityShortcuts[shortcut.rawValue] = nil
        }
    }

    func restoreDefaultCapabilityShortcut(_ shortcut: CapabilityShortcut) {
        setCapabilityShortcut(shortcut.defaultBinding, for: shortcut)
    }

    func setWindowShortcut(_ binding: ShortcutBinding?, for action: WindowAction) {
        if let binding {
            for (key, existing) in windowShortcuts
                where existing.usesSameKeys(as: binding) && key != action.rawValue {
                windowShortcuts[key] = nil
            }
            for (key, existing) in capabilityShortcuts where existing.usesSameKeys(as: binding) {
                capabilityShortcuts[key] = nil
            }
            windowShortcuts[action.rawValue] = binding
        } else {
            windowShortcuts[action.rawValue] = nil
        }
    }

    func restoreDefaultWindowShortcuts() {
        let defaults = Dictionary(uniqueKeysWithValues: WindowAction.allCases.compactMap { action in
            action.defaultShortcut.map { (action.rawValue, $0) }
        })
        for (key, existing) in capabilityShortcuts where defaults.values.contains(where: { $0.usesSameKeys(as: existing) }) {
            capabilityShortcuts[key] = nil
        }
        windowShortcuts = defaults
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
        for windowBinding in windowShortcuts.values {
            for (key, capabilityBinding) in capabilityShortcuts
                where capabilityBinding.usesSameKeys(as: windowBinding) {
                capabilityShortcuts[key] = nil
            }
        }
    }
}
