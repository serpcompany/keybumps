import SwiftUI

extension CapabilityDescriptor {
    static let keyboardShortcutter = CapabilityDescriptor(
        capability: .keyboardShortcutter,
        title: "Shortcut Coach",
        systemImage: "keyboard",
        iconTint: .gray,
        requiredPermissions: [.accessibility, .inputMonitoring],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .keyboardShortcutter,
            name: "Hotkeys",
            // Hidden by default, so it follows Snippets (⌘5) and the visible tabs stay ⌘1–⌘5.
            commandKey: 6,
            systemImage: "keyboard",
            prompt: "Search hotkeys",
            primaryActionTitle: nil,
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .keyboardShortcutter,
            summary: "Learn the shortcuts for actions you do by hand.",
            disableExplanation: nil,
            content: { AnyView(KeyboardShortcutterSettingsView()) }
        ),
        criticalOperations: [],
        searchKeywords: ["hotkeys", "hotkey", "shortcuts", "keyboard", "history"]
    )
}

/// Owns the manual-action detector and the Hotkeys tab's rows. Its Settings attention is its own
/// missing permissions.
@MainActor
final class KeyboardShortcutterModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.keyboardShortcutter
    private let detector: ManualActionDetector
    let paletteContent: (any CapabilityPaletteContent)?

    init(detector: ManualActionDetector, inbox: InboxStore, preferences: AppPreferences) {
        self.detector = detector
        paletteContent = KeyboardShortcutterPaletteContent(inbox: inbox, preferences: preferences)
    }

    func apply(_ context: CapabilityContext) {
        context.isEnabled(capability) ? detector.start() : detector.stop()
    }

    func deactivate(_ context: CapabilityContext) {
        detector.stop()
        PaletteHUD.shared.dismissCoach()
    }

    func permissionsDidRefresh(_ context: CapabilityContext) {
        if context.isEnabled(capability), detector.status != .monitoring {
            detector.start()
        }
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }
}
