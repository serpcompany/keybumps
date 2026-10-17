import AppKit
import SwiftUI

/// The rows Settings › Screengrabs adds at the end of its Recordings group: where recording isn't
/// supported, a note saying so (`PluginCompatibility.recordingRequirement`); otherwise the folder
/// recordings are saved in, and a button that opens it in Finder, whether Screengrabs is on or off.
/// Each reports itself through `ScreenshotsSettings.Shown`.
struct ScreencastCapturesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.preferences.compatibility.supportsRecording {
            let folder = model.preferences.screencast.capturesFolder
            LabeledContent {
                Button("Show in Finder") { Self.show(folder) }
                    .accessibilityIdentifier("plugin.screencast.showCaptures")
            } label: {
                SettingsRowLabel(title: "Recordings folder", subtitle: Self.displayPath(folder))
            }
            .shown(.recordingsFolder)
        } else {
            SettingsNote(PluginCompatibility.recordingRequirement)
                .accessibilityIdentifier("plugin.screenshotTools.recordingRequirement")
                .shown(.recordingRequirement)
        }
    }

    /// The folder as people type it in Finder's Go to Folder, such as `~/Documents/Keybumps/captures`.
    static func displayPath(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the folder in Finder, making it first while nothing has been recorded. Inert under the
    /// unit-test host.
    private static func show(_ folder: URL) {
        guard !UnitTestHost.isActive else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
