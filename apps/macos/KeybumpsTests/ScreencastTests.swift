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
        #expect(descriptor.shortcuts == [.screencast])
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

    @Test("A saved capture shows its videos to share, or its screenshots")
    func filesShown() {
        let folder = URL(fileURLWithPath: "/captures/1791000000", isDirectory: true)
        let video = ScreencastVideo(
            file: folder.appendingPathComponent("video-1.mov"), mixdown: folder.appendingPathComponent("video-1-mixdown.mp4"),
            pixelWidth: 2, pixelHeight: 2, audioTracks: [.microphone, .systemAudio], duration: 1
        )
        let capture = ScreencastCapture(folder: folder, videos: [video], duration: 1, endedEarly: nil)
        #expect(ScreencastModule.files(of: .video(capture)) == [folder.appendingPathComponent("video-1-mixdown.mp4")])
        let screenshot = ScreencastScreenshot(folder: folder, images: [.init(file: folder.appendingPathComponent("screenshot-1.png"), pixelWidth: 2, pixelHeight: 2)])
        #expect(ScreencastModule.files(of: .screenshot(screenshot)) == [folder.appendingPathComponent("screenshot-1.png")])
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
