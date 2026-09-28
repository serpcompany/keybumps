import SwiftUI

extension CapabilityDescriptor {
    static let keyboardShortcutter = CapabilityDescriptor(
        capability: .keyboardShortcutter,
        title: "Keyboard Shortcutter",
        systemImage: "keyboard",
        requiredPermissions: [.accessibility, .inputMonitoring],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .keyboardShortcutter,
            name: "Hotkeys",
            commandKey: 4,
            systemImage: "keyboard",
            prompt: "Search hotkeys",
            primaryActionTitle: nil,
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .keyboardShortcutter,
            disableExplanation: nil,
            content: { AnyView(KeyboardShortcutterSettingsView()) }
        ),
        showsOnboardingCard: true,
        criticalOperations: []
    )
}

/// Owns the manual-action detector and its presentations. Its Settings attention is its own
/// missing permissions, including native notification authorization when that channel is selected.
@MainActor
final class KeyboardShortcutterModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.keyboardShortcutter
    private let detector: ManualActionDetector
    private let presenter: PresentationWindowController

    init(detector: ManualActionDetector, presenter: PresentationWindowController) {
        self.detector = detector
        self.presenter = presenter
    }

    func apply(_ context: CapabilityContext) {
        context.isEnabled(capability) ? detector.start() : detector.stop()
    }

    func deactivate(_ context: CapabilityContext) {
        detector.stop()
        presenter.dismissAll()
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
