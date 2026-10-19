import SwiftUI

extension CapabilityDescriptor {
    static let quickSearch = CapabilityDescriptor(
        capability: .quickSearch,
        title: "Quick Search",
        systemImage: "magnifyingglass",
        iconTint: .red,
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .search,
            name: "Search",
            commandKey: 1,
            systemImage: "magnifyingglass",
            prompt: "Search apps, files, and folders",
            primaryActionTitle: "Open",
            secondaryActions: [],
            clickAction: .acts,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .search,
            summary: "Open apps, files, and folders from the keyboard.",
            // No switch, so no tooltip for one: Quick Search is always on (#553).
            disableExplanation: nil,
            content: { AnyView(QuickSearchSettingsView()) }
        ),
        criticalOperations: [],
        // No capability command: Quick Search's own tab is where commands are listed.
        searchKeywords: nil,
        category: .productivity,
        isAlwaysOn: true
    )
}

/// Owns the Quick Search shortcut and the Search tab. It's always on (#553), so its module is
/// deactivated only while Keybumps is Locked.
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
            // On the first shown tab, the Search tab unless Settings › Quick Search hides it (#553).
            guard let palette else { return }
            palette.toggle(palette.openingTab)
        }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .search)
    }
}
