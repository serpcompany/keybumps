import SwiftUI

extension CapabilityDescriptor {
    static let screenshotTools = CapabilityDescriptor(
        capability: .screenshotTools,
        title: "Screenshot Tools",
        systemImage: "camera.viewfinder",
        iconTint: .purple,
        requiredPermissions: [],
        dependencies: [.clipboardHistory],
        paletteTab: CapabilityPaletteTab(
            tab: .screenshots,
            name: "Screenshots",
            commandKey: 4,
            systemImage: "camera.viewfinder",
            prompt: "Search screenshots",
            primaryActionTitle: "Edit",
            secondaryActionTitle: "Copy",
            dataSource: .clipboardHistory
        ),
        settingsPage: CapabilitySettingsPage(
            section: .screenshotTools,
            summary: "Keep your screenshots in Clipboard History and mark them up.",
            disableExplanation: "Turning this off stops adding new screenshots to Clipboard History. Screenshots already there stay until removed.",
            content: { AnyView(ScreenshotToolsSettingsView()) }
        ),
        criticalOperations: [.unsavedWork]
    )
}

/// Owns the screenshot watcher and the Screenshot Editor. It runs only while Clipboard History,
/// its dependency, is enabled, and contributes the edit action to Clipboard tab image rows.
@MainActor
final class ScreenshotToolsModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.screenshotTools
    private let service: ScreenshotToolsService
    private let editor: ScreenshotEditorPresenter
    private let palette: CommandPaletteController

    init(
        service: ScreenshotToolsService,
        palette: CommandPaletteController,
        editorFallbackFolder: @escaping () -> URL,
        updateSafety: CapabilityUpdateSafety
    ) {
        self.service = service
        self.palette = palette
        editor = ScreenshotEditorPresenter(
            fallbackFolder: editorFallbackFolder,
            editingChanged: { isEditing in
                updateSafety.setCriticalOperation(.unsavedWork, active: isEditing)
            }
        )
    }

    func apply(_ context: CapabilityContext) {
        let isEnabled = context.isEnabled(capability)
        service.apply(
            enabled: isEnabled,
            clipboardHistoryEnabled: descriptor.dependencies.allSatisfy(context.isEnabled)
        )
        palette.editImage = isEnabled
            ? { [weak editor] entry in editor?.edit(entry) ?? false }
            : nil
    }

    func deactivate(_ context: CapabilityContext) {
        service.stop()
        editor.close()
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        switch service.status {
        case .requiresClipboardHistory, .folderAccessDenied: 1
        case .stopped, .watching, .folderUnavailable: 0
        }
    }
}
