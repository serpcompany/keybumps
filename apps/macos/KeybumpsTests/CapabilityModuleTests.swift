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
            .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets
        ]
        #expect(CapabilityCatalog.descriptors.map(\.capability) == order)
        #expect(harness.model.capabilities.modules.map(\.capability) == order)
        #expect(Set(order) == Set(Capability.allCases))
        for capability in Capability.allCases {
            #expect(harness.model.capabilities.module(for: capability)?.capability == capability)
            #expect(CapabilityCatalog.descriptor(for: capability).capability == capability)
        }
    }

    @Test("Shortcut Coach's module supplies the Hotkeys rows, and the app gives them to the palette")
    func hotkeysRowsComeFromTheModule() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }

        #expect(Array(harness.model.capabilities.paletteContents.keys) == [.keyboardShortcutter])
        #expect(harness.model.capabilities.module(for: .keyboardShortcutter)?.paletteContent?.tab == .keyboardShortcutter)
        #expect(Array(harness.model.commandPalette.tabContents.keys) == [.keyboardShortcutter])
    }

    @Test("Every palette tab is drawn by the palette or supplied by its module, never neither or both")
    func everyTabHasRows() {
        let harness = ModuleHarness()
        defer { harness.tearDown() }

        let supplied = Set(harness.model.commandPalette.tabContents.keys)
        #expect(supplied.isDisjoint(with: CommandPaletteTab.drawnByPalette))
        #expect(supplied.union(CommandPaletteTab.drawnByPalette) == Set(CommandPaletteTab.allCases))
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

        await licensing.deactivate()
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

    @Test("Palette tabs and Settings pages come from their owning modules")
    func sharedSurfacesComeFromModules() {
        let tabs = CapabilityCatalog.paletteTabs
        #expect(tabs.map(\.commandKey) == [1, 2, 3, 4, 5, 6])
        #expect(Set(tabs.map(\.tab)).count == tabs.count)
        for rawValue in ["search", "clipboard", "dictation", "keyboardShortcutter", "screenshots", "snippets"] {
            #expect(CommandPaletteTab(rawValue: rawValue).map(CommandPaletteTab.allCases.contains) == true)
        }
        #expect(CommandPaletteTab.search.owner == .quickSearch)
        #expect(CommandPaletteTab.keyboardShortcutter.owner == .keyboardShortcutter)
        #expect(CommandPaletteTab.screenshots.owner == .screenshotTools)
        #expect(CommandPaletteTab.snippets.owner == .snippets)
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
        #expect(Array(SettingsSection.allCases.suffix(3)) == [.permissions, .general, .account])
    }

    @Test("The Screenshots tab copies on Return or a click, like the Clipboard tab, and edits with Command")
    func screenshotsTabCopiesAndEditsWithCommand() {
        #expect(ScreenshotPaletteAction(withCommand: false) == .copy)
        #expect(ScreenshotPaletteAction(withCommand: true) == .edit)
        // The footer pill names them in that order: Copy ↵, then Edit ⌘↵.
        #expect(CommandPaletteTab.screenshots.primaryActionTitle == "Copy")
        #expect(CommandPaletteTab.screenshots.primaryActionTitle == CommandPaletteTab.clipboard.primaryActionTitle)
        #expect(CommandPaletteTab.screenshots.secondaryActionTitle == "Edit")
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
            .snippets: []
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
            "quickSearch", "clipboardHistory", "dictation", "windowManagement", "keyboardShortcutter", "screenshotTools", "snippets"
        ])
        #expect(Capability.originalCapabilities == [
            .quickSearch, .clipboardHistory, .dictation, .windowManagement, .keyboardShortcutter
        ])

        let defaults = InMemoryDefaults()

        // An install from before per-capability tracking gets Screenshot Tools and Snippets once.
        defaults.set(["dictation", "quickSearch"], forKey: "enabledCapabilities")
        let upgraded = AppPreferences(defaults: defaults)
        #expect(upgraded.enabledCapabilities == [.dictation, .quickSearch, .screenshotTools, .snippets])
        #expect(defaults.stringArray(forKey: "enabledCapabilities") == ["dictation", "quickSearch", "screenshotTools", "snippets"])
        #expect(defaults.stringArray(forKey: "knownCapabilities") == Capability.allCases.map(\.rawValue).sorted())

        // Once known, the owner's choice is respected.
        upgraded.setCapability(.screenshotTools, enabled: false)
        upgraded.setCapability(.snippets, enabled: false)
        #expect(AppPreferences(defaults: defaults).enabledCapabilities == [.dictation, .quickSearch])

        // An install that already knew Screenshot Tools, but not Snippets, gets only Snippets.
        let screenshotsKnown = InMemoryDefaults()
        screenshotsKnown.set(["quickSearch"], forKey: "enabledCapabilities")
        screenshotsKnown.set(
            ["clipboardHistory", "dictation", "keyboardShortcutter", "quickSearch", "screenshotTools", "windowManagement"],
            forKey: "knownCapabilities"
        )
        #expect(AppPreferences(defaults: screenshotsKnown).enabledCapabilities == [.quickSearch, .snippets])
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
        if assignsSnippetsShortcut {
            preferences.setCapabilityShortcut(Self.snippetsBinding, for: .snippets)
        }

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
        case .quickSearch, .dictation, .snippets:
            model.shortcuts.activeOwners.isSuperset(of: Self.ownedShortcuts(for: capability))
        case .clipboardHistory: clipboard.isMonitoring
        case .windowManagement: windows.isDragSnapping
        case .keyboardShortcutter: model.detectorStatus == .monitoring
        case .screenshotTools: isWatchingScreenshots
        }
    }
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
