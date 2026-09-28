import SwiftUI

extension CapabilityDescriptor {
    static let quickSearch = CapabilityDescriptor(
        capability: .quickSearch,
        title: "Quick Search",
        systemImage: "magnifyingglass",
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .search,
            name: "Search",
            commandKey: 1,
            systemImage: "magnifyingglass",
            prompt: "Search apps, files, and folders",
            primaryActionTitle: "Open",
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .search,
            disableExplanation: "Turning this off closes Quick Search and releases its global shortcut.",
            content: { AnyView(QuickSearchSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: []
    )
}
