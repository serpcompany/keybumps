import SwiftUI

extension CapabilityDescriptor {
    static let dictation = CapabilityDescriptor(
        capability: .dictation,
        title: "Dictation",
        systemImage: "waveform",
        requiredPermissions: [.microphone, .speechRecognition],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .dictation,
            name: "Dictation",
            commandKey: 3,
            systemImage: "waveform",
            prompt: "Search dictation history",
            primaryActionTitle: "Copy",
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .dictation,
            disableExplanation: "Turning this off cancels active Dictation and releases its global shortcut.",
            content: { AnyView(DictationSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: []
    )
}
