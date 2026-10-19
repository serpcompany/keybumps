import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// Quick Search's action commands (#468): what plugins declare, listing them only while their plugin
/// is on, ranking them with commands and apps, learning their usage, and running them. Nothing here
/// shows a notice, records, or opens Settings.
@MainActor
@Suite("Quick Search: action commands")
struct QuickSearchActionTests {
    static let macOS14 = PluginCompatibility(macOSMajorVersion: 14)

    static let startScreencastKeys = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧R"
    )

    /// ScreenGrabs' Record Screen. A model starts with its ⇧⌘5.
    private static func start(_ shortcut: String? = nil) -> QuickSearchAction {
        QuickSearchAction(capability: .screenshotTools, action: .startScreencast, title: "Record Screen", shortcut: shortcut)
    }

    private static let recordScreenKeys = DefaultShortcut.recordScreen.displayName

    /// Named Show Keystrokes by default: the harness's keyboard tap never starts, so no keys are on
    /// screen.
    private static func keystrokes(_ title: String = "Show Keystrokes") -> QuickSearchAction {
        QuickSearchAction(capability: .keystrokes, action: .toggleKeystrokes, title: title)
    }

    /// A key display that draws nothing, with secure input off, whose keyboard tap starts only when
    /// `listens`, as macOS lets it only with Input Monitoring granted.
    private static func display(listens: Bool) -> KeyDisplay {
        KeyDisplay(keys: StandInKeys(listens: listens), pointer: InertPointerEventMonitor(), secureInput: { false })
    }

    private static func keystrokesContext(
        enabled: Set<Capability> = [.keystrokes], _ preferences: AppPreferences, inputMonitoring granted: Bool
    ) -> CapabilityContext {
        CapabilityContext(
            enabledCapabilities: enabled, preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: SilentHotKeys()),
            permissions: PermissionCoordinator(inputMonitoringAuthorized: { granted }),
            permissionReadiness: {
                PermissionReadinessSnapshot.resolve(
                    enabledCapabilities: $0, states: [.inputMonitoring: granted ? .granted : .denied], permissionsRequiringRelaunch: []
                )
            }
        )
    }

    private static func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Manifests

    @Test("ScreenGrabs declares Record Screen and Keystrokes its show and hide, each with its plugin's shortcut")
    func declared() {
        #expect(CapabilityDescriptor.screenshotTools.actions == [.startScreencast])
        #expect(CapabilityDescriptor.keystrokes.actions == [.toggleKeystrokes])
        #expect(PluginAction.startScreencast.shortcut == .screencast)
        #expect(PluginAction.toggleKeystrokes.shortcut == .keystrokes)
        for descriptor in CapabilityCatalog.descriptors where descriptor.capability != .screenshotTools && descriptor.capability != .keystrokes {
            #expect(descriptor.actions.isEmpty, "\(descriptor.title)")
        }
    }

    @Test("Every action's ID is unique and isn't a command's, and its shortcut is its own plugin's")
    func declarationsAreValid() {
        let actions = CapabilityCatalog.descriptors.flatMap { descriptor in descriptor.actions.map { (descriptor.capability, $0) } }
        let ids = actions.map(\.1.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids).isDisjoint(with: QuickSearchCommand.allCases.map(\.id)))
        for (capability, action) in actions {
            #expect(!action.title.isEmpty)
            #expect(action.shortcut.map { $0.capability == capability } ?? true, "\(action.id)")
        }
    }

    // MARK: Listing

    @Test("An action is listed only while its plugin is on, named and with keycaps as they are now")
    func listedOnlyWhileOn() {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActions")
        defer { try? FileManager.default.removeItem(at: root) }

        let off = WiringHarness(enabled: [.quickSearch], missing: nil, root: root)
        off.model.start()
        #expect(off.model.quickSearchActions.isEmpty)

        let on = WiringHarness(enabled: [.quickSearch, .keystrokes, .screenshotTools], missing: nil, root: root)
        on.model.start()
        #expect(on.model.quickSearchActions == [Self.start(Self.recordScreenKeys), Self.keystrokes()], "Registry order")

        on.model.preferences.setCapabilityShortcut(Self.startScreencastKeys, for: .screencast)
        #expect(on.model.quickSearchActions.first == Self.start("⌃⌥⇧R"), "Its shortcut's keycaps, as they are now")
        on.model.preferences.setCapabilityShortcut(nil, for: .screencast)
        #expect(on.model.quickSearchActions.first == Self.start())

        on.model.setCapability(.screenshotTools, enabled: false)
        #expect(on.model.quickSearchActions == [Self.keystrokes()])
    }

    @Test("Before macOS 15, Record Screen is never listed, with ScreenGrabs on; Keystrokes' is")
    func screencastNeedsMacOS15() {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsGate")
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = InMemoryDefaults()
        saved.set(Capability.allCases.map(\.rawValue), forKey: "enabledCapabilities")
        saved.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
        let old = WiringHarness(
            enabled: Set(Capability.allCases), missing: nil, root: root, compatibility: Self.macOS14, defaults: saved
        )
        old.model.start()
        #expect(old.model.quickSearchActions.map(\.action) == [.toggleKeystrokes])
    }

    @Test("Locked lists and runs no actions, even with their plugins saved on, and activating lists them")
    func lockedListsNone() async throws {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsLocked")
        defer { try? FileManager.default.removeItem(at: root) }
        let licensing = FixedLicenseController(state: .unlicensed)
        let harness = WiringHarness(enabled: [.quickSearch, .screenshotTools, .keystrokes], missing: nil, root: root, licensing: licensing)
        harness.model.preferences.set(.bool(false), of: .keystrokesShowing, for: .keystrokes)
        harness.model.start()
        #expect(!harness.model.isLicensed)
        #expect(harness.model.preferences.enabledCapabilities.isSuperset(of: [.screenshotTools, .keystrokes]), "Saved on")
        #expect(harness.model.quickSearchActions.isEmpty)

        let keystrokes = try #require(harness.model.capabilities.module(for: .keystrokes) as? KeystrokesModule)
        harness.model.runQuickSearchAction(Self.keystrokes())
        #expect(!keystrokes.isShowing, "Locked runs nothing: running it would show the hidden keys")

        await licensing.activate(key: "KEYBUMPS-TEST")
        #expect(harness.model.quickSearchActions == [Self.start(Self.recordScreenKeys), Self.keystrokes()])
    }

    @Test("Quick Search finds Record Screen for screencast through the real model, beside ScreenGrabs' command")
    func modelListsTheAction() {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsModel")
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: [.quickSearch, .screenshotTools], missing: nil, root: root, quickSearch: search)
        harness.model.start()

        search.query = "screencast"
        #expect(search.items == [.command(.capability(.screenshotTools)), .command(.action(Self.start(Self.recordScreenKeys)))])

        harness.model.setCapability(.screenshotTools, enabled: false)
        search.query = "record screen"
        #expect(search.items == [.command(.capability(.screenshotTools))], "Off: no action, and ScreenGrabs' command opens its page")
    }

    // MARK: Ranking

    @Test("An action ranks as a command does: a name match leads, a keyword never hides an app, a prefix follows")
    func ranking() {
        let imageCapture = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Image Capture.app"), kind: .application)
        let file = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/fixture/notes.txt"), kind: .file)
        func items(_ query: String, apps: [QuickSearchResult] = [], usage: ApplicationUsageStore? = nil) -> [QuickSearchItem] {
            QuickSearchRanking.items(matching: query, applications: apps, files: [file], actions: [Self.start()], usage: usage)
        }
        let start = QuickSearchItem.command(.action(Self.start()))

        #expect(QuickSearchCommand.action(Self.start()).match("record screen") == .name)
        #expect(QuickSearchCommand.action(Self.start()).match("screencast") == .keyword)
        #expect(QuickSearchCommand.action(Self.start()).match("video") == .keyword)
        #expect(QuickSearchCommand.action(Self.start()).match("rec scr") == .prefix)
        #expect(QuickSearchCommand.action(Self.start()).match("screenshot") == nil, "It records video only (#485)")
        #expect(!items("screenshot").contains(start))
        #expect(items("record screen") == [start, .command(.capability(.screenshotTools)), .result(file)])
        #expect(items("screencast") == [.command(.capability(.screenshotTools)), start, .result(file)], "Equal scores keep commands first")
        #expect(
            items("capture", apps: [imageCapture])
                == [.result(imageCapture), .command(.capability(.screenshotTools)), start, .result(file)],
            "A keyword lists it after the app it names"
        )
        #expect(items("hello").filter { if case .command = $0 { true } else { false } }.isEmpty)
    }

    @Test("Picking an action teaches it under action:<id>, and one pick lifts it past its plugin's command")
    func learnedUsage() throws {
        let url = Self.temporaryRoot("KeybumpsQuickSearchActionsUsage").appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let usage = ApplicationUsageStore(storageURL: url, now: { now })
        let action = QuickSearchCommand.action(Self.start())

        usage.record(action)
        #expect(usage.record(for: action)?.launchCount == 1)
        #expect(usage.record(for: .capability(.screenshotTools)) == nil, "Kept apart from its plugin's command")
        let stored = try JSONDecoder().decode([String: ApplicationUsageRecord].self, from: Data(contentsOf: url))
        #expect(Array(stored.keys) == ["action:startScreencast"])
        #expect(action.usageKey == "action:startScreencast")
        #expect(QuickSearchCommand.capability(.screenshotTools).usageKey == "command:screenshotTools")

        let ranked = QuickSearchRanking.items(matching: "screencast", applications: [], files: [], actions: [Self.start()], usage: usage)
        #expect(ranked.first == .command(action))
        let assigned = QuickSearchRanking.items(matching: "screencast", applications: [], files: [], actions: [Self.start("⌃⌥⇧R")], usage: usage)
        #expect(assigned.first == .command(.action(Self.start("⌃⌥⇧R"))), "Learned by its ID, whatever its keycaps")
    }

    // MARK: Rows

    @Test("Its row says Action, shows its shortcut's keycaps while assigned, and closes the palette to run")
    func row() {
        let action = QuickSearchCommand.action(Self.start("⌃⌥⇧R"))
        #expect(action.kindLabel == "Action")
        #expect(QuickSearchCommand.capability(.screenshotTools).kindLabel == "Command")
        #expect(action.title == "Record Screen")
        #expect(action.accessibilityIdentifier == "quickSearch.action.startScreencast")
        #expect(QuickSearchCommand.capability(.screenshotTools).accessibilityIdentifier == "quickSearch.command.screenshotTools")
        #expect(action.rowShortcut(enabledCapabilities: [.screenshotTools], visibleTabs: []) == "⌃⌥⇧R")
        #expect(QuickSearchCommand.action(Self.start()).rowShortcut(enabledCapabilities: [.screenshotTools], visibleTabs: []) == nil)
        #expect(action.shortcut == nil && action.commandKey == nil, "No Command-key of its own")
        #expect(!action.isTurnedOff(enabledCapabilities: []))
        #expect(action.destination(enabledCapabilities: [.screenshotTools]) == .action(Self.start("⌃⌥⇧R")))
        #expect(action.destination(enabledCapabilities: []).hint == "Closes Quick Search, then runs Record Screen")
        #expect(PaletteFilter.commands.matches(.command(action)), "/'s Commands filter keeps it")
    }

    // MARK: Running

    @available(macOS 15, *)
    @Test("Picking Record Screen in Quick Search learns it, closes the palette, and opens the picker")
    func pickingStartScreencastOpensThePicker() throws {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsRun")
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: [.quickSearch, .screenshotTools], missing: nil, root: root, quickSearch: search)
        harness.model.start()
        let action = try #require(harness.model.quickSearchActions.first)

        harness.model.commandPalette.choose(.action(action))
        let module = try #require(harness.model.recording)
        let controller = try #require(module.controller, "Record Screen's own path")
        #expect(controller.phase == .picking)
        #expect(!harness.model.commandPalette.isVisible)
        #expect(search.applicationUsage.record(for: .action(action))?.launchCount == 1)

        #expect(harness.model.quickSearchActions.isEmpty, "Not listed while a capture is under way, when it would do nothing")
        search.query = "record screen"
        #expect(!search.items.contains(.command(.action(action))))
        controller.cancel()
        #expect(harness.model.quickSearchActions == [action], "Listed again once the capture is over")
    }

    @Test("Without Screen Recording, Record Screen from Quick Search opens ScreenGrabs' page, as the shortcut does")
    func startWithoutScreenRecordingOpensItsPage() {
        var opened: [SettingsSection] = []
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let permissions = PermissionCoordinator(screenRecordingAuthorized: { false })
        let module = ScreencastModule(preferences: preferences, permissions: permissions, openSettings: { opened.append($0) })
        let context = CapabilityContext(
            enabledCapabilities: [.screenshotTools], preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: SilentHotKeys()), permissions: permissions,
            permissionReadiness: { _ in PermissionReadinessSnapshot.resolve(enabledCapabilities: [], states: [:], permissionsRequiringRelaunch: []) }
        )
        module.apply(context)
        module.perform(.startScreencast, context)
        #expect(opened == [.screenshotTools])
        module.perform(.toggleKeystrokes, context)
        #expect(opened == [.screenshotTools], "Another plugin's action does nothing here")
    }

    @Test("Show and Hide Keystrokes take the keys off the screen and back without turning the plugin off, named for what they'll do")
    func keystrokesShowAndHide() {
        var opened: [SettingsSection] = []
        let display = Self.display(listens: true)
        let notices = NoticeRecorder()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.setCapability(.keystrokes, enabled: true)
        let module = KeystrokesModule(display: display, preferences: preferences, notices: notices, openSettings: { opened.append($0) })
        let context = Self.keystrokesContext(preferences, inputMonitoring: true)
        module.apply(context)
        #expect(module.isShowing && display.isOnScreen)
        #expect(module.title(for: .toggleKeystrokes, context) == "Hide Keystrokes")

        module.perform(.toggleKeystrokes, context)
        #expect(!module.isShowing && !display.isOnScreen)
        #expect(display.holds(.keystrokes) && display.isHidden(.keystrokes), "Hidden, it still holds the display, its keys hidden")
        #expect(module.title(for: .toggleKeystrokes, context) == "Show Keystrokes")
        #expect(preferences.enabledCapabilities.contains(.keystrokes), "The plugin stays on")

        module.perform(.toggleKeystrokes, context)
        #expect(module.isShowing && display.isOnScreen && !display.isHidden(.keystrokes))
        #expect(notices.messages == ["Keystrokes hidden", "Keystrokes shown"], "The shortcut's notices")
        #expect(notices.warnings == [false, false])
        #expect(opened.isEmpty, "With Input Monitoring, Settings stays shut")

        module.setShowing(true, announces: true)
        #expect(module.isShowing && display.isOnScreen)
        #expect(notices.messages.count == 3, "Already shown: it stays, and says so again")
        #expect(module.title(for: .startScreencast, context) == nil)

        module.apply(Self.keystrokesContext(enabled: [], preferences, inputMonitoring: true))
        module.setShowing(false, announces: true)
        #expect(!display.holds(.keystrokes), "Off: nothing shows")
        #expect(notices.messages.count == 4 && notices.messages.last == "Keystrokes hidden", "Off: hiding is only remembered, and still says so")
    }

    @Test("Show or Hide Keystrokes is named for the keys on screen, so a recording's keys make it Hide Keystrokes though Hidden is saved")
    func keystrokesTitleFollowsTheScreen() {
        let display = Self.display(listens: true)
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let module = KeystrokesModule(display: display, preferences: preferences, notices: NoticeRecorder())
        let context = Self.keystrokesContext(preferences, inputMonitoring: true)
        let title = { module.title(for: .toggleKeystrokes, context) }
        module.apply(context)
        #expect(title() == "Hide Keystrokes")
        module.setShowing(false)
        #expect(title() == "Show Keystrokes", "Hidden, and nothing else shows keys")

        var recordingLook = KeyDisplayConfiguration()
        recordingLook.position = .bottomRight
        recordingLook.displays = [2]
        display.acquire(.screencast, configuration: recordingLook, keepsWindowsOnScreen: true)
        #expect(!module.isShowing && display.isOnScreen)
        #expect(title() == "Hide Keystrokes", "A recording's keys are on screen")

        module.perform(.toggleKeystrokes, context)
        #expect(display.isHidden(.screencast) && !display.isOnScreen, "It hides the recording's keys too")
        #expect(title() == "Show Keystrokes")

        module.perform(.toggleKeystrokes, context)
        #expect(module.isShowing && display.isOnScreen)
        #expect(display.configuration?.position == .bottomRight, "Shown again, in the recording's look")
        #expect(title() == "Hide Keystrokes")

        display.release(.screencast)
        module.setShowing(false)
        #expect(title() == "Show Keystrokes", "The recording over and the plugin's keys hidden")
    }

    @Test("Without Input Monitoring no keys are on screen: Show Keystrokes shows them, says why none can appear, and opens Keystrokes' page, which asks for it")
    func showKeystrokesWithoutInputMonitoringOpensItsPage() {
        var opened: [SettingsSection] = []
        let display = Self.display(listens: false)
        let notices = NoticeRecorder()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let module = KeystrokesModule(display: display, preferences: preferences, notices: notices, openSettings: { opened.append($0) })
        let context = Self.keystrokesContext(preferences, inputMonitoring: false)
        module.apply(context)
        #expect(module.isShowing && display.isShowing && !display.isOnScreen, "Shown, but the tap is refused, so none can appear")
        #expect(module.title(for: .toggleKeystrokes, context) == "Show Keystrokes")

        module.perform(.toggleKeystrokes, context)
        #expect(module.isShowing && display.isShowing, "A press shows them, never hides")
        #expect(opened == [.keystrokes])
        #expect(notices.messages == ["Keystrokes can't show keys without Input Monitoring"])
        #expect(notices.warnings == [true])

        module.setShowing(false)
        #expect(module.title(for: .toggleKeystrokes, context) == "Show Keystrokes")
        module.perform(.toggleKeystrokes, context)
        #expect(module.isShowing && !display.isHidden(.keystrokes), "Hidden was saved: a press shows them and saves Shown")
        #expect(opened == [.keystrokes, .keystrokes])
        #expect(notices.messages == Array(repeating: "Keystrokes can't show keys without Input Monitoring", count: 2), "Never Keystrokes hidden")
    }
}

@MainActor
private final class SilentHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

private final class NoticeRecorder: PaletteNoticePresenting {
    private(set) var messages: [String] = []
    private(set) var warnings: [Bool] = []
    func showNotice(_ message: String, isWarning: Bool) {
        messages.append(message)
        warnings.append(isWarning)
    }
}

/// A keyboard tap that never hears a key, and starts only when `listens`.
private final class StandInKeys: KeyPressMonitoring {
    var onPress: ((KeyPress) -> Void)?
    private let listens: Bool
    init(listens: Bool) { self.listens = listens }
    func start() -> Bool { listens }
    func stop() {}
}
