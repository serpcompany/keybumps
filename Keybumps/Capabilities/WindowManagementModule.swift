import SwiftUI

extension CapabilityDescriptor {
    static let windowManagement = CapabilityDescriptor(
        capability: .windowManagement,
        title: "Window Management",
        systemImage: "rectangle.split.2x1",
        requiredPermissions: [.accessibility],
        dependencies: [],
        paletteTab: nil,
        settingsPage: CapabilitySettingsPage(
            section: .windows,
            disableExplanation: "Turning this off stops drag-to-snap and releases all window shortcuts.",
            content: { AnyView(WindowSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: [.windowAction, .windowDrag]
    )
}
