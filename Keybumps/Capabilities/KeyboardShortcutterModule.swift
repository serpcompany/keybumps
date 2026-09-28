import SwiftUI

extension CapabilityDescriptor {
    static let keyboardShortcutter = CapabilityDescriptor(
        capability: .keyboardShortcutter,
        title: "Keyboard Shortcutter",
        systemImage: "keyboard",
        requiredPermissions: [.accessibility, .inputMonitoring],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .keyboardShortcutter,
            name: "Hotkeys",
            commandKey: 4,
            systemImage: "keyboard",
            prompt: "Search hotkeys",
            primaryActionTitle: nil,
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .keyboardShortcutter,
            disableExplanation: nil,
            content: { AnyView(KeyboardShortcutterSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: []
    )
}
