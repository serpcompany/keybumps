import SwiftUI

extension CapabilityDescriptor {
    static let screencast = CapabilityDescriptor(
        capability: .screencast,
        title: "Screencast",
        systemImage: "record.circle",
        iconTint: .red,
        requiredPermissions: [.screenRecording],
        dependencies: [],
        // ⌘1–⌘9 are taken; whether it gets a tab is open (ADR 0009).
        paletteTab: nil,
        settingsPage: CapabilitySettingsPage(
            section: .screencast,
            summary: "Record your screen with your voice and the Mac’s sound, and keep each capture on this Mac.",
            disableExplanation: "Turning this off releases its global shortcut. Captures already saved stay on this Mac.",
            content: { AnyView(PluginSettingsPage(capability: .screencast) { ScreencastCapturesSettings() }) }
        ),
        criticalOperations: [],
        searchKeywords: ["screen recording", "record", "recorder", "video", "capture"],
        category: .media,
        preferences: [
            .screencastRecordsMicrophone, .screencastRecordsSystemAudio,
            .screencastCountdown, .screencastShowsShortcuts, .screencastHighlightsClicks,
        ],
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .microphone,
                reason: "Records your voice with a video. Without it, videos have only the screen and the Mac’s sound."
            ),
        ],
        isOnByDefault: false,
        minimumMacOS: 15
    )
}

/// Owns Screencast (ADR 0009) and its optional Start Screencast shortcut. It ships off, and needs
/// macOS 15 (`minimumMacOS`), where ScreenCaptureKit records the screen, the microphone, and the
/// Mac's sound in one stream. Its own code is under `Screencast/`, and its settings are read
/// through `AppPreferences.screencast`. Nothing records yet (#446, #447), so Start Screencast opens
/// its Settings page.
@MainActor
final class ScreencastModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.screencast
    /// Opens Settings on a page; tests replace it.
    private let openSettings: @MainActor (SettingsSection) -> Void

    init(openSettings: @escaping @MainActor (SettingsSection) -> Void) {
        self.openSettings = openSettings
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.screencast.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .screencast)
        ) { [weak self] in
            self?.start()
        }
    }

    func deactivate(_ context: CapabilityContext) {}

    /// Settings attention while it's on and Screen Recording isn't granted.
    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    /// What Start Screencast does: for now, shows Screencast's page, where it's set up.
    func start() {
        openSettings(.screencast)
    }
}
