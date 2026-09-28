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
        criticalOperations: []
    )
}

/// Owns the Quick Search shortcut and the Search tab.
@MainActor
final class QuickSearchModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.quickSearch
    private let palette: CommandPaletteController

    init(palette: CommandPaletteController) {
        self.palette = palette
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.quickSearch.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .quickSearch)
        ) { [weak palette] in
            palette?.toggle(.search)
        }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .search)
    }
}
