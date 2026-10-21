import SwiftUI

/// A plugin's folder in the Keybumps folder (ADR 0013), on its Settings page, or the Keybumps folder
/// itself on Settings › General: the path as Finder's Go to Folder takes it, with Show in Finder,
/// which makes the folder first if it isn't there yet. Choosing another folder is #603.
struct KeybumpsFolderRow: View {
    /// Nil for the Keybumps folder itself.
    let capability: Capability?

    init(_ capability: Capability? = nil) {
        self.capability = capability
    }

    var body: some View {
        let folder = Self.folder(for: capability, in: .keybumps())
        LabeledContent {
            Button("Show in Finder") { ScreengrabFolderRow.show(folder) }
                .accessibilityIdentifier(Self.identifier(capability))
        } label: {
            SettingsRowLabel(title: Self.title(capability), subtitle: ScreengrabFolderRow.displayPath(folder))
        }
    }

    static func title(_ capability: Capability?) -> String {
        "\(capability?.title ?? "Keybumps") folder"
    }

    /// The folder each plugin's files are in this launch (`ProductPaths.inUse`): its own folder, or
    /// the old one where this launch's move left them. A plugin without one shows the Keybumps folder.
    static func folder(for capability: Capability?, in paths: ProductPaths) -> URL {
        switch capability {
        case .dictation: paths.inUse(.dictationHistory)
        case .clipboardHistory: paths.inUse(.clipboardHistory).deletingLastPathComponent()
        case .translation: paths.inUse(.recentTranslations).deletingLastPathComponent()
        case .snippets: paths.inUse(.snippets).deletingLastPathComponent()
        case .keyboardShortcutter: paths.inUse(.coachingEvents).deletingLastPathComponent()
        default: paths.keybumpsFolder
        }
    }

    static func identifier(_ capability: Capability?) -> String {
        capability.map { "plugin.\($0.rawValue).showFolder" } ?? "settings.general.showKeybumpsFolder"
    }
}
