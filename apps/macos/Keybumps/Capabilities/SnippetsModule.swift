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
        criticalOperations: [],
        searchKeywords: ["snippet", "snip"],
        category: .writing
    )
}

/// Owns the optional Open Snippets shortcut, the Snippets tab, and keyword auto-expansion. The
/// snippets themselves live in the shell's `SnippetStore`. Nothing runs in the background unless
/// Settings' Expand keywords as you type is on (`KeywordExpansionController`). Its Settings
/// attention is a library that can't be read, and, while that switch is on, a missing Input
/// Monitoring or Accessibility permission.
@MainActor
final class SnippetsModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.snippets
    private let palette: CommandPaletteController
    private let snippets: SnippetStore
    private let expansion: KeywordExpansionController

    init(palette: CommandPaletteController, snippets: SnippetStore, expansion: KeywordExpansionController) {
        self.palette = palette
        self.snippets = snippets
        self.expansion = expansion
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.snippets.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .snippets)
        ) { [weak palette] in
            palette?.toggle(.snippets)
        }
        updateExpansion(context)
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .snippets)
        expansion.update(listening: false)
    }

    func permissionsDidRefresh(_ context: CapabilityContext) {
        updateExpansion(context)
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        let unreadable = snippets.libraryState == .readOnly ? 1 : 0
        return unreadable + Self.missingExpansionPermissions(context).count
    }

    /// The permissions keyword expansion still needs while its switch is on.
    static func missingExpansionPermissions(_ context: CapabilityContext) -> [MacPermission] {
        guard context.preferences.expandsSnippetKeywords else { return [] }
        var missing: [MacPermission] = []
        if !context.permissions.inputMonitoringGranted { missing.append(.inputMonitoring) }
        if !context.permissions.accessibilityGranted { missing.append(.accessibility) }
        return missing
    }

    private func updateExpansion(_ context: CapabilityContext) {
        expansion.update(listening: KeywordExpansionController.shouldListen(
            snippetsOn: context.isEnabled(capability),
            switchOn: context.preferences.expandsSnippetKeywords,
            inputMonitoring: context.permissions.inputMonitoringGranted,
            accessibility: context.permissions.accessibilityGranted
        ))
    }
}
