import SwiftUI

extension CapabilityDescriptor {
    static let screenshotTools = CapabilityDescriptor(
        capability: .screenshotTools,
        title: "Screenshot Tools",
        systemImage: "camera.viewfinder",
        iconTint: .purple,
        requiredPermissions: [.screenRecording],
        dependencies: [.clipboardHistory],
        paletteTab: CapabilityPaletteTab(
            tab: .screenshots,
            name: "Screenshots",
            commandKey: 3,
            systemImage: "camera.viewfinder",
            prompt: "Search screenshots",
            primaryActionTitle: "Edit",
            secondaryActionTitle: "Copy",
            dataSource: .clipboardHistory
        ),
        settingsPage: CapabilitySettingsPage(
            section: .screenshotTools,
            summary: "Take screenshots, keep them in Clipboard History, and mark them up.",
            disableExplanation: "Turning this off stops the screenshot hotkeys and adding new screenshots to Clipboard History, and gives ⇧⌘3 and ⇧⌘4 back to macOS. Screenshots already there stay until removed.",
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
    static let captureShortcuts: [(shortcut: CapabilityShortcut, mode: ScreenshotCaptureMode)] = [
        (.screenshotScreen, .screens),
        (.screenshotScreenAndEdit, .screens),
        (.screenshotArea, .area)
    ]

    private let service: ScreenshotToolsService
    private let editor: ScreenshotEditorPresenter
    private let palette: CommandPaletteController
    private let clipboard: ClipboardHistoryService
    private let capturer: ScreenshotCapturer
    private let systemShortcuts: SystemScreenshotShortcutTakeover
    private let permissions: PermissionCoordinator
    /// Set by the shell: asks for Screen Recording when a hotkey is pressed without it.
    var onNeedsScreenRecording: (() -> Void)?

    init(
        service: ScreenshotToolsService,
        palette: CommandPaletteController,
        clipboard: ClipboardHistoryService,
        capturer: ScreenshotCapturer,
        systemShortcuts: SystemScreenshotShortcutTakeover,
        permissions: PermissionCoordinator,
        editorFallbackFolder: @escaping () -> URL,
        updateSafety: CapabilityUpdateSafety
    ) {
        self.service = service
        self.palette = palette
        self.clipboard = clipboard
        self.capturer = capturer
        self.systemShortcuts = systemShortcuts
        self.permissions = permissions
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
        var bindings: [ShortcutBinding] = []
        for (shortcut, mode) in Self.captureShortcuts {
            let binding = context.preferences.capabilityShortcut(for: shortcut)
            if let binding { bindings.append(binding) }
            context.configureShortcut(owner: shortcut.ownerID, for: capability, binding: binding) { [weak self] in
                self?.capture(mode, opensEditor: shortcut == .screenshotScreenAndEdit)
            }
        }
        systemShortcuts.apply(bindings: bindings, isEnabled: isEnabled)
    }

    func deactivate(_ context: CapabilityContext) {
        service.stop()
        editor.close()
    }

    func attentionCount(_ context: CapabilityContext) -> Int {
        let setup = switch service.status {
        case .requiresClipboardHistory, .folderAccessDenied: 1
        case .stopped, .watching, .folderUnavailable: 0
        }
        let permission = context.isEnabled(capability) && !context.permissions.screenRecordingGranted ? 1 : 0
        return setup + permission
    }

    private func capture(_ mode: ScreenshotCaptureMode, opensEditor: Bool) {
        permissions.refresh()
        guard permissions.screenRecordingGranted else {
            onNeedsScreenRecording?()
            return
        }
        capturer.capture(mode) { [weak self] files in
            guard opensEditor, let self, let file = files.first else { return }
            _ = clipboard.ingestImageFile(at: file, isScreenCapture: true)
            if let entry = clipboard.entries.first(where: { $0.sourcePath == file.path }) {
                _ = editor.edit(entry)
            }
        }
    }
}
