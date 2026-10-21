import AppKit
import SwiftUI

/// One of ScreenGrabs' save folders on Settings › ScreenGrabs (#504): the Screenshots folder in the
/// Screenshots group, the Recordings folder in the Recordings group. It shows the folder it saves in
/// now, with Show in Finder, and Choose…, which opens a folder panel and stores the folder picked
/// (`AppPreferences.chooseScreengrabFolder`). Each reports itself through `ScreenshotsSettings.Shown`.
struct ScreengrabFolderRow: View {
    @Environment(AppModel.self) private var model
    let kind: ScreengrabFolders.Kind

    var body: some View {
        let folders = model.preferences.screengrabFolders
        let folder = folders.folder(for: kind)
        LabeledContent {
            HStack(spacing: 8) {
                Button("Show in Finder") { Self.show(folder) }
                    .accessibilityIdentifier(Self.showIdentifier(kind))
                Button("Choose…") {
                    let preferences = model.preferences
                    ScreengrabFolderPanel.choose(kind, startingIn: folder) { preferences.chooseScreengrabFolder($0, for: kind) }
                }
                .accessibilityIdentifier("plugin.screenshotTools.choose.\(kind.rawValue)")
            }
        } label: {
            SettingsRowLabel(title: Self.title(kind), subtitle: Self.subtitle(kind, in: folders))
        }
        .shown(kind == .screenshots ? .screenshotsFolder : .recordingsFolder)
    }

    static func title(_ kind: ScreengrabFolders.Kind) -> String {
        switch kind {
        case .screenshots: "Screenshots folder"
        case .recordings: "Recordings folder"
        }
    }

    /// Where `kind` saves now: the folder chosen, or the default, said to be where macOS saves
    /// screenshots, or, while the folder chosen can't be used, the default until it can.
    static func subtitle(_ kind: ScreengrabFolders.Kind, in folders: ScreengrabFolders) -> String {
        let path = displayPath(folders.folder(for: kind))
        guard let chosen = folders.chosen[kind] else { return "\(path), where macOS saves screenshots" }
        return folders.choiceIsUnavailable(for: kind) ? "Saving to \(path) until \(displayPath(chosen)) is available" : path
    }

    /// The folder as people type it in Finder's Go to Folder, such as `~/Desktop`.
    static func displayPath(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Show in Finder's identifier. The Recordings folder's keeps Screencast's, which the UI tests use.
    private static func showIdentifier(_ kind: ScreengrabFolders.Kind) -> String {
        switch kind {
        case .screenshots: "plugin.screenshotTools.show.screenshots"
        case .recordings: "plugin.screencast.showCaptures"
        }
    }

    /// Opens the folder in Finder, making it first if it isn't there. Inert under the unit-test host.
    /// `KeybumpsFolderRow` shares it.
    static func show(_ folder: URL) {
        guard !UnitTestHost.isActive else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// The folder panel Choose… opens: folders only, starting in the folder in use, as a sheet on the
/// window in front (Settings). It never opens under the unit-test host.
@MainActor
enum ScreengrabFolderPanel {
    static func choose(_ kind: ScreengrabFolders.Kind, startingIn folder: URL, chosen: @escaping @MainActor (URL) -> Void) {
        guard !UnitTestHost.isActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        panel.message = kind == .screenshots
            ? "Choose where ScreenGrabs saves screenshots."
            : "Choose where ScreenGrabs saves recordings."
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { chosen(url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
