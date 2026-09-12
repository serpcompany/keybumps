import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let selectedChannels = "selectedNotificationChannels"
        static let showInDockAndSwitcher = "showInDockAndSwitcher"
        static let enabledCapabilities = "enabledCapabilities"
        static let dictationLanguage = "dictationLanguage"
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let capabilityShortcuts = "capabilityShortcuts"
        static let windowShortcuts = "windowShortcuts"
    }

    private let defaults: UserDefaults

    var selectedChannels: Set<NotificationChannel> {
        didSet { persistChannels() }
    }

    var showInDockAndSwitcher: Bool {
        didSet { defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher) }
    }

    var enabledCapabilities: Set<Capability> {
        didSet { defaults.set(enabledCapabilities.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities) }
    }

    var dictationLanguage: String {
        didSet { defaults.set(dictationLanguage, forKey: Key.dictationLanguage) }
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

    init(defaults: UserDefaults = .standard, legacyDefaults: [UserDefaults] = []) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Key.enabledCapabilities) as? [String] {
            enabledCapabilities = Set(raw.compactMap(Capability.init(rawValue:)))
        } else {
            enabledCapabilities = Set(Capability.allCases)
        }
        dictationLanguage = defaults.string(forKey: Key.dictationLanguage) ?? "en-US"
        didCompleteOnboarding = defaults.bool(forKey: Key.didCompleteOnboarding)
        if let data = defaults.data(forKey: Key.capabilityShortcuts),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            capabilityShortcuts = decoded
        } else {
            capabilityShortcuts = Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.map {
                ($0.rawValue, $0.defaultBinding)
            })
        }
        if let data = defaults.data(forKey: Key.windowShortcuts),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            windowShortcuts = decoded
        } else {
            windowShortcuts = Dictionary(uniqueKeysWithValues: SuperMacWindowAction.allCases.compactMap { action in
                action.defaultShortcut.map { (action.rawValue, $0) }
            })
        }
        let currentChannels = defaults.array(forKey: Key.selectedChannels) as? [String]
        let legacyChannels = legacyDefaults.lazy.compactMap {
            $0.array(forKey: Key.selectedChannels) as? [String]
        }.first
        let channelsWereNormalized: Bool
        if let rawChannels = currentChannels ?? legacyChannels {
            let decodedChannels = Set(rawChannels.compactMap(NotificationChannel.init(rawValue:)))
            let normalizedChannels = PresentationOverlapPolicy.normalized(decodedChannels)
            selectedChannels = normalizedChannels
            channelsWereNormalized = normalizedChannels != decodedChannels
        } else {
            selectedChannels = [.topRightToast, .dockBadge]
            channelsWereNormalized = false
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

        if (currentChannels == nil && legacyChannels != nil) || channelsWereNormalized {
            persistChannels()
        }
        if defaults.object(forKey: Key.showInDockAndSwitcher) == nil,
           legacyDefaults.contains(where: { $0.object(forKey: Key.showInDockAndSwitcher) != nil }) {
            defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher)
        }
        normalizeShortcutConflictsFavoringExistingWindowBindings()
    }

    func set(_ channel: NotificationChannel, enabled: Bool) {
        if enabled {
            selectedChannels = PresentationOverlapPolicy.selecting(channel, in: selectedChannels)
        } else {
            selectedChannels.remove(channel)
        }
    }

    func setCapability(_ capability: Capability, enabled: Bool) {
        if enabled { enabledCapabilities.insert(capability) }
        else { enabledCapabilities.remove(capability) }
    }

    func windowShortcut(for action: SuperMacWindowAction) -> ShortcutBinding? {
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

    func setWindowShortcut(_ binding: ShortcutBinding?, for action: SuperMacWindowAction) {
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
        let defaults = Dictionary(uniqueKeysWithValues: SuperMacWindowAction.allCases.compactMap { action in
            action.defaultShortcut.map { (action.rawValue, $0) }
        })
        for (key, existing) in capabilityShortcuts where defaults.values.contains(where: { $0.usesSameKeys(as: existing) }) {
            capabilityShortcuts[key] = nil
        }
        windowShortcuts = defaults
    }

    private func persistChannels() {
        defaults.set(selectedChannels.map(\.rawValue).sorted(), forKey: Key.selectedChannels)
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
