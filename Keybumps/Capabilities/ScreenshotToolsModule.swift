import SwiftUI

extension CapabilityDescriptor {
    static let screenshotTools = CapabilityDescriptor(
        capability: .screenshotTools,
        title: "Screenshot Tools",
        systemImage: "camera.viewfinder",
        requiredPermissions: [],
        dependencies: [.clipboardHistory],
        paletteTab: CapabilityPaletteTab(
            tab: .screenshots,
            name: "Screenshots",
            commandKey: 5,
            systemImage: "camera.viewfinder",
            prompt: "Search screenshots",
            primaryActionTitle: "Edit",
            secondaryActionTitle: "Copy",
            dataSource: .clipboardHistory
        ),
        settingsPage: CapabilitySettingsPage(
            section: .screenshotTools,
            disableExplanation: "Turning this off stops adding new screenshots to Clipboard History. Screenshots already there stay until removed.",
            content: { AnyView(ScreenshotToolsSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: [.unsavedWork]
    )
}
