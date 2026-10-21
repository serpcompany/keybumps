import AppKit
import SwiftUI

/// The Keybumps folder (ADR 0013) on Settings › General: the path as Finder's Go to Folder takes it,
/// with Show in Finder, which makes the folder first if it isn't there yet. Each plugin's files are
/// in a folder of its own there. Choosing another folder is #603.
struct KeybumpsFolderRow: View {
    var body: some View {
        let folder = ProductPaths.keybumps().keybumpsFolder
        LabeledContent {
            Button("Show in Finder") { Self.show(folder) }
                .accessibilityIdentifier("settings.general.showKeybumpsFolder")
        } label: {
            SettingsRowLabel(title: "Keybumps folder", subtitle: Self.displayPath(folder))
        }
    }

    /// The folder as people type it in Finder's Go to Folder, such as `~/Library/Application Support/Keybumps`.
    static func displayPath(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Opens the folder in Finder, making it first if it isn't there. Inert under the unit-test host.
    static func show(_ folder: URL) {
        guard !UnitTestHost.isActive else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
