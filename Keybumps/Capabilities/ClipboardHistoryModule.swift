import SwiftUI

extension CapabilityDescriptor {
    static let clipboardHistory = CapabilityDescriptor(
        capability: .clipboardHistory,
        title: "Clipboard History",
        systemImage: "clipboard",
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .clipboard,
            name: "Clipboard",
            commandKey: 2,
            systemImage: "clipboard",
            prompt: "Search clipboard history",
            primaryActionTitle: "Copy",
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .clipboard,
            disableExplanation: "Turning this off stops clipboard monitoring, closes its panel, and releases its global shortcut.",
            content: { AnyView(ClipboardSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: []
    )
}
