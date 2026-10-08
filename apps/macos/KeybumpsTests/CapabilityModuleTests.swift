import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("Capability modules")
struct CapabilityModuleTests {
    // MARK: Registry

    @Test("The registry holds one module per capability, in catalog order")
    func registryOrderingAndLookups() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }

        let order: [Capability] = [
            .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets, .timer,
            .emojiPicker, .translation,
        ]
        #expect(CapabilityCatalog.descriptors.map(\.capability) == order)
        #expect(harness.model.capabilities.modules.map(\.capability) == order)
        #expect(Set(order) == Set(Capability.allCases))
        for capability in Capability.allCases {
            #expect(harness.model.capabilities.module(for: capability)?.capability == capability)
            #expect(CapabilityCatalog.descriptor(for: capability).capability == capability)
        }
    }

    @Test("Shortcut Coach's, Timer's, Emoji Picker's, and Translation's modules supply their tabs' rows, and the app gives them to the palette")
    func moduleRowsComeFromTheModules() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }

        #expect(Set(harness.model.capabilities.paletteContents.keys) == [.keyboardShortcutter, .timers, .emoji, .translate])
        #expect(harness.model.capabilities.module(for: .keyboardShortcutter)?.paletteContent?.tab == .keyboardShortcutter)
        #expect(harness.model.capabilities.module(for: .timer)?.paletteContent?.tab == .timers)
        #expect(harness.model.capabilities.module(for: .emojiPicker)?.paletteContent?.tab == .emoji)
        #expect(harness.model.capabilities.module(for: .translation)?.paletteContent?.tab == .translate)
        #expect(Set(harness.model.commandPalette.tabContents.keys) == [.keyboardShortcutter, .timers, .emoji, .translate])
    }

    @Test("Every palette tab is drawn by the palette or supplied by its module, never neither or both")
    func everyTabHasRows() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }

        let supplied = Set(harness.model.commandPalette.tabContents.keys)
        #expect(supplied.isDisjoint(with: CommandPaletteTab.drawnByPalette))
        #expect(supplied.union(CommandPaletteTab.drawnByPalette) == Set(CommandPaletteTab.allCases))
    }

    @Test("A plugin page's switch stores its preference through the app model")
    func setPluginPreference() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()
        harness.model.setPluginPreference(.timerMenuBarCountdown, to: .bool(false), for: .timer)
        #expect(!harness.model.preferences.bool(.timerMenuBarCountdown, for: .timer))
    }

    @Test("Turning a capability off clears its menu bar dot")
    func turningOffClearsDot() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()

        CapabilityMenuBarAttention(attention: harness.model.menuBarAttention, capability: .snippets).show(saying: "snippets need you")
        harness.model.setCapability(.snippets, enabled: false)
        #expect(!harness.model.menuBarAttention.showsDot)
    }

    // MARK: Licensing gate (ADR 0002)

    @Test("Locked runs no capability, and activating starts them")
    func lockedRunsNoCapability() async {
        let licensing = FixedLicenseController(state: .unlicensed)
        let harness = ModuleHarness(licensing: licensing)
        defer { harness.tearDown() }

        harness.model.start()
        #expect(harness.model.isLicensed == false)
        #expect(harness.model.capabilityContext.enabledCapabilities.isEmpty)
        #expect(harness.backend.registered.isEmpty)
        #expect(!harness.clipboard.isMonitoring)

        await licensing.activate(key: "KEYBUMPS-TEST")
        #expect(harness.model.isLicensed)
        #expect(!harness.backend.registered.isEmpty)
        #expect(harness.clipboard.isMonitoring)

        // Locked leaves nothing to open that would clear a capability's dot, so it goes too.
        CapabilityMenuBarAttention(attention: harness.model.menuBarAttention, capability: .snippets).show(saying: "snippets need you")
        await licensing.deactivate()
        #expect(!harness.model.menuBarAttention.showsDot)
        #expect(harness.backend.registered.isEmpty)
        #expect(!harness.clipboard.isMonitoring)
    }

    @Test("Every module follows the modules it depends on")
    func dependenciesPrecedeDependents() {
        let order = CapabilityCatalog.descriptors.map(\.capability)
        for descriptor in CapabilityCatalog.descriptors {
            let position = order.firstIndex(of: descriptor.capability)!
            for dependency in descriptor.dependencies {
                #expect(order.firstIndex(of: dependency)! < position, "\(descriptor.capability) before \(dependency)")
            }
        }
        #expect(CapabilityDescriptor.screenshotTools.dependencies == [.clipboardHistory])
    }

    @Test("Turning off Remember recently used emoji clears them, through the app model")
    func turningOffRecentEmojiClearsThem() throws {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()
        let tab = try #require(harness.model.commandPalette.tabContents[.emoji] as? EmojiPaletteContent)
        tab.recents.use("😀")
        harness.model.setPluginPreference(.emojiRemembersRecent, to: .bool(false), for: .emojiPicker)
        #expect(tab.recents.glyphs.isEmpty)
    }

    @Test("Turning Translation off keeps recent translations; Settings clears the Translate tab's own")
    func translationOffKeepsRecentTranslations() throws {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()
        let tab = try #require(harness.model.commandPalette.tabContents[.translate] as? TranslatePaletteContent)
        #expect(tab.recents === harness.model.recentTranslations)
        harness.model.recentTranslations.save("Hello", translated: "こんにちは", from: "en", to: "ja")
        harness.model.setCapability(.translation, enabled: false)
        #expect(harness.model.recentTranslations.records.map(\.sourceText) == ["Hello"])
    }

    @Test("A plugin that's off has no tab in the bar, and its Command-number does nothing, unless its tab is on screen")
    func offPluginsHaveNoTab() {
        let enabled = Set(Capability.allCases).subtracting([.emojiPicker, .clipboardHistory])
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search, enabled: enabled)
        #expect(tabs == [.search, .dictation, .snippets, .timers, .translate], "Screenshots lists Clipboard History, so it goes too")
        #expect(CommandPaletteTab.matchingCommandKey("7", in: tabs) == nil)
        #expect(CommandPaletteTab.matchingCommandKey("6", in: tabs) == .timers, "Numbers stay fixed")
        #expect(CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .emoji, enabled: enabled).contains(.emoji))
    }

    @Test("Left and Right go to the tab beside this one in the bar, skipping plugins that are off")
    func adjacentTabsSkipOffPlugins() {
        let enabled = Set(Capability.allCases).subtracting([.emojiPicker, .clipboardHistory])
        let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search, enabled: enabled)
        #expect(CommandPaletteTab.adjacent(to: .search, offset: 1, in: tabs) == .dictation)
        #expect(CommandPaletteTab.adjacent(to: .dictation, offset: -1, in: tabs) == .search)
        #expect(CommandPaletteTab.adjacent(to: .search, offset: -1, in: tabs) == nil, "No wrap at the first tab")
        #expect(CommandPaletteTab.adjacent(to: .timers, offset: 1, in: tabs) == .translate)
        #expect(CommandPaletteTab.adjacent(to: .translate, offset: 1, in: tabs) == nil, "No wrap at the last tab")
        #expect(CommandPaletteTab.adjacent(to: .emoji, offset: 1, in: tabs) == nil, "A tab not in the bar has no neighbor")
    }

    @Test("Palette tabs and Settings pages come from their owning modules")
    func sharedSurfacesComeFromModules() {
        let tabs = CapabilityCatalog.paletteTabs
        #expect(tabs.map(\.commandKey) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(Set(tabs.map(\.tab)).count == tabs.count)
        for rawValue in ["search", "clipboard", "dictation", "keyboardShortcutter", "screenshots", "snippets", "timers", "emoji", "translate"] {
            #expect(CommandPaletteTab(rawValue: rawValue).map(CommandPaletteTab.allCases.contains) == true)
        }
        #expect(CommandPaletteTab.search.owner == .quickSearch)
        #expect(CommandPaletteTab.keyboardShortcutter.owner == .keyboardShortcutter)
        #expect(CommandPaletteTab.screenshots.owner == .screenshotTools)
        #expect(CommandPaletteTab.snippets.owner == .snippets)
        #expect(CommandPaletteTab.timers.owner == .timer)
        #expect(CommandPaletteTab.emoji.owner == .emojiPicker)
        #expect(CommandPaletteTab.translate.owner == .translation)
        #expect(CapabilityCatalog.paletteTab(for: .screenshots).tab.dataSource == .clipboardHistory)
        #expect(CapabilityDescriptor.windowManagement.paletteTab == nil)

        for descriptor in CapabilityCatalog.descriptors {
            let section = descriptor.settingsPage?.section
            #expect(section?.rawValue == descriptor.title)
            #expect(section?.capability == descriptor.capability)
            #expect(section?.icon == descriptor.systemImage)
        }
        #expect(SettingsSection.permissions.capability == nil)
        #expect(SettingsSection.general.capability == nil)
        #expect(SettingsSection.changelog.capability == nil)
        #expect(Array(SettingsSection.allCases.suffix(4)) == [.permissions, .general, .changelog, .account])
    }

    @Test("The Screenshots tab copies on Return or a click, like the Clipboard tab, and edits with Command")
    func screenshotsTabCopiesAndEditsWithCommand() {
        #expect(ScreenshotPaletteAction(withCommand: false) == .copy)
        #expect(ScreenshotPaletteAction(withCommand: true) == .edit)
        // The footer pill names them in that order: Copy ↵, Paste ⌘P, then Edit ⌘↵.
        #expect(CommandPaletteTab.screenshots.primaryActionTitle == "Copy")
        #expect(CommandPaletteTab.screenshots.primaryActionTitle == CommandPaletteTab.clipboard.primaryActionTitle)
        #expect(CommandPaletteTab.screenshots.secondaryActions.map(\.description) == ["Paste ⌘P", "Edit ⌘↵"])
    }

    @Test("Only the modules that own critical operations declare them")
    func criticalOperationsAreDeclaredByTheirOwners() {
        let declared = Dictionary(uniqueKeysWithValues: CapabilityCatalog.descriptors.map {
            ($0.capability, $0.criticalOperations)
        })
        #expect(declared == [
            .quickSearch: [],
            .clipboardHistory: [],
            .screenshotTools: [.unsavedWork],
            .dictation: [],
            .windowManagement: [.windowAction, .windowDrag],
            .keyboardShortcutter: [],
            .snippets: [],
            .timer: [],
            .emojiPicker: [],
            .translation: []
        ])
    }

    // MARK: Lifecycle

    @Test("Turning a module off stops its resources and releases its shortcuts; turning it on restores them once", arguments: Capability.allCases)
    func togglingStartsAndStopsOwnedResources(_ capability: Capability) {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()
        let allOwners = harness.model.shortcuts.desiredOwners
        #expect(allOwners.isSuperset(of: ModuleHarness.ownedShortcuts(for: capability)))
        #expect(harness.resourcesRunning(for: capability))

        for _ in 0..<2 {
            harness.model.setCapability(capability, enabled: false)
            #expect(!harness.resourcesRunning(for: capability))
            #expect(harness.model.shortcuts.desiredOwners == allOwners.subtracting(ModuleHarness.ownedShortcuts(for: capability)))
            #expect(harness.backend.registered.count == harness.model.shortcuts.activeOwners.count)

            harness.model.setCapability(capability, enabled: true)
            #expect(harness.resourcesRunning(for: capability))
            #expect(harness.model.shortcuts.desiredOwners == allOwners)
            #expect(harness.backend.registered.count == harness.model.shortcuts.activeOwners.count)
        }
    }

    @Test("Screenshot Tools stops and reports Requires Clipboard History while Clipboard History is off")
    func screenshotToolsDependsOnClipboardHistory() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }
        harness.model.start()
        #expect(harness.isWatchingScreenshots)
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 0)

        harness.model.setCapability(.clipboardHistory, enabled: false)
        #expect(harness.model.screenshotTools.status == .requiresClipboardHistory)
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 1)
        // The edit action is Screenshot Tools' own contribution, so it stays while the module is on.
        #expect(harness.model.commandPalette.editImage != nil)

        harness.model.setCapability(.clipboardHistory, enabled: true)
        #expect(harness.isWatchingScreenshots)
        #expect(harness.model.settingsAttentionCount(for: .screenshotTools) == 0)

        harness.model.setCapability(.screenshotTools, enabled: false)
        #expect(harness.model.screenshotTools.status == .stopped)
        #expect(harness.model.commandPalette.editImage == nil)
    }

    // MARK: Persistence

    @Test("Preference keys and the known-capabilities migration are unchanged")
    func preferenceKeysAndKnownCapabilitiesMigration() {
        #expect(Capability.allCases.map(\.rawValue) == [
            "quickSearch", "clipboardHistory", "dictation", "windowManagement", "keyboardShortcutter", "screenshotTools", "snippets",
            "timer", "emojiPicker", "translation",
        ])
        #expect(Capability.originalCapabilities == [
            .quickSearch, .clipboardHistory, .dictation, .windowManagement, .keyboardShortcutter
        ])

        let defaults = InMemoryDefaults()

        // An install from before per-capability tracking gets Screenshot Tools, Snippets, and Timer once.
        defaults.set(["dictation", "quickSearch"], forKey: "enabledCapabilities")
        let upgraded = AppPreferences(defaults: defaults)
        #expect(upgraded.enabledCapabilities == [.dictation, .quickSearch, .screenshotTools, .snippets, .timer])
        #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["dictation", "quickSearch", "screenshotTools", "snippets", "timer"])
        #expect(defaults.stringArray(forKey: "knownCapabilities") == Capability.allCases.map(\.rawValue).sorted())

        // Once known, the owner's choice is respected.
        upgraded.setCapability(.screenshotTools, enabled: false)
        upgraded.setCapability(.snippets, enabled: false)
        upgraded.setCapability(.timer, enabled: false)
        #expect(AppPreferences(defaults: defaults).enabledCapabilities == [.dictation, .quickSearch])

        // An install that already knew Screenshot Tools, but not Snippets or Timer, gets only those.
        let screenshotsKnown = InMemoryDefaults()
        screenshotsKnown.set(["quickSearch"], forKey: "enabledCapabilities")
        screenshotsKnown.set(
            ["clipboardHistory", "dictation", "keyboardShortcutter", "quickSearch", "screenshotTools", "windowManagement"],
            forKey: "knownCapabilities"
        )
        #expect(AppPreferences(defaults: screenshotsKnown).enabledCapabilities == [.quickSearch, .snippets, .timer])
    }

    @Test("Open Snippets starts unassigned, on new installs and upgrades, and registers once the owner sets it")
    func openSnippetsShortcutStartsUnassigned() {
        #expect(CapabilityShortcut.snippets.defaultBinding == nil)
        #expect(CapabilityShortcut.snippets.capability == .snippets)
        #expect(AppPreferences(defaults: InMemoryDefaults()).capabilityShortcut(for: .snippets) == nil)

        let harness = ModuleHarness(assignsSnippetsShortcut: false)
        defer { harness.tearDown() }
        harness.model.start()
        #expect(!harness.model.shortcuts.desiredOwners.contains(CapabilityShortcut.snippets.ownerID))

        harness.model.finishCapabilityShortcutRecording(ModuleHarness.snippetsBinding, for: .snippets)
        #expect(harness.model.shortcuts.activeOwners.contains(CapabilityShortcut.snippets.ownerID))
        // With no default, restoring the default clears it.
        harness.model.restoreDefaultCapabilityShortcut(.snippets)
        #expect(!harness.model.shortcuts.desiredOwners.contains(CapabilityShortcut.snippets.ownerID))
    }

    @Test("Snippets requires no permission: missing Accessibility adds no attention or badge count")
    func snippetsRequiresNoPermission() {
        #expect(CapabilityDescriptor.snippets.requiredPermissions.isEmpty)
        #expect(CapabilityDescriptor.snippets.dependencies.isEmpty)
        let harness = ModuleHarness(accessibilityGranted: false)
        defer { harness.tearDown() }
        harness.model.preferences.enabledCapabilities = [.snippets]
        harness.model.start()
        #expect(harness.model.settingsAttentionCount(for: .snippets) == 0)
        #expect(harness.model.missingPermissions(for: .snippets).isEmpty)
        #expect(harness.model.missingPermissionCount == 0, "No Dock badge on installs that never granted Accessibility")
    }
}

