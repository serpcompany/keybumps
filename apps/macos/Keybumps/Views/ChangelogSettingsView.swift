import SwiftUI

/// Settings › Changelog (#416): update status and controls, then every release's What's New notes,
/// newest first. The up-to-date alert's Version History button opens it.
struct ChangelogSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Read once: the notes ship inside the app and don't change while it runs.
    private static let entries = Changelog.entries()
    private static let installedVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap(ReleaseVersion.init)?.description

    var body: some View {
        SettingsPage {
            SettingsGroup("Updates") {
                LabeledContent {
                    HStack(spacing: 8) {
                        if model.updateSnapshot.canRestart {
                            Button("Restart to Update") { model.restartToUpdate() }
                        }
                        Button("Check now") { model.checkForUpdates() }
                            .disabled(!model.updateSnapshot.canCheck)
                    }
                } label: {
                    SettingsRowLabel(title: "Keybumps Updates", subtitle: "\(AppVersionDisplay.title()) · \(model.updateSnapshot.status.summary)")
                }
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { model.updateSnapshot.automaticallyChecks },
                        set: model.setAutomaticallyChecksForUpdates
                    )
                )
                .disabled(!model.updateSnapshot.canCheck)
                if case .unavailable = model.updateSnapshot.status {
                    SettingsNote("This build does not contain a configured update feed. Keybumps remains fully usable offline.")
                }
            }
            if Self.entries.isEmpty {
                SettingsGroup("Version history") {
                    SettingsNote("This build doesn't include release notes.")
                }
            }
            ForEach(Self.entries) { entry in
                SettingsGroup(entry.version, subtitle: entry.version == Self.installedVersion ? "Installed" : nil) {
                    // The group's title names the version, so the notes' own title is left out.
                    ReleaseNotesBlocksView(blocks: entry.notes.blocks.filter {
                        if case .title = $0 { false } else { true }
                    })
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("settings.changelog.\(entry.version)")
            }
        }
        .navigationTitle("Changelog")
    }
}
