import SwiftUI

/// The Keybumps folder (ADR 0013) on Settings › General: the path as Finder's Go to Folder takes it,
/// with Show in Finder, which makes the folder first if it isn't there yet. Each plugin's files are
/// in a folder of its own there. Choosing another folder is #603.
struct KeybumpsFolderRow: View {
    var body: some View {
        let folder = ProductPaths.keybumps().keybumpsFolder
        LabeledContent {
            Button("Show in Finder") { ScreengrabFolderRow.show(folder) }
                .accessibilityIdentifier("settings.general.showKeybumpsFolder")
        } label: {
            SettingsRowLabel(title: "Keybumps folder", subtitle: ScreengrabFolderRow.displayPath(folder))
        }
    }
}
