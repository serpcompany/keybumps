import SwiftUI

extension CapabilityDescriptor {
    static let dictation = CapabilityDescriptor(
        capability: .dictation,
        title: "Dictation",
        systemImage: "waveform",
        iconTint: .blue,
        // Accessibility lets Dictation post ⌘V to paste the transcript at the original cursor.
        requiredPermissions: [.accessibility, .microphone, .speechRecognition],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .dictation,
            name: "Dictation",
            commandKey: 4,
            systemImage: "waveform",
            prompt: "Search dictation history",
            primaryActionTitle: "Copy",
            secondaryActions: [.paste()],
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .dictation,
            summary: "Speech to text anywhere, transcribed on this Mac.",
            disableExplanation: "Turning this off cancels active Dictation and releases its global shortcut.",
            content: { AnyView(DictationSettingsView()) }
        ),
        criticalOperations: [],
        searchKeywords: [
            "dictate", "voice", "speech", "transcribe", "transcription", "transcript", "recording", "recordings", "history"
        ],
        category: .writing,
        preferences: [.dictationRestoresClipboard]
    )
}

extension PluginPreference {
    static let dictationRestoresClipboard = PluginPreference(
        key: "restoresClipboard",
        title: "Put the clipboard back after inserting",
        subtitle: "Dictation inserts your words through the clipboard. With this on, what you’d copied before comes back once they’re in, unless you copy something else first. Off, the transcript stays on the clipboard.",
        group: "Inserting",
        kind: .toggle(default: true)
    )
}

enum DictationSetupCopy {
    /// The Dictation page's "Setup required" note, naming only the missing permissions.
    static func settingsNote(missing: [MacPermission]) -> String {
        "Dictation needs \(MacPermission.names(missing)) access before its shortcut can record and paste."
    }
}

enum DictationEscapeRegistration {
    static let ownerID = "dictation.cancel"

    static func shouldRegister(for phase: DictationPhase) -> Bool {
        phase == .recording || phase == .transcribing
    }
}

/// Owns the Dictation shortcut, the cancellable-phase Cancel Dictation shortcut, the recording indicator,
/// and Dictation's phase report to update-installation safety.
@MainActor
final class DictationModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.dictation
    private let dictation: DictationService
    private let indicator: DictationIndicatorController
    private let shortcuts: GlobalShortcutCoordinator
    private let updateSafety: CapabilityUpdateSafety
    /// Set by the shell, which routes the shortcut to Dictation or to its permission setup.
    var onShortcut: (() -> Void)?
    /// Cancel Dictation's binding from preferences; Esc unless the owner changed or cleared it.
    private var cancelBinding: ShortcutBinding? = DefaultShortcut.cancelDictation
    /// The last phase Dictation reported, for re-registering Cancel when its binding changes.
    private var phase: DictationPhase = .idle
    private var isEnabled = true

    init(
        dictation: DictationService,
        indicator: DictationIndicatorController,
        shortcuts: GlobalShortcutCoordinator,
        updateSafety: CapabilityUpdateSafety
    ) {
        self.dictation = dictation
        self.indicator = indicator
        self.shortcuts = shortcuts
        self.updateSafety = updateSafety
        dictation.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.phase = phase
            self.indicator.update(phase)
            self.updateEscapeRegistration(for: phase)
            self.updateSafety.update(dictationPhase: phase)
        }
        dictation.onInputLevel = { [weak indicator] level in indicator?.updateLevel(level) }
    }

    func apply(_ context: CapabilityContext) {
        indicator.finishShortcut = context.preferences.capabilityShortcut(for: .dictation)?.displayName
        // Cancel Dictation is registered only while Dictation is cancellable, and re-registered
        // only when its binding or Dictation's on/off state changes.
        let binding = context.preferences.capabilityShortcut(for: .cancelDictation)
        indicator.cancelShortcut = binding?.displayName
        let enabled = context.isEnabled(capability)
        if binding != cancelBinding || enabled != isEnabled {
            cancelBinding = binding
            isEnabled = enabled
            updateEscapeRegistration(for: phase)
        }
        context.configureShortcut(
            owner: CapabilityShortcut.dictation.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .dictation)
        ) { [weak self] in
            self?.onShortcut?()
        }
    }

    func deactivate(_ context: CapabilityContext) {
        isEnabled = false
        dictation.cancel()
        shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
    }

    private func updateEscapeRegistration(for phase: DictationPhase) {
        guard isEnabled, DictationEscapeRegistration.shouldRegister(for: phase), let cancelBinding else {
            shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
            return
        }
        shortcuts.register(
            owner: DictationEscapeRegistration.ownerID,
            binding: cancelBinding
        ) { [weak dictation] in
            dictation?.cancel()
        }
    }
}
