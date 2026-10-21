import SwiftUI

/// The rows Settings › ScreenGrabs adds at the end of its Recordings group: where recording isn't
/// supported, a note saying so (`PluginCompatibility.recordingRequirement`); otherwise a note on
/// where recordings are kept (#605), whether ScreenGrabs is on or off. Each reports itself through
/// `ScreenshotsSettings.Shown`.
struct ScreencastCapturesSettings: View {
    @Environment(AppModel.self) private var model

    static let about = "Every recording you keep is saved in the Keybumps folder's screengrabs folder for the ScreenGrabs tab, and a copy of its folder goes where macOS saves screenshots; deleting or moving the copy leaves the recording in ScreenGrabs."

    var body: some View {
        if model.preferences.compatibility.supportsRecording {
            SettingsNote(Self.about)
                .accessibilityIdentifier("plugin.screenshotTools.recordingsAbout")
                .shown(.recordingsAbout)
        } else {
            SettingsNote(PluginCompatibility.recordingRequirement)
                .accessibilityIdentifier("plugin.screenshotTools.recordingRequirement")
                .shown(.recordingRequirement)
        }
    }
}
