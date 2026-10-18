import SwiftUI

/// The rows Settings › ScreenGrabs adds at the end of its Recordings group: where recording isn't
/// supported, a note saying so (`PluginCompatibility.recordingRequirement`); otherwise the
/// Recordings folder (`ScreengrabFolderRow`), with Show in Finder and Choose…, whether ScreenGrabs
/// is on or off. Each reports itself through `ScreenshotsSettings.Shown`.
struct ScreencastCapturesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.preferences.compatibility.supportsRecording {
            ScreengrabFolderRow(kind: .recordings)
        } else {
            SettingsNote(PluginCompatibility.recordingRequirement)
                .accessibilityIdentifier("plugin.screenshotTools.recordingRequirement")
                .shown(.recordingRequirement)
        }
    }
}
