import SwiftUI

extension CapabilityDescriptor {
    static let dictation = CapabilityDescriptor(
        capability: .dictation,
        title: "Dictation",
        systemImage: "waveform",
        iconTint: .blue,
        requiredPermissions: [.microphone, .speechRecognition],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .dictation,
            name: "Dictation",
            commandKey: 4,
            systemImage: "waveform",
            prompt: "Search dictation history",
            primaryActionTitle: "Copy",
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .dictation,
            summary: "Speech to text anywhere, transcribed on this Mac.",
            disableExplanation: "Turning this off cancels active Dictation and releases its global shortcut.",
            content: { AnyView(DictationSettingsView()) }
        ),
        criticalOperations: []
    )
}

enum DictationEscapeRegistration {
    static let ownerID = "dictation.cancel"

    static func shouldRegister(for phase: DictationPhase) -> Bool {
        phase == .recording || phase == .transcribing
    }
}

/// Owns the Dictation shortcut, the cancellable-phase Escape shortcut, the recording indicator,
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
            self.indicator.update(phase)
            self.updateEscapeRegistration(for: phase)
            self.updateSafety.update(dictationPhase: phase)
        }
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.dictation.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .dictation)
        ) { [weak self] in
            self?.onShortcut?()
        }
    }

    func deactivate(_ context: CapabilityContext) {
        dictation.cancel()
        shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
    }

    private func updateEscapeRegistration(for phase: DictationPhase) {
        guard DictationEscapeRegistration.shouldRegister(for: phase) else {
            shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
            return
        }
        shortcuts.register(
            owner: DictationEscapeRegistration.ownerID,
            binding: DefaultShortcut.cancelDictation
        ) { [weak dictation] in
            dictation?.cancel()
        }
    }
}
