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

/// Owns the window shortcuts and drag-to-snap, and reports window actions and drags to
/// update-installation safety.
@MainActor
final class WindowManagementModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.windowManagement
    private let windows: WindowManagementService
    private let updateSafety: CapabilityUpdateSafety

    init(windows: WindowManagementService, updateSafety: CapabilityUpdateSafety) {
        self.windows = windows
        self.updateSafety = updateSafety
        windows.onDragActivityChange = { isActive in
            updateSafety.setCriticalOperation(.windowDrag, active: isActive)
        }
    }

    func apply(_ context: CapabilityContext) {
        for action in WindowAction.allCases {
            context.configureShortcut(
                owner: "window.\(action.rawValue)",
                for: capability,
                binding: context.preferences.windowShortcut(for: action)
            ) { [weak self] in
                self?.perform(action)
            }
        }
        context.isEnabled(capability) ? windows.startDragSnapping() : windows.stop()
    }

    func deactivate(_ context: CapabilityContext) {
        windows.stop()
    }

    func permissionsDidRefresh(_ context: CapabilityContext) {
        if context.isEnabled(capability), context.permissions.accessibilityGranted {
            windows.startDragSnapping()
        }
    }

    private func perform(_ action: WindowAction) {
        updateSafety.performSynchronously(.windowAction) { windows.perform(action) }
    }
}
