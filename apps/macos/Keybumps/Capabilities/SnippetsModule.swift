import SwiftUI

extension CapabilityDescriptor {
    static let snippets = CapabilityDescriptor(
        capability: .snippets,
        title: "Snippets",
        systemImage: "text.quote",
        iconTint: .green,
        // Only ⌘Return's paste needs it: posting ⌘V into another app. Without it, ⌘Return copies.
        requiredPermissions: [.accessibility],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .snippets,
            name: "Snippets",
            commandKey: 5,
            systemImage: "text.quote",
            prompt: "Search snippets",
            primaryActionTitle: "Copy",
            secondaryActionTitle: "Paste",
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .snippets,
            summary: "Save text you reuse, then copy or paste it from the Command Palette.",
            disableExplanation: "Turning this off closes the Snippets tab and releases its global shortcut. Your snippets stay saved on this Mac.",
            content: { AnyView(SnippetsSettingsView()) }
        ),
        criticalOperations: []
    )
}

/// Owns the optional Open Snippets shortcut and the Snippets tab. The snippets themselves live in
/// the shell's `SnippetStore`; nothing runs in the background.
@MainActor
final class SnippetsModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.snippets
    private let palette: CommandPaletteController

    init(palette: CommandPaletteController) {
        self.palette = palette
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.snippets.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .snippets)
        ) { [weak palette] in
            palette?.toggle(.snippets)
        }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .snippets)
    }

    /// Without Accessibility, ⌘Return copies instead of pasting; the page says so.
    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }
}