// MARK: - Harness

@MainActor
private final class ModuleHarness {
    let backend = CountingHotKeyBackend()
    let clipboard: TrackingClipboardHistoryService
    let windows = TrackingWindowManagementService()
    let model: AppModel
    private let root: URL
    private let pasteboard: NSPasteboard

    /// A binding for the Open Snippets shortcut, which starts unassigned, so its module has a
    /// shortcut to register and release.
    static let snippetsBinding = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧S"
    )

    /// A binding for the Open Timers shortcut, which also starts unassigned.
    static let timerBinding = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧T"
    )

    /// A binding for the Open Emoji Picker shortcut, which also starts unassigned.
    static let emojiPickerBinding = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_E),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧E"
    )

    /// A binding for the Open Translate shortcut, which also starts unassigned.
    static let translationBinding = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧L"
    )

    init(
        licensing: (any LicenseControlling)? = nil,
        assignsSnippetsShortcut: Bool = true,
        accessibilityGranted: Bool = true
    ) {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityModules-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsCapabilityModules-\(id)"))
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.didCompleteOnboarding = true
        // Every module on, including those that ship off, so every module's lifecycle is covered.
        preferences.enabledCapabilities = Set(Capability.allCases)
        if assignsSnippetsShortcut {
            preferences.setCapabilityShortcut(Self.snippetsBinding, for: .snippets)
        }
        preferences.setCapabilityShortcut(Self.timerBinding, for: .timer)
        preferences.setCapabilityShortcut(Self.emojiPickerBinding, for: .emojiPicker)
        preferences.setCapabilityShortcut(Self.translationBinding, for: .translation)

        clipboard = TrackingClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        let screenshotHome = root.appendingPathComponent("home", isDirectory: true)
        model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: DiscardingEventPersistence()),
            presenceController: InertPresenceController(),
            detector: ManualActionDetector(monitor: InertPointerMonitor(), permissions: GrantedDetectorPermissions()),
            shortcutCoordinator: GlobalShortcutCoordinator(backend: backend),
            permissionCoordinator: PermissionCoordinator(
                accessibilityTrusted: { accessibilityGranted },
                inputMonitoringAuthorized: { true },
                microphoneAuthorizationStatus: { .authorized },
                speechAuthorizationStatus: { .authorized },
                screenRecordingAuthorized: { true },
                requestScreenRecording: {},
                openSettings: { _ in }
            ),
            updater: DisabledUpdateController(reason: "Capability module tests"),
            licensing: licensing,
            dictationModelManager: DictationModelManager(
                modelsRoot: root.appendingPathComponent("models", isDirectory: true),
                downloader: WhisperKitModelDownloader()
            ),
            spotlightShortcutResolver: InertSpotlightShortcutResolver(),
            clipboard: clipboard,
            timers: TimerStore(
                storageURL: root.appendingPathComponent(TimerStore.fileName),
                scheduler: NoTimerWakeUps(),
                notifications: NotificationCenter()
            ),
            recentTranslations: RecentTranslations(storageURL: root.appendingPathComponent(RecentTranslations.fileName)),
            dictationHistory: DictationHistoryService(
                recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
            ),
            windows: windows,
            screenshotTools: ScreenshotToolsService(
                resolver: ScreenshotLocationResolver(
                    preferredLocation: { nil },
                    homeDirectory: screenshotHome,
                    isDirectory: { _ in true }
                ),
                reader: FakeScreenshotDirectoryReader(granted: true),
                ingest: { _ in false }
            ),
            dictationIndicator: QuietDictationIndicator(),
            dictationFileManager: RootedFileManager(root: root),
            allowsDictationSystemAccess: false,
            screenshotEditorFallbackFolder: { screenshotHome }
        )
    }


    func tearDown() {
        model.screenshotTools.stop()
        clipboard.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    static func ownedShortcuts(for capability: Capability) -> Set<String> {
        switch capability {
        case .quickSearch: [CapabilityShortcut.quickSearch.ownerID]
        case .clipboardHistory: [CapabilityShortcut.clipboardHistory.ownerID]
        case .dictation: [CapabilityShortcut.dictation.ownerID]
        case .windowManagement: Set(WindowAction.allCases.filter { $0.defaultShortcut != nil }.map { "window.\($0.rawValue)" })
        case .screenshotTools: Set(CapabilityShortcut.allCases.filter { $0.capability == .screenshotTools }.map(\.ownerID))
        case .keyboardShortcutter: []
        case .snippets: [CapabilityShortcut.snippets.ownerID]
        case .timer: [CapabilityShortcut.timer.ownerID]
        case .emojiPicker: [CapabilityShortcut.emojiPicker.ownerID]
        case .translation: [CapabilityShortcut.translation.ownerID]
        }
    }

    var isWatchingScreenshots: Bool {
        if case .watching = model.screenshotTools.status { return true }
        return false
    }

    /// Whether the resources the capability owns are running. Capabilities without a background
    /// resource are judged by their shortcut alone.
    func resourcesRunning(for capability: Capability) -> Bool {
        switch capability {
        case .quickSearch, .dictation, .snippets, .emojiPicker, .translation:
            model.shortcuts.activeOwners.isSuperset(of: Self.ownedShortcuts(for: capability))
        case .clipboardHistory: clipboard.isMonitoring
        case .windowManagement: windows.isDragSnapping
        case .keyboardShortcutter: model.detectorStatus == .monitoring
        case .screenshotTools: isWatchingScreenshots
        case .timer:
            model.timers.isActive && model.shortcuts.activeOwners.isSuperset(of: Self.ownedShortcuts(for: capability))
        }
    }
}

