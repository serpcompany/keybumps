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

    /// Each plugin's own folder. A plugin without one shows the Keybumps folder.
    static func folder(for capability: Capability?, in paths: ProductPaths) -> URL {
        switch capability {
        case .dictation: paths.dictation
        case .clipboardHistory: paths.clipboardHistory
        case .translation: paths.translations
        case .snippets: paths.snippets
        case .keyboardShortcutter: paths.shortcutCoach
        default: paths.keybumpsFolder
        }
    }

    static func identifier(_ capability: Capability?) -> String {
        capability.map { "plugin.\($0.rawValue).showFolder" } ?? "settings.general.showKeybumpsFolder"
    }
}
