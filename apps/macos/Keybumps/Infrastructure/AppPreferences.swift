import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        /// Retired: the old presentation-channel list. Removed on load.
        static let retiredSelectedChannels = "selectedNotificationChannels"
        /// Retired: Screencast's "Also add to Screenshots (⌘3)", which only QA builds had (#464,
        /// #485). Removed on load.
        static let retiredScreencastAddsToScreenshots = "plugin.screencast.addsToScreenshots"
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
        /// Whether Quick Search shows the Hotkeys tab, which is hidden unless this is true. It
        /// keeps the key it had before #553 put every tab's show switch on Settings › Quick Search.
        static let showsHotkeysTab = "showsHotkeysTab"
        /// The other tabs hidden in Settings › Quick Search, by `CommandPaletteTab` raw value (#553).
        static let quickSearchHiddenTabs = "quickSearchHiddenTabs"
        /// The tab order set in Settings › Quick Search, by `CommandPaletteTab` raw value (#553).
        /// Absent while the tabs are in the default order.
        static let quickSearchTabOrder = "quickSearchTabOrder"
        /// Whether the one-time step that hides the Search tab where Quick Search was off has run
        /// (#553): Quick Search can't be turned off any more, and hiding its tab replaced that.
        static let didMoveQuickSearchSwitchToSearchTab = "didMoveQuickSearchSwitchToSearchTab"
        /// Whether the next launch turns Spotlight's ⌘Space off, once, for an install that had
        /// Quick Search off before #553 (owner's decision on #553).
        static let takesCommandSpaceFromSpotlightOnLaunch = "takesCommandSpaceFromSpotlightOnLaunch"
        static let foldsSettingsSidebarPlugins = "foldsSettingsSidebarPlugins"
        static let didRequestScreenRecording = "didRequestScreenRecording"
        static let copiesScreenshotsToClipboard = "copiesScreenshotsToClipboard"
        static let expandsSnippetKeywords = "expandsSnippetKeywords"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let lastUpdateYearDay = "lastUpdateYearDay"
        static let didFillSettingsWindow = "didFillSettingsWindow"
        static let sendsCrashReports = "sendsCrashReports"
        /// Whether the one-time step that gives Record Screen ⇧⌘5 has run (#513). It replaced #490's
        /// `didOfferRecordScreenShortcut`, so it runs once more on every install that step marked
        /// done, replacing a Record Screen shortcut cleared or changed after it, unless another
        /// Keybumps shortcut (a plugin's or a window's) holds ⇧⌘5; the old key is left in place, unread.
        static let didGiveRecordScreenShortcut = "didGiveRecordScreenShortcut"

        /// A save folder chosen in Settings › ScreenGrabs (#504), as its path:
        /// `screengrabs.screenshotsFolder` or `screengrabs.recordingsFolder`.
        static func chosenFolder(_ kind: ScreengrabFolders.Kind) -> String {
            "screengrabs.\(kind.rawValue)Folder"
        }
    }

    private let defaults: UserDefaults
    /// Which plugins this Mac's macOS runs (#322).
    let compatibility: PluginCompatibility
    /// The folder macOS saves screenshots to, which ScreenGrabs' save folders default to: macOS's own
    /// (`ScreenshotLocationResolver.system`, which reads none under the unit-test host), or the
    /// UI-test sandbox's.
    let screenshotLocation: ScreenshotLocationResolver

    var showInDockAndSwitcher: Bool {
        didSet { defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher) }
    }

    /// The plugins that are on. A plugin this Mac's macOS can't run is never among them, even when
    /// saved on or set here (`PluginCompatibility`), so its module, tab, and shortcuts never run.
    /// One that's always on, Quick Search (`CapabilityDescriptor.isAlwaysOn`, #553), is always among
    /// them, even when saved off or left out here.
    var enabledCapabilities: Set<Capability> {
        get { storedEnabledCapabilities }
        set { storedEnabledCapabilities = newValue.union(CapabilityCatalog.alwaysOnCapabilities).filter(compatibility.supports) }
    }

    private var storedEnabledCapabilities: Set<Capability> {
        didSet { defaults.set(storedEnabledCapabilities.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities) }
    }

    /// A locale identifier such as `en-US`, or Automatic (`DictationLanguage`), the default.
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

    /// macOS symbolic hotkey IDs Keybumps turned off for ScreenGrabs' shortcuts, to restore later.
    var takenOverSystemShortcuts: Set<String> {
        didSet { defaults.set(takenOverSystemShortcuts.sorted(), forKey: Key.takenOverSystemShortcuts) }
    }

    /// The Quick Search tabs hidden by their show switches in Settings › Quick Search (#553). The
    /// Hotkeys tab starts hidden, and the Search tab starts shown, except where Quick Search was
    /// off before it could no longer be turned off. `CommandPaletteTab.shownTabs` always keeps one
    /// tab shown, whatever is hidden here.
    private(set) var hiddenTabs: Set<CommandPaletteTab> {
        didSet { persistHiddenTabs() }
    }

    /// Whether `tab`'s show switch in Settings › Quick Search is on.
    func showsTab(_ tab: CommandPaletteTab) -> Bool {
        !hiddenTabs.contains(tab)
    }

    /// Turns `tab`'s show switch in Settings › Quick Search on or off.
    func setShowsTab(_ tab: CommandPaletteTab, _ shows: Bool) {
        if shows { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
    }

    private func persistHiddenTabs() {
        defaults.set(!hiddenTabs.contains(.keyboardShortcutter), forKey: Key.showsHotkeysTab)
        defaults.set(hiddenTabs.subtracting([.keyboardShortcutter]).map(\.rawValue).sorted(), forKey: Key.quickSearchHiddenTabs)
    }

    /// Every Quick Search tab, in the order Settings › Quick Search lists them, which the tab bar,
    /// the tab keys, and Left and Right follow (#553): the saved order, then any tab it leaves
    /// out, such as one a later version adds, in the default order (`CommandPaletteTab.ordered`).
    /// Nothing is saved while it's the default order, so a later default reaches anyone who never
    /// reordered. Which tabs show is `hiddenTabs`, apart from this.
    private(set) var tabOrder: [CommandPaletteTab] {
        didSet { persistTabOrder() }
    }

    /// Whether the tabs are in the default order, where Reset Order has nothing to do.
    var isDefaultTabOrder: Bool { tabOrder == CommandPaletteTab.defaultOrder }

    /// Moves `tab` `offset` places in the order, stopping at either end, as Settings › Quick
    /// Search's move buttons do.
    func moveTab(_ tab: CommandPaletteTab, by offset: Int) {
        guard let index = tabOrder.firstIndex(of: tab) else { return }
        let place = min(max(index + offset, 0), tabOrder.count - 1)
        moveTabs(fromOffsets: [index], toOffset: place > index ? place + 1 : place)
    }

    /// Moves the tabs at `offsets` in the order to just before the tab at `destination`, as
    /// Settings › Quick Search's list reports a dragged row (`ForEach.onMove`). Both count places
    /// in the order before the move, so `destination` is `tabOrder.count` for the end. Offsets
    /// outside the order move nothing.
    func moveTabs(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy(tabOrder.indices.contains),
              (0...tabOrder.count).contains(destination) else { return }
        let moving = offsets.map { tabOrder[$0] }
        var order = tabOrder.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        order.insert(contentsOf: moving, at: destination - offsets.count(in: 0..<destination))
        if order != tabOrder { tabOrder = order }
    }

    /// Puts the tabs back in the default order. Which tabs show stays as it is.
    func resetTabOrder() {
        tabOrder = CommandPaletteTab.defaultOrder
    }

    private func persistTabOrder() {
        if isDefaultTabOrder {
            defaults.removeObject(forKey: Key.quickSearchTabOrder)
        } else {
            defaults.set(tabOrder.map(\.rawValue), forKey: Key.quickSearchTabOrder)
        }
    }

    /// Whether the next launch turns Spotlight's ⌘Space off, once, as first-time setup does: set by
    /// the step below for an install that had Quick Search off, which never went through setup
    /// with it on, and cleared by `AppModel` when it runs (owner's decision on #553).
    var takesCommandSpaceFromSpotlightOnLaunch: Bool {
        didSet { defaults.set(takesCommandSpaceFromSpotlightOnLaunch, forKey: Key.takesCommandSpaceFromSpotlightOnLaunch) }
    }

    /// The tabs saved hidden, with the Search tab hidden once where Quick Search was saved off
    /// (#553). Quick Search could be turned off until it became the window's page, which can't
    /// be; hiding the Search tab took the switch's place, so an install that had it off starts
    /// with the tab hidden instead. Open Quick Search's shortcut stays as it was, ⌘Space or the key
    /// saved, and the next launch takes ⌘Space from Spotlight once (owner's decisions on #553). A
    /// new install, which saved no plugins, and one with Quick Search on show the tab. It runs
    /// once, whatever it found, so a Search tab shown after it stays shown, and `init` runs it
    /// before it saves Quick Search on.
    private static func loadHiddenTabs(in defaults: UserDefaults, storedCapabilities: [String]?) -> Set<CommandPaletteTab> {
        var hidden = Set((defaults.stringArray(forKey: Key.quickSearchHiddenTabs) ?? []).compactMap(CommandPaletteTab.init(rawValue:)))
            .subtracting([.keyboardShortcutter])
        if !defaults.bool(forKey: Key.showsHotkeysTab) { hidden.insert(.keyboardShortcutter) }
        guard !defaults.bool(forKey: Key.didMoveQuickSearchSwitchToSearchTab) else { return hidden }
        if let storedCapabilities, !storedCapabilities.contains(Capability.quickSearch.rawValue) {
            hidden.insert(.search)
            defaults.set(hidden.subtracting([.keyboardShortcutter]).map(\.rawValue).sorted(), forKey: Key.quickSearchHiddenTabs)
            defaults.set(true, forKey: Key.takesCommandSpaceFromSpotlightOnLaunch)
        }
        // Written last, so a launch cut short before the tab is saved hidden does it again.
        defaults.set(true, forKey: Key.didMoveQuickSearchSwitchToSearchTab)
        return hidden
    }

    /// Whether the Settings sidebar's Plugins section is folded (#559). Unfolded by default.
    var foldsSettingsSidebarPlugins: Bool {
        didSet { defaults.set(foldsSettingsSidebarPlugins, forKey: Key.foldsSettingsSidebarPlugins) }
    }

    /// Whether a screenshot hotkey has already shown macOS's Screen Recording request, which
    /// opens System Settings on recent macOS and so must happen only once.
    var didRequestScreenRecording: Bool {
        didSet { defaults.set(didRequestScreenRecording, forKey: Key.didRequestScreenRecording) }
    }

    /// The save folders chosen in Settings › ScreenGrabs (#504), by kind. A kind with none follows
    /// macOS's screenshot folder (`screengrabFolders`).
    private(set) var chosenScreengrabFolders: [ScreengrabFolders.Kind: URL]

    /// The paths of the folders chosen in Settings › ScreenGrabs, read straight from `defaults` before
    /// any preferences load: the launch's move into the Keybumps folder never moves one (ADR 0013).
    nonisolated static func chosenScreengrabFolderPaths(in defaults: UserDefaults) -> [String] {
        ScreengrabFolders.Kind.allCases.compactMap { defaults.string(forKey: Key.chosenFolder($0)) }.filter { $0.hasPrefix("/") }
    }

    /// Whether an earlier build ran on this Mac, read straight from `defaults` before any preferences
    /// load (ADR 0013). Every release sets `didCompleteOnboarding` once setup is done, and no plugin
    /// that keeps files runs before it; every release since #226 sets `lastLaunchedVersion` at launch.
    nonisolated static func ranBefore(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Key.didCompleteOnboarding) || defaults.string(forKey: Key.lastLaunchedVersion) != nil
    }

    /// ScreenGrabs' Screenshots and Recordings folders as they are now.
    var screengrabFolders: ScreengrabFolders {
        ScreengrabFolders(location: screenshotLocation, chosen: chosenScreengrabFolders)
    }

    /// Stores the folder chosen for `kind`; nil goes back to following macOS's screenshot folder.
    func chooseScreengrabFolder(_ folder: URL?, for kind: ScreengrabFolders.Kind) {
        let folder = folder.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        chosenScreengrabFolders[kind] = folder
        if let folder {
            defaults.set(folder.path, forKey: Key.chosenFolder(kind))
        } else {
            defaults.removeObject(forKey: Key.chosenFolder(kind))
        }
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

    /// The last day of the last update year this Mac learned (ADR 0011). The updater keeps filtering
    /// by it while no license is active, so a deactivated Mac never installs a release its license
    /// didn't cover and then finds it Locked when activated again.
    var lastUpdateYearDay: Date? {
        didSet { if lastUpdateYearDay != oldValue { defaults.set(lastUpdateYearDay, forKey: Key.lastUpdateYearDay) } }
    }

    /// The plugins that start on: in a new install every one but those that ship off; in an existing
    /// install the ones it had on, plus any an update added since (not in `known`) that ship on.
    static func initialCapabilities(stored: [String]?, known: [String]?, shippingOff: Set<Capability>) -> Set<Capability> {
        guard let stored else { return Set(Capability.allCases).subtracting(shippingOff) }
        let knownSet = known.map { Set($0.compactMap(Capability.init(rawValue:))) } ?? Capability.originalCapabilities
        let introduced = Set(Capability.allCases).subtracting(knownSet).subtracting(shippingOff)
        return Set(stored.compactMap(Capability.init(rawValue:))).union(introduced)
    }

    /// Every plugin shortcut's default, by ID, as a new install starts.
    private static var defaultCapabilityShortcuts: [String: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: CapabilityShortcut.allCases.compactMap { shortcut in
            shortcut.defaultBinding.map { (shortcut.rawValue, $0) }
        })
    }

    /// Folds what an install saved for Screencast into Screenshot Tools, which became ScreenGrabs
    /// and keeps its ID (ADR 0010, #489). It runs on an install whose saved `knownCapabilities` holds
    /// `screencast`, and rewrites saved values before `init` reads them, since `init` drops an ID
    /// `Capability` no longer has. That makes it run once: `init` then saves `knownCapabilities`
    /// without `screencast`. A build rolled back to puts `screencast` back, so after a return it runs
    /// again, from what the person last saved; doing so is safe, since a row already done changes
    /// nothing and the moved usage is gone from its old key. `init` calls it first.
    /// - Screenshot Tools on: left on, whatever Screencast was.
    /// - Screenshot Tools off and Screencast on: Screenshot Tools turns on. Each screenshot shortcut
    ///   still on its default key (⇧⌘2, ⇧⌘3, ⇧⌘4) is unassigned and a custom one is kept, so nothing
    ///   new answers ⇧⌘2 and macOS keeps ⇧⌘3 and ⇧⌘4; and new screenshots stop going on the clipboard.
    /// - Both off: left off.
    ///
    /// Quick Search's learned usage of the Screencast command is added to Screenshot Tools'. All else
    /// Screencast saved keeps its key: its declared preferences (`plugin.screencast.*`, which #490
    /// reads there), its shortcuts, and the picker's, control bar's, and drawing's memories. `init`
    /// removes the retired `plugin.screencast.addsToScreenshots`.
    static func foldScreencastIntoScreengrabs(
        in defaults: UserDefaults,
        applicationUsage: URL = ApplicationUsageStore.defaultStorageURL()
    ) {
        let screencast = "screencast"
        let screenshotTools = Capability.screenshotTools.rawValue
        guard (defaults.array(forKey: Key.knownCapabilities) as? [String])?.contains(screencast) == true else { return }
        ApplicationUsageStore.moveUsage(from: "command:\(screencast)", to: "command:\(screenshotTools)", at: applicationUsage)
        // A saved list that's missing means every plugin is as it ships: ScreenGrabs on.
        if var enabled = defaults.array(forKey: Key.enabledCapabilities) as? [String],
           enabled.contains(screencast), !enabled.contains(screenshotTools) {
            var shortcuts = defaults.data(forKey: Key.capabilityShortcuts)
                .flatMap { try? JSONDecoder().decode([String: ShortcutBinding].self, from: $0) }
                ?? defaultCapabilityShortcuts
            for shortcut in [CapabilityShortcut.screenshotScreen, .screenshotScreenAndEdit, .screenshotAreaAndEdit] {
                guard let binding = shortcut.defaultBinding,
                      shortcuts[shortcut.rawValue]?.usesSameKeys(as: binding) == true else { continue }
                shortcuts[shortcut.rawValue] = nil
            }
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: Key.capabilityShortcuts)
            }
            defaults.set(false, forKey: Key.copiesScreenshotsToClipboard)
            // Written last, so a launch cut short before this line does the whole row again.
            enabled.append(screenshotTools)
            defaults.set(enabled.sorted(), forKey: Key.enabledCapabilities)
        }
    }

    /// Gives Record Screen (`CapabilityShortcut.screencast`) its default, ⇧⌘5, once, unless another
    /// Keybumps shortcut, a plugin's or a window's, uses those keys (ADR 0010, #490, #513). A
    /// shortcut Record Screen already had is replaced: the owner wants ⇧⌘5 to be Record Screen's.
    /// A new install, or an update that didn't know the shortcut, already has its default (`init`);
    /// this catches the development and QA builds since #458, which listed it with no default or
    /// a shortcut set while testing. It also runs once on every install #490's step marked done,
    /// so a Record Screen shortcut cleared or changed after that step is replaced. Recorded once it
    /// runs, whatever it did, so a shortcut the person changes or clears after this step stays as
    /// they left it.
    private func giveRecordScreenShortcutOnce() {
        guard !defaults.bool(forKey: Key.didGiveRecordScreenShortcut) else { return }
        defaults.set(true, forKey: Key.didGiveRecordScreenShortcut)
        let recordScreen = CapabilityShortcut.screencast.rawValue
        guard let binding = CapabilityShortcut.screencast.defaultBinding,
              capabilityShortcuts[recordScreen]?.usesSameKeys(as: binding) != true,
              !capabilityShortcuts.contains(where: { $0.key != recordScreen && $0.value.usesSameKeys(as: binding) }),
              !windowShortcuts.values.contains(where: { $0.usesSameKeys(as: binding) })
        else { return }
        capabilityShortcuts[recordScreen] = binding
        persistCapabilityShortcuts()
    }

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: [UserDefaults] = [],
        compatibility: PluginCompatibility = .current,
        screenshotLocation: ScreenshotLocationResolver = .system
    ) {
        self.defaults = defaults
        self.compatibility = compatibility
        self.screenshotLocation = screenshotLocation
        // Before anything is read: it rewrites what Screencast saved, whose ID `Capability` no longer has.
        Self.foldScreencastIntoScreengrabs(in: defaults)
        let stored = defaults.array(forKey: Key.enabledCapabilities) as? [String]
        // Before Quick Search is saved on below: where it was off, the Search tab starts hidden.
        hiddenTabs = Self.loadHiddenTabs(in: defaults, storedCapabilities: stored)
        tabOrder = CommandPaletteTab.ordered(
            (defaults.stringArray(forKey: Key.quickSearchTabOrder) ?? []).compactMap(CommandPaletteTab.init(rawValue:))
        )
        takesCommandSpaceFromSpotlightOnLaunch = defaults.bool(forKey: Key.takesCommandSpaceFromSpotlightOnLaunch)
        let initial = Self.initialCapabilities(
            stored: stored,
            known: defaults.array(forKey: Key.knownCapabilities) as? [String],
            shippingOff: Set(CapabilityCatalog.descriptors.filter { !$0.isOnByDefault }.map(\.capability))
        ).union(CapabilityCatalog.alwaysOnCapabilities).filter(compatibility.supports)
        storedEnabledCapabilities = initial
        if stored != nil {
            defaults.set(initial.map(\.rawValue).sorted(), forKey: Key.enabledCapabilities)
        }
        defaults.set(Capability.allCases.map(\.rawValue).sorted(), forKey: Key.knownCapabilities)
        // Automatic unless a language was saved (#530); English was the default before.
        dictationLanguage = defaults.string(forKey: Key.dictationLanguage) ?? DictationLanguage.automatic
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
        foldsSettingsSidebarPlugins = defaults.bool(forKey: Key.foldsSettingsSidebarPlugins)
        didRequestScreenRecording = defaults.bool(forKey: Key.didRequestScreenRecording)
        copiesScreenshotsToClipboard = defaults.object(forKey: Key.copiesScreenshotsToClipboard) == nil
            || defaults.bool(forKey: Key.copiesScreenshotsToClipboard)
        var chosenFolders: [ScreengrabFolders.Kind: URL] = [:]
        for kind in ScreengrabFolders.Kind.allCases {
            if let path = defaults.string(forKey: Key.chosenFolder(kind)), path.hasPrefix("/") {
                chosenFolders[kind] = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        chosenScreengrabFolders = chosenFolders
        expandsSnippetKeywords = defaults.bool(forKey: Key.expandsSnippetKeywords)
        sendsCrashReports = Self.sendsCrashReports(in: defaults)
        lastLaunchedVersion = defaults.string(forKey: Key.lastLaunchedVersion)
        lastUpdateYearDay = defaults.object(forKey: Key.lastUpdateYearDay) as? Date
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
            capabilityShortcuts = Self.defaultCapabilityShortcuts
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
        defaults.removeObject(forKey: Key.retiredScreencastAddsToScreenshots)
        if introducedShortcuts {
            persistCapabilityShortcuts()
        }
        giveRecordScreenShortcutOnce()
        if defaults.object(forKey: Key.showInDockAndSwitcher) == nil,
           legacyDefaults.contains(where: { $0.object(forKey: Key.showInDockAndSwitcher) != nil }) {
            defaults.set(showInDockAndSwitcher, forKey: Key.showInDockAndSwitcher)
        }
        normalizeShortcutConflictsFavoringExistingWindowBindings()
        loadPluginValues()
    }

    /// The last area Screencast's picker recorded or captured (`screencast.lastArea`), kept with
    /// the other settings.
    var screencastAreaMemory: ScreencastAreaMemory { ScreencastAreaMemory(defaults: defaults) }

    /// Area, Window, or Screen, and the screen, as Screencast's picker last took them
    /// (`screencast.pickerChoices`).
    var screencastPickerMemory: ScreencastPickerMemory { ScreencastPickerMemory(defaults: defaults) }

    /// Where Screencast's control bar was left on each display (`screencast.controlBarPositions`).
    var screencastBarPlacement: ScreencastControlBarPlacement { ScreencastControlBarPlacement(defaults: defaults) }

    /// The drawing tools' last choices while recording (`screencast.drawingStyle`).
    var screencastDrawingMemory: ScreencastDrawingMemory { ScreencastDrawingMemory(defaults: defaults) }

    /// Whether the recordings index's one-time import ran (`screencast.recordingsImported`, #492).
    var recordingImportMemory: RecordingImportMemory { RecordingImportMemory(defaults: defaults) }

    /// Every folder ScreenGrabs saved a recording in (`screencast.recordingsFolders`, #504), which the
    /// recordings index reads again when it rebuilds.
    var recordingFolderMemory: RecordingFolderMemory { RecordingFolderMemory(defaults: defaults) }

    /// Turns a plugin on or off. One this Mac's macOS can't run stays off, and one that's always on
    /// stays on.
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
    /// them from (#334). A plugin shortcut that can't run on this Mac, such as Record Screen on
    /// macOS 14, isn't one: nobody is asked about keys that do nothing here.
    func shortcutConflict(for binding: ShortcutBinding, assigningTo owner: ShortcutOwner) -> ShortcutOwner? {
        let running = capabilityShortcuts.filter { CapabilityShortcut(rawValue: $0.key)?.runs(on: compatibility) ?? true }
        return ShortcutConflict.find(binding, for: owner, capabilityShortcuts: running, windowShortcuts: windowShortcuts)
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
            // One that can't run here gives up the keys without asking, so two actions never share
            // them once this Mac can run it (on an update to macOS 15).
            for shortcut in CapabilityShortcut.allCases where !shortcut.runs(on: compatibility)
                && owner != .capability(shortcut)
                && capabilityShortcuts[shortcut.rawValue]?.usesSameKeys(as: binding) == true {
                clear(.capability(shortcut), movingTo: owner)
                moved.append(.capability(shortcut))
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
