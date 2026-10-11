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

    private static func start(_ shortcut: String? = nil) -> QuickSearchAction {
        QuickSearchAction(capability: .screencast, action: .startScreencast, title: "Start Screencast", shortcut: shortcut)
    }

    private static func keystrokes(_ title: String = "Hide Keystrokes") -> QuickSearchAction {
        QuickSearchAction(capability: .keystrokes, action: .toggleKeystrokes, title: title)
    }

    private static func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Manifests

    @Test("Screencast declares Start Screencast and Keystrokes its show and hide, each with its plugin's shortcut")
    func declared() {
        #expect(CapabilityDescriptor.screencast.actions == [.startScreencast])
        #expect(CapabilityDescriptor.keystrokes.actions == [.toggleKeystrokes])
        #expect(PluginAction.startScreencast.shortcut == .screencast)
        #expect(PluginAction.toggleKeystrokes.shortcut == .keystrokes)
        for descriptor in CapabilityCatalog.descriptors where descriptor.capability != .screencast && descriptor.capability != .keystrokes {
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

        let on = WiringHarness(enabled: [.quickSearch, .keystrokes, .screencast], missing: nil, root: root)
        on.model.start()
        #expect(on.model.quickSearchActions == [Self.keystrokes(), Self.start()], "Registry order; keys show while it's on")

        on.model.preferences.setCapabilityShortcut(Self.startScreencastKeys, for: .screencast)
        #expect(on.model.quickSearchActions.last == Self.start("⌃⌥⇧R"), "Its shortcut's keycaps, once assigned")

        on.model.setCapability(.screencast, enabled: false)
        #expect(on.model.quickSearchActions == [Self.keystrokes()])
    }

    @Test("Before macOS 15, Start Screencast is never listed, even saved on; Keystrokes' is")
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
        let harness = WiringHarness(enabled: [.quickSearch, .screencast, .keystrokes], missing: nil, root: root, licensing: licensing)
        harness.model.start()
        #expect(!harness.model.isLicensed)
        #expect(harness.model.preferences.enabledCapabilities.isSuperset(of: [.screencast, .keystrokes]), "Saved on")
        #expect(harness.model.quickSearchActions.isEmpty)

        let keystrokes = try #require(harness.model.capabilities.module(for: .keystrokes) as? KeystrokesModule)
        harness.model.runQuickSearchAction(Self.keystrokes())
        #expect(keystrokes.isShowing, "Locked runs nothing")

        await licensing.activate(key: "KEYBUMPS-TEST")
        #expect(harness.model.quickSearchActions == [Self.keystrokes(), Self.start()])
    }

    @Test("Quick Search finds Start Screencast for screencast through the real model, beside Screencast's command")
    func modelListsTheAction() {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsModel")
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: [.quickSearch, .screencast], missing: nil, root: root, quickSearch: search)
        harness.model.start()

        search.query = "screencast"
        #expect(search.items == [.command(.capability(.screencast)), .command(.action(Self.start()))])

        harness.model.setCapability(.screencast, enabled: false)
        search.query = "start screencast"
        #expect(search.items.isEmpty, "Off: no action, and the command's name has no \"start\"")
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

        #expect(QuickSearchCommand.action(Self.start()).match("start screencast") == .name)
        #expect(QuickSearchCommand.action(Self.start()).match("record") == .keyword)
        #expect(QuickSearchCommand.action(Self.start()).match("sta") == .prefix)
        #expect(items("start") == [start, .result(file)])
        #expect(items("screencast") == [.command(.capability(.screencast)), start, .result(file)], "Equal scores keep commands first")
        #expect(
            items("capture", apps: [imageCapture])
                == [.result(imageCapture), .command(.capability(.screenshotTools)), .command(.capability(.screencast)), start, .result(file)],
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
        #expect(usage.record(for: .capability(.screencast)) == nil, "Kept apart from its plugin's command")
        let stored = try JSONDecoder().decode([String: ApplicationUsageRecord].self, from: Data(contentsOf: url))
        #expect(Array(stored.keys) == ["action:startScreencast"])
        #expect(action.usageKey == "action:startScreencast")
        #expect(QuickSearchCommand.capability(.screencast).usageKey == "command:screencast")

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
        #expect(QuickSearchCommand.capability(.screencast).kindLabel == "Command")
        #expect(action.title == "Start Screencast")
        #expect(action.accessibilityIdentifier == "quickSearch.action.startScreencast")
        #expect(QuickSearchCommand.capability(.screencast).accessibilityIdentifier == "quickSearch.command.screencast")
        #expect(action.rowShortcut(enabledCapabilities: [.screencast], visibleTabs: []) == "⌃⌥⇧R")
        #expect(QuickSearchCommand.action(Self.start()).rowShortcut(enabledCapabilities: [.screencast], visibleTabs: []) == nil)
        #expect(action.shortcut == nil && action.commandKey == nil, "No Command-key of its own")
        #expect(!action.isTurnedOff(enabledCapabilities: []))
        #expect(action.destination(enabledCapabilities: [.screencast]) == .action(Self.start("⌃⌥⇧R")))
        #expect(action.destination(enabledCapabilities: []).hint == "Closes the palette, then runs Start Screencast")
        #expect(PaletteFilter.commands.matches(.command(action)), "/'s Commands filter keeps it")
    }

    // MARK: Running

    @available(macOS 15, *)
    @Test("Picking Start Screencast in Quick Search learns it, closes the palette, and opens the picker")
    func pickingStartScreencastOpensThePicker() throws {
        let root = Self.temporaryRoot("KeybumpsQuickSearchActionsRun")
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: [.quickSearch, .screencast], missing: nil, root: root, quickSearch: search)
        harness.model.start()
        let action = try #require(harness.model.quickSearchActions.first)

        harness.model.commandPalette.choose(.action(action))
        let module = try #require(harness.model.capabilities.module(for: .screencast) as? ScreencastModule)
        let controller = try #require(module.controller, "Start Screencast's own path")
        #expect(controller.phase == .picking)
        #expect(!harness.model.commandPalette.isVisible)
        #expect(search.applicationUsage.record(for: .action(action))?.launchCount == 1)
        controller.cancel()
    }

    @Test("Without Screen Recording, Start Screencast from Quick Search opens Screencast's page, as the shortcut does")
    func startWithoutScreenRecordingOpensItsPage() {
        var opened: [SettingsSection] = []
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let permissions = PermissionCoordinator(screenRecordingAuthorized: { false })
        let module = ScreencastModule(preferences: preferences, permissions: permissions, openSettings: { opened.append($0) })
        let context = CapabilityContext(
            enabledCapabilities: [.screencast], preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: SilentHotKeys()), permissions: permissions,
            permissionReadiness: { _ in PermissionReadinessSnapshot.resolve(enabledCapabilities: [], states: [:], permissionsRequiringRelaunch: []) }
        )
        module.apply(context)
        module.perform(.startScreencast, context)
        #expect(opened == [.screencast])
        module.perform(.toggleKeystrokes, context)
        #expect(opened == [.screencast], "Another plugin's action does nothing here")
    }

    @Test("Show and Hide Keystrokes take the keys off the screen and back without turning the plugin off, named for what they'll do")
    func keystrokesShowAndHide() {
        let display = KeyDisplay(keys: InertKeyTypingMonitor(), pointer: InertPointerEventMonitor())
        let notices = NoticeRecorder()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.setCapability(.keystrokes, enabled: true)
        let module = KeystrokesModule(display: display, preferences: preferences, notices: notices)
        let context = CapabilityContext(
            enabledCapabilities: [.keystrokes], preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: SilentHotKeys()),
            permissions: PermissionCoordinator(inputMonitoringAuthorized: { true }),
            permissionReadiness: { _ in PermissionReadinessSnapshot.resolve(enabledCapabilities: [], states: [:], permissionsRequiringRelaunch: []) }
        )
        module.apply(context)
        #expect(module.isShowing && display.holds(.keystrokes))
        #expect(module.title(for: .toggleKeystrokes, context) == "Hide Keystrokes")

        module.perform(.toggleKeystrokes, context)
        #expect(!module.isShowing && !display.holds(.keystrokes))
        #expect(module.title(for: .toggleKeystrokes, context) == "Show Keystrokes")
        #expect(preferences.enabledCapabilities.contains(.keystrokes), "The plugin stays on")

        module.perform(.toggleKeystrokes, context)
        #expect(module.isShowing && display.holds(.keystrokes))
        #expect(notices.messages == ["Keystrokes hidden", "Showing keystrokes"], "The shortcut's notices")

        module.setShowing(true, announces: true)
        #expect(module.isShowing && display.holds(.keystrokes))
        #expect(notices.messages.count == 3, "Already showing: it stays, and says so again")
        #expect(module.title(for: .startScreencast, context) == nil)

        module.apply(CapabilityContext(
            enabledCapabilities: [], preferences: preferences, shortcuts: context.shortcuts,
            permissions: context.permissions, permissionReadiness: context.permissionReadiness
        ))
        module.setShowing(false, announces: true)
        #expect(!display.holds(.keystrokes), "Off: nothing shows")
        #expect(notices.messages.count == 4 && notices.messages.last == "Keystrokes hidden", "Off: hiding is only remembered, and still says so")
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
    func showNotice(_ message: String, isWarning: Bool) { messages.append(message) }
}
