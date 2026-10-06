import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// #290: Cancel Dictation is a Settings command, Esc by default, active only while Dictation can
/// be cancelled.
@MainActor
@Suite struct DictationCancelShortcutTests {
    @Test func dictationsCommandsAreNamedAndCancelDefaultsToEscape() {
        #expect(CapabilityShortcut.dictation.title == "Start & Stop Dictation")
        #expect(CapabilityShortcut.cancelDictation.title == "Cancel Dictation")
        #expect(CapabilityShortcut.cancelDictation.capability == .dictation)
        #expect(CapabilityShortcut.cancelDictation.defaultBinding == DefaultShortcut.cancelDictation)
        #expect(CapabilityShortcut.cancelDictation.detail != nil)
        #expect(CapabilityDescriptor.dictation.shortcuts == [.dictation, .cancelDictation])
    }

    @Test func theDefaultCancelShortcutShowsAsTheEscapeKeycap() {
        let name = DefaultShortcut.cancelDictation.displayName
        #expect(KeyboardShortcutRegistry.keycapTokens(for: name) == ["⎋"])
        #expect(KeyboardShortcutRegistry.keycapTokens(for: "Esc") == ["⎋"])
        #expect(KeyboardShortcutRegistry.accessibilityDescription(for: name)?.contains("Escape") == true)
    }

    @Test func voiceOverNamesTheCancelShortcutInUseOrNone() {
        #expect(DictationNotchView.recordingLabel(finish: "⌥ Space", cancel: "Escape")
            .hasSuffix("or Escape (Esc) to cancel."))
        #expect(!DictationNotchView.recordingLabel(finish: "⌥ Space", cancel: nil).contains("cancel"))
        #expect(DictationNotchView.recordingLabel(finish: nil, cancel: nil) == "Dictation recording.")
    }

    @Test func thePluginsTableDoesNotShowEscapeAsDictationsShortcut() {
        let text = PluginsTable.shortcutText(for: .dictation) { shortcut in
            shortcut == .cancelDictation ? DefaultShortcut.cancelDictation : nil
        }

        #expect(text == "")
    }

    @Test func anExistingInstallGetsEscapeForCancelDictation() throws {
        let defaults = InMemoryDefaults()
        // Saved before Cancel Dictation existed: only the original shortcuts are known.
        defaults.set(
            try JSONEncoder().encode(["dictation": DefaultShortcut.dictation]),
            forKey: "capabilityShortcuts"
        )

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.capabilityShortcut(for: .cancelDictation) == DefaultShortcut.cancelDictation)
    }

    @Test func cancelIsRegisteredOnlyWhileDictationCanBeCancelled() {
        let fixture = Fixture()
        fixture.apply()
        #expect(fixture.backend.registered.isEmpty == false)
        #expect(!fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))

        fixture.dictation.onPhaseChange?(.recording)
        #expect(fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))

        fixture.dictation.onPhaseChange?(.transcribing)
        #expect(fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))

        fixture.dictation.onPhaseChange?(.idle)
        #expect(!fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))
    }

    @Test func cancelUsesTheOwnersBinding() {
        let fixture = Fixture()
        let custom = ShortcutBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey), displayName: "⌘.")
        fixture.preferences.setCapabilityShortcut(custom, for: .cancelDictation)
        fixture.apply()

        fixture.dictation.onPhaseChange?(.recording)

        #expect(fixture.backend.registered.values.contains(custom))
        #expect(!fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))
    }

    @Test func aClearedCancelShortcutIsNeverRegistered() {
        let fixture = Fixture()
        fixture.preferences.setCapabilityShortcut(nil, for: .cancelDictation)
        fixture.apply()

        let before = fixture.backend.registered.count
        fixture.dictation.onPhaseChange?(.recording)

        #expect(fixture.backend.registered.count == before)
    }

    @Test func changingTheBindingMidRecordingTakesEffect() {
        let fixture = Fixture()
        fixture.apply()
        fixture.dictation.onPhaseChange?(.recording)
        let custom = ShortcutBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey), displayName: "⌘.")

        fixture.preferences.setCapabilityShortcut(custom, for: .cancelDictation)
        fixture.apply()

        #expect(fixture.backend.registered.values.contains(custom))
        #expect(!fixture.backend.registered.values.contains(DefaultShortcut.cancelDictation))
    }
}

@MainActor
private final class Fixture {
    let backend = RecordingHotKeys()
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let dictation = DictationService(language: "en-US", history: DictationHistoryService(
        recordingsDirectoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCancelShortcut-\(UUID().uuidString)", isDirectory: true)
    ))
    let shortcuts: GlobalShortcutCoordinator
    let module: DictationModule

    init() {
        shortcuts = GlobalShortcutCoordinator(backend: backend)
        module = DictationModule(
            dictation: dictation,
            indicator: SilentIndicator(),
            shortcuts: shortcuts,
            updateSafety: CapabilityUpdateSafety(
                policy: UpdateInstallationSafetyPolicy(),
                updater: DisabledUpdateController(reason: "tests"),
                descriptor: .dictation
            )
        )
    }

    func apply() {
        module.apply(CapabilityContext(
            enabledCapabilities: [.dictation],
            preferences: preferences,
            shortcuts: shortcuts,
            permissions: PermissionCoordinator(
                accessibilityTrusted: { true },
                inputMonitoringAuthorized: { true },
                microphoneAuthorizationStatus: { .authorized },
                speechAuthorizationStatus: { .authorized },
                screenRecordingAuthorized: { true },
                requestScreenRecording: {},
                openSettings: { _ in }
            ),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
    }
}

@MainActor
private final class RecordingHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private(set) var registered: [UInt32: ShortcutBinding] = [:]

    func installHandler(_ handler: @escaping (UInt32) -> Void) {}

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        registered[identifier] = binding
        return true
    }

    func unregister(identifier: UInt32) {
        registered[identifier] = nil
    }
}

/// Never shows the recording panel, so tests stay off the screen.
private final class SilentIndicator: DictationIndicatorController {
    override func update(_ phase: DictationPhase) {}
}
