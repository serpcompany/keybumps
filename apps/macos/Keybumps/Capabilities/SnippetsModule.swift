import SwiftUI

extension CapabilityDescriptor {
    static let snippets = CapabilityDescriptor(
        capability: .snippets,
        title: "Snippets",
        systemImage: "text.quote",
        iconTint: .green,
        // Copying needs no permission. ⌘Return's paste uses Accessibility when it's granted and
        // copies otherwise, so Accessibility is optional here and never counts as missing.
        requiredPermissions: [],
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
/// the shell's `SnippetStore`; nothing runs in the background. Its Settings attention is a library
/// that can't be read, never a permission.
@MainActor
final class SnippetsModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.snippets
    private let palette: CommandPaletteController
    private let snippets: SnippetStore

    init(palette: CommandPaletteController, snippets: SnippetStore) {
        self.palette = palette
        self.snippets = snippets
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

    func attentionCount(_ context: CapabilityContext) -> Int {
        context.isEnabled(capability) && snippets.libraryState == .readOnly ? 1 : 0
    }
}
