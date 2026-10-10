import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// Screencast's plugin shell (#445, ADR 0009): its manifest, its preferences and their defaults,
/// the macOS 15 gate, and Start Screencast, which opens the picker (#447). Nothing here records,
/// reads the screen, asks for a permission, or opens Settings or Finder.
@MainActor
@Suite("Screencast: the plugin shell")
struct ScreencastTests {
    static let macOS14 = PluginCompatibility(macOSMajorVersion: 14)
    static let macOS15 = PluginCompatibility(macOSMajorVersion: 15)

    static let startScreencast = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧R"
    )

    @Test("Its manifest: an added media plugin that ships off, needs macOS 15, and has a page but no tab")
    func manifest() throws {
        let descriptor = CapabilityDescriptor.screencast
        #expect(descriptor.title == "Screencast")
        #expect(descriptor.category == .media)
        #expect(!descriptor.isOnByDefault)
        #expect(descriptor.minimumMacOS == 15)
        #expect(descriptor.paletteTab == nil, "⌘1–⌘9 are taken (ADR 0009)")
        #expect(descriptor.dependencies.isEmpty)
        #expect(descriptor.criticalOperations.isEmpty)
        #expect(descriptor.settingsPage?.section == .screencast)
        #expect(!CapabilityCatalog.defaultCapabilities.contains(.screencast), "An added capability")
        #expect(descriptor.shortcuts == [.screencast, .screencastPause, .screencastStop, .screencastDiscard, .screencastDraw])
        #expect(PluginSettingsPage<EmptyView>.byline(descriptor) == "Official plugin by Keybumps · Media")
    }

    @Test("Its icon is a real symbol no other plugin uses")
    func icon() {
        let descriptor = CapabilityDescriptor.screencast
        #expect(NSImage(systemSymbolName: descriptor.systemImage, accessibilityDescription: nil) != nil)
        let others = CapabilityCatalog.descriptors.filter { $0.capability != .screencast }
        #expect(!others.map(\.systemImage).contains(descriptor.systemImage))
        #expect(!others.compactMap(\.paletteTab?.systemImage).contains(descriptor.systemImage))
        #expect(SettingsSection.screencast.icon == descriptor.systemImage)
    }

    @Test("It needs Screen Recording, which says so, and can use the Microphone, with its own reason")
    func permissions() throws {
        let descriptor = CapabilityDescriptor.screencast
        #expect(descriptor.requiredPermissions == [.screenRecording])
        #expect(MacPermission.screenRecording.explanation.contains("Screencast"))
        let microphone = try #require(descriptor.optionalPermissions.first)
        #expect(descriptor.optionalPermissions.map(\.permission) == [.microphone])
        #expect(microphone.reason.contains("voice"))
        #expect(!MacPermission.microphone.explanation.contains("Screencast"), "Optional: its reason is its own")
        #expect(PermissionSetupPlan.requiredPermissions(for: [.screencast]) == [.screenRecording])
    }

    @Test("Quick Search finds its command, which opens its page whether it's on or off")
    func command() {
        let command = QuickSearchCommand.capability(.screencast)
        #expect(command.match("screencast") == .name)
        #expect(command.match("screen recording") == .keyword)
        #expect(command.destination(enabledCapabilities: [.screencast]) == .settings(.screencast))
        #expect(command.destination(enabledCapabilities: []) == .settings(.screencast))
    }

    // MARK: Preferences

    @Test("Its preferences start as the issue sets them: both sounds, shortcuts shown, no click rings, a 3-second countdown")
    func defaults() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        #expect(preferences.screencast == ScreencastPreferences(
            recordsMicrophone: true,
            recordsSystemAudio: true,
            countdownSeconds: 3,
            showsShortcuts: true,
            highlightsClicks: false,
            capturesFolder: ProductPaths.keybumps().captures
        ))
    }

    @Test("Its page lists them in groups: Sound, then Recording, then its captures folder")
    func groups() {
        let descriptor = CapabilityDescriptor.screencast
        #expect(descriptor.preferenceGroups.map(\.title) == ["Sound", "Recording"])
        #expect(descriptor.preferenceGroups.map { $0.preferences.map(\.key) } == [
            ["recordsMicrophone", "recordsSystemAudio"],
            ["countdown", "showsShortcuts", "highlightsClicks"],
        ])
        guard case .choice(let options, _) = PluginPreference.screencastCountdown.kind else {
            Issue.record("The countdown is a menu")
            return
        }
        #expect(options.map(\.value) == ["0", "3", "5", "10"])
        #expect(options.map(\.title) == ["None", "3 seconds", "5 seconds", "10 seconds"])
    }

    @Test("A change is stored under the plugin's name, read back after a relaunch, and in the typed value")
    func storage() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.set(.bool(false), of: .screencastRecordsMicrophone, for: .screencast)
        preferences.set(.bool(false), of: .screencastRecordsSystemAudio, for: .screencast)
        preferences.set(.bool(false), of: .screencastShowsShortcuts, for: .screencast)
        preferences.set(.bool(true), of: .screencastHighlightsClicks, for: .screencast)
        preferences.set(.choice("0"), of: .screencastCountdown, for: .screencast)

        #expect(defaults.object(forKey: "plugin.screencast.recordsMicrophone") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.recordsSystemAudio") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.showsShortcuts") as? Bool == false)
        #expect(defaults.object(forKey: "plugin.screencast.highlightsClicks") as? Bool == true)
        #expect(defaults.object(forKey: "plugin.screencast.countdown") as? String == "0")

        let relaunched = AppPreferences(defaults: defaults).screencast
        #expect(!relaunched.recordsMicrophone)
        #expect(!relaunched.recordsSystemAudio)
        #expect(!relaunched.showsShortcuts)
        #expect(relaunched.highlightsClicks)
        #expect(relaunched.countdownSeconds == 0)

        preferences.set(.choice("10"), of: .screencastCountdown, for: .screencast)
        #expect(preferences.screencast.countdownSeconds == 10)
        preferences.set(.choice("4"), of: .screencastCountdown, for: .screencast)
        #expect(preferences.screencast.countdownSeconds == 10, "Only one of its options")
    }

    @Test("Captures go in Documents › Keybumps › captures, shown as Go to Folder takes it")
    func capturesFolder() {
        let paths = ProductPaths.make(productDirectoryName: "Keybumps", fileManager: .default, sandboxRoot: nil, unitTestRoot: nil)
        #expect(paths.captures == paths.recordings.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true))
        // Lexical only: nothing reads the owner's folders.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documents = home.appendingPathComponent("Documents/Keybumps/captures", isDirectory: true)
        #expect(ScreencastCapturesSettings.displayPath(documents) == "~/Documents/Keybumps/captures")
    }

    // MARK: The macOS 15 gate

    @Test("On macOS 14 it can't be turned on, and says it requires macOS 15")
    func refusedOnMacOS14() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.macOS14)
        #expect(!preferences.compatibility.supports(.screencast))
        #expect(preferences.compatibility.requirement(for: .screencast) == "Requires macOS 15")
        preferences.setCapability(.screencast, enabled: true)
        #expect(!preferences.enabledCapabilities.contains(.screencast))
    }

    @Test("On macOS 15 and later it ships off, then turns on like any plugin", arguments: [15, 26, 27])
    func allowedOnMacOS15(_ version: Int) {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: version))
        #expect(preferences.compatibility.requirement(for: .screencast) == nil)
        #expect(!preferences.enabledCapabilities.contains(.screencast), "It ships off")
        preferences.setCapability(.screencast, enabled: true)
        #expect(preferences.enabledCapabilities.contains(.screencast))
    }

    @Test("An update that adds it leaves it off, as it ships off")
    func updateLeavesItOff() {
        let known = Capability.allCases.filter { $0 != .screencast }.map(\.rawValue)
        let saved = InMemoryDefaults()
        saved.set(["quickSearch", "timer"], forKey: "enabledCapabilities")
        saved.set(known, forKey: "knownCapabilities")
        #expect(AppPreferences(defaults: saved, compatibility: Self.macOS15).enabledCapabilities == [.quickSearch, .timer])
    }

    // MARK: Start Screencast

    @Test("Start Screencast starts unassigned, on new installs and upgrades")
    func shortcutStartsUnassigned() {
        #expect(CapabilityShortcut.screencast.title == "Start Screencast")
        #expect(CapabilityShortcut.screencast.capability == .screencast)
        #expect(CapabilityShortcut.screencast.defaultBinding == nil)
        #expect(CapabilityShortcut.screencast.worksEverywhere)
        #expect(!CapabilityShortcut.originalShortcuts.contains(.screencast))
        #expect(AppPreferences(defaults: InMemoryDefaults()).capabilityShortcut(for: .screencast) == nil)

        let upgraded = InMemoryDefaults()
        upgraded.set(try? JSONEncoder().encode([String: ShortcutBinding]()), forKey: "capabilityShortcuts")
        #expect(AppPreferences(defaults: upgraded).capabilityShortcut(for: .screencast) == nil)
    }

    @Test("Start Screencast, once assigned, registers only while Screencast is on, on macOS 15")
    func shortcutRegistersWhileOn() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = CapabilityShortcut.screencast.ownerID

        func harness(enabled: Set<Capability>, on compatibility: PluginCompatibility) -> WiringHarness {
            let harness = WiringHarness(enabled: enabled, missing: nil, root: root, compatibility: compatibility)
            harness.model.preferences.setCapabilityShortcut(Self.startScreencast, for: .screencast)
            harness.model.start()
            return harness
        }

        let on = harness(enabled: [.screencast], on: Self.macOS15)
        #expect(on.shortcuts()[owner] != nil)
        on.model.setCapability(.screencast, enabled: false)
        #expect(on.shortcuts()[owner] == nil)

        let off = harness(enabled: [], on: Self.macOS15)
        #expect(off.shortcuts()[owner] == nil)

        let old = harness(enabled: [.screencast], on: Self.macOS14)
        #expect(old.shortcuts()[owner] == nil, "It's never on before macOS 15")
    }

    @Test("Start Screencast opens Screencast's page while it's off")
    func startWhileOffOpensItsPage() {
        var opened: [SettingsSection] = []
        let module = ScreencastModule(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { opened.append($0) }
        )
        module.start()
        #expect(opened == [.screencast])
    }

    @available(macOS 15, *)
    @Test("Start Screencast opens the picker with Screen Recording, and never reads the screen without it")
    func startOpensThePicker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastStart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = WiringHarness(enabled: [.screencast], missing: .screenRecording, root: root)
        missing.model.start()
        missing.model.startScreencast()
        #expect(Self.module(of: missing).controller == nil, "No picker, so macOS never asks")

        let granted = WiringHarness(enabled: [.screencast], missing: nil, root: root)
        granted.model.start()
        granted.model.startScreencast()
        let controller = try #require(Self.module(of: granted).controller)
        #expect(controller.phase == .picking)
        #expect(controller.picker?.microphoneAvailable == true)
        controller.cancel()

        let noMicrophone = WiringHarness(enabled: [.screencast], missing: .microphone, root: root)
        noMicrophone.model.start()
        noMicrophone.model.startScreencast()
        let picker = try #require(Self.module(of: noMicrophone).controller?.picker)
        #expect(!picker.microphoneAvailable && !picker.recordsMicrophone, "Its switch stays off; nothing asks for it")
    }

    @available(macOS 15, *)
    @Test("Turning Screencast off closes the picker")
    func turningOffCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screencast], missing: nil, root: root)
        harness.model.start()
        harness.model.startScreencast()
        let controller = try #require(Self.module(of: harness).controller)
        #expect(controller.phase == .picking)
        harness.model.setCapability(.screencast, enabled: false)
        #expect(await ScreencastWait.until { controller.phase == .idle })
        #expect(controller.picker == nil)
        harness.model.startScreencast()
        #expect(controller.phase == .idle, "Off, Start Screencast opens its page instead")
    }

    @available(macOS 15, *)
    @Test("A saved capture opens the review panel, off screen here; turning Screencast off closes it, which saves")
    func savedCaptureOpensTheReviewPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastReview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screencast, .clipboardHistory, .screenshotTools], missing: nil, root: root)
        harness.model.start()
        let module = Self.module(of: harness)
        let folder = root.appendingPathComponent("captures/1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("screenshot-1.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!.write(to: file)
        let screenshot = ScreencastScreenshot(folder: folder, images: [.init(file: file, pixelWidth: 1, pixelHeight: 1)])

        module.review.captureStarting()
        module.review.captureFinished(.screenshot(screenshot))
        try await Self.waitUntil { module.review.panel?.isShown == true }
        let panel = try #require(module.review.panel)
        let model = try #require(panel.model)
        #expect(!panel.panel.isVisible, "never on screen under the unit-test host")
        #expect(model.input == .screenshot(screenshot))
        #expect(model.context == .none, "the unit-test host's reader reads nothing")
        #expect(model.showsAddToScreenshots && model.canEdit, "Clipboard History and Screenshot Tools are on")

        harness.model.setCapability(.screencast, enabled: false)
        try await Self.waitUntil { !panel.isShown }
        #expect(ScreencastReview.read(from: screenshot.metadataURL) != nil, "closing saved it")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @available(macOS 15, *)
    @Test("Without Clipboard History or Screenshot Tools, the review panel offers no ⌘3 switch and no Edit")
    func reviewPanelFollowsOtherPlugins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastReviewOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.screencast], missing: nil, root: root)
        harness.model.start()
        let module = Self.module(of: harness)
        let folder = root.appendingPathComponent("captures/1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("screenshot-1.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!.write(to: file)
        module.review.captureFinished(.screenshot(ScreencastScreenshot(folder: folder, images: [.init(file: file, pixelWidth: 1, pixelHeight: 1)])))
        try await Self.waitUntil { module.review.panel?.isShown == true }
        let model = try #require(module.review.panel?.model)
        #expect(!model.showsAddToScreenshots && !model.canEdit)
        await module.review.panel?.close()
    }

    @available(macOS 15, *)
    @Test("Through the module, a screenshot taken with the picker reaches the review panel once")
    func screenshotReachesTheReviewOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastOnce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreencastOnce-\(UUID().uuidString)"))
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("history.json"), pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true), sourceApps: .inert
        )
        let module = ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            seams: ScreencastSeams(
                captureSystem: FakeCaptureSystem(content: ScreencastScreens.content()),
                pickerSystem: FakePickerSystem(content: ScreencastScreens.content()),
                presenter: FakeOverlays(),
                screens: { PickerScreens.both },
                sleep: { _ in },
                contextReader: .inert
            ),
            review: ScreencastReviewServices(
                clipboard: clipboard,
                isClipboardHistoryOn: { false },
                editor: { nil },
                settings: ScreencastReviewSettings(defaults: InMemoryDefaults()),
                notices: nil,
                repositories: { ScreencastRepositoryMemory(storageURL: root.appendingPathComponent("repositories.json")) }
            )
        )
        module.apply(CapabilityContext(
            enabledCapabilities: [.screencast],
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: DrawingHotKeyBackend()),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
        var outcomes: [ScreencastReviewOutcome] = []
        module.review.onFinish = { outcomes.append($0) }

        module.start()
        let controller = try #require(module.controller)
        let picker = try #require(controller.picker)
        picker.kind = .screenshot
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        controller.confirm()
        try await Self.waitUntil { module.review.panel?.isShown == true }
        let panel = try #require(module.review.panel)
        guard case .screenshot(let screenshot) = panel.model?.input else {
            Issue.record("the panel shows the screenshot")
            return
        }
        defer { try? FileManager.default.removeItem(at: screenshot.folder) }
        #expect(controller.phase == .idle)

        await panel.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(outcomes == [.saved(.screenshot(screenshot))], "once, and saved")
        #expect(!panel.isShown)
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private static func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private static func module(of harness: WiringHarness) -> ScreencastModule {
        harness.model.capabilities.module(for: .screencast) as! ScreencastModule
    }

    // MARK: Settings attention

    @Test("Its page needs attention while it's on without Screen Recording, and only then")
    func attention() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreencastAttention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = WiringHarness(enabled: [.screencast], missing: .screenRecording, root: root)
        missing.model.start()
        #expect(missing.model.settingsAttentionCount(for: .screencast) == 1)
        #expect(missing.model.missingPermissions(for: .screencast) == [.screenRecording])

        let noMicrophone = WiringHarness(enabled: [.screencast], missing: .microphone, root: root)
        noMicrophone.model.start()
        #expect(noMicrophone.model.settingsAttentionCount(for: .screencast) == 0, "The Microphone is optional")

        let off = WiringHarness(enabled: [], missing: .screenRecording, root: root)
        off.model.start()
        #expect(off.model.settingsAttentionCount(for: .screencast) == 0)
    }
}