/// Never schedules a wake-up: these tests start no timers.
@MainActor
private struct NoTimerWakeUps: TimerScheduling {
    private struct Never: TimerScheduledAction { func cancel() {} }
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction { Never() }
}

@MainActor
private final class CountingHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private(set) var registered: Set<UInt32> = []

    func installHandler(_ handler: @escaping (UInt32) -> Void) {}

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        registered.insert(identifier)
        return true
    }

    func unregister(identifier: UInt32) {
        registered.remove(identifier)
    }
}

private final class TrackingClipboardHistoryService: ClipboardHistoryService {
    private(set) var isMonitoring = false
    override func start() { isMonitoring = true }
    override func stop() { isMonitoring = false }
}

private final class TrackingWindowManagementService: WindowManagementService {
    private(set) var isDragSnapping = false
    override func startDragSnapping() { isDragSnapping = true }
    override func stop() { isDragSnapping = false }
}

private final class InertPointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { true }
    func stop() {}
}

private struct GrantedDetectorPermissions: DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { true }
    var isInputMonitoringAuthorized: Bool { true }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

private final class QuietDictationIndicator: DictationIndicatorController {
    override func update(_ phase: DictationPhase) {}
}

/// Keeps Dictation's recovery file out of the user's real Application Support folder.
private final class RootedFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

private struct DiscardingEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

@MainActor
private struct InertPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}
