import AppKit
import SwiftUI

/// Screencast's page's own part, below its preferences: the folder captures are saved in, and a
/// button that opens it in Finder. It works whether Screencast is on or off.
struct ScreencastCapturesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folder = model.preferences.screencast.capturesFolder
        SettingsGroup("Captures", subtitle: "Each capture is kept on this Mac, in a folder of its own.") {
            LabeledContent {
                Button("Show in Finder") { Self.show(folder) }
                    .accessibilityIdentifier("plugin.screencast.showCaptures")
            } label: {
                SettingsRowLabel(title: "Captures folder", subtitle: Self.displayPath(folder))
            }
        }
    }

    /// The folder as people type it in Finder's Go to Folder, such as `~/Documents/Keybumps/captures`.
    static func displayPath(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the folder in Finder, making it first while nothing has been captured. Inert under the
    /// unit-test host.
    private static func show(_ folder: URL) {
        guard !UnitTestHost.isActive else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
