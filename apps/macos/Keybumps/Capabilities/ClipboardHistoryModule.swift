import SwiftUI

extension CapabilityDescriptor {
    static let clipboardHistory = CapabilityDescriptor(
        capability: .clipboardHistory,
        title: "Clipboard History",
        systemImage: "clipboard",
        iconTint: .orange,
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
            summary: "Search text and images you copied earlier and paste them again.",
            disableExplanation: "Turning this off stops clipboard monitoring, closes its panel, and releases its global shortcut.",
            content: { AnyView(ClipboardSettingsView()) }
        ),
        criticalOperations: [],
        searchKeywords: ["copy", "copied", "paste"]
    )
}

/// Owns clipboard monitoring, the Clipboard History shortcut, and the Clipboard tab.
@MainActor
final class ClipboardHistoryModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.clipboardHistory
    private let clipboard: ClipboardHistoryService
    private let palette: CommandPaletteController

    init(clipboard: ClipboardHistoryService, palette: CommandPaletteController) {
        self.clipboard = clipboard
        self.palette = palette
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.clipboardHistory.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .clipboardHistory)
        ) { [weak palette] in
            palette?.toggle(.clipboard)
        }
        context.isEnabled(capability) ? clipboard.start() : clipboard.stop()
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .clipboard)
        clipboard.stop()
    }
}
