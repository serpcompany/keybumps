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
            primaryActionTitle: "Copy",
            secondaryActions: [.paste(), .edit],
            dataSource: .clipboardHistory
        ),
        settingsPage: CapabilitySettingsPage(
            section: .screenshotTools,
            summary: "Take screenshots, keep them in Clipboard History, and mark them up.",
            disableExplanation: "Turning this off stops the screenshot hotkeys and adding new screenshots to Clipboard History, and gives ⇧⌘3 and ⇧⌘4 back to macOS. Screenshots already there stay until removed.",
            content: {
                // Screen Recording has its own row in the Screenshots group, with Restart Keybumps.
                AnyView(PluginSettingsPage(capability: .screenshotTools, includesRequiredPermissions: false) {
                    ScreenshotsSettings()
                } custom: {
                    EmptyView()
                }
                // The window's title on macOS 14, which shows it (`hidingWindowTitle`).
                .navigationTitle("Screenshot Tools"))
            }
        ),
        criticalOperations: [.unsavedWork],
        searchKeywords: ["screenshots", "screenshot", "screen", "capture", "annotate"],
        category: .media,
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .accessibility,
                reason: "Lets ⌘P paste a screenshot into the app you were using. Without it, ⌘P copies the screenshot instead."
            ),
        ]
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
    private let delivery: ScreenshotClipboardDelivery
    private let capturer: ScreenshotCapturer
    /// Read by the unit-test isolation guard.
    let systemShortcuts: SystemScreenshotShortcutTakeover
    private let permissions: PermissionCoordinator
    /// Set by the shell: asks for Screen Recording when a hotkey is pressed without it.
    var onNeedsScreenRecording: (() -> Void)?
    /// Set by the shell: runs just before a hotkey captures, so the key display is off the screen.
    var willCapture: (() -> Void)?

    init(
        service: ScreenshotToolsService,
        palette: CommandPaletteController,
        clipboard: ClipboardHistoryService,
        delivery: ScreenshotClipboardDelivery,
        capturer: ScreenshotCapturer,
        systemShortcuts: SystemScreenshotShortcutTakeover,
        permissions: PermissionCoordinator,
        editorFallbackFolder: @escaping () -> URL,
        updateSafety: CapabilityUpdateSafety
    ) {
        self.service = service
        self.palette = palette
        self.clipboard = clipboard
        self.delivery = delivery
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
        willCapture?()
        capturer.capture(mode) { [weak self] files in
            guard opensEditor, let self, let file = delivery.addForEditing(files) else { return }
            if let entry = clipboard.entries.first(where: { $0.sourcePath == file.path }) {
                _ = editor.edit(entry)
            }
        }
    }
}

/// Screenshot Tools' Screenshots group, in its page's slot above the declared preferences: Screen
/// Recording while it's missing, the watcher's status with what fixes it, and Copy new screenshots
/// to the clipboard, which keeps its own key (`AppPreferences.copiesScreenshotsToClipboard`). Each
/// row reports itself through `Shown`, so a test can lay out the page in each of the watcher's
/// states.
struct ScreenshotsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup("Screenshots") {
            if !model.permissions.screenRecordingGranted {
                LabeledContent {
                    HStack {
                        Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                        Button("Allow…") { Task { await model.recoverPermission(.screenRecording) } }
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Screen Recording required",
                        subtitle: "The screenshot hotkeys need Screen Recording access. Allow Keybumps in System Settings, then restart Keybumps so macOS applies it."
                    )
                }
                .shown(.screenRecordingRequired)
            }
            // A `@ViewBuilder` property, not a view of its own, so each of its views is a row.
            status
            Toggle("Copy new screenshots to the clipboard", isOn: Binding(
                get: { model.preferences.copiesScreenshotsToClipboard },
                set: { model.preferences.copiesScreenshotsToClipboard = $0 }
            ))
            .shown(.copiesScreenshotsToClipboard)
            SettingsNote("Screenshots from these hotkeys, and ones you take with macOS's own ⇧⌘5, are saved where macOS saves screenshots and appear in Clipboard History, ready to paste. With Copy new screenshots on, each also goes on the clipboard unless you've copied something since it was saved; Screenshot Screen and Edit copies only when you Save. While Screenshot Tools is on, Keybumps uses ⇧⌘3 and ⇧⌘4 in place of macOS's own; turning it off gives them back.")
                .shown(.about)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.screenshotTools.status {
        case .stopped:
            Label("Off", systemImage: "pause.circle").foregroundStyle(.secondary)
                .shown(.off)
        case .watching(let folder):
            Label("Watching \(FileManager.default.displayName(atPath: folder.path))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .shown(.watching)
        case .requiresClipboardHistory:
            Label("Requires Clipboard History", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .shown(.requiresClipboardHistory)
            Button("Enable Clipboard History") { model.setCapability(.clipboardHistory, enabled: true) }
                .shown(.enableClipboardHistory)
        case .folderAccessDenied(let folder):
            Label("Keybumps can’t read \(FileManager.default.displayName(atPath: folder.path))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .shown(.folderAccessDenied)
            SettingsNote("Allow access in System Settings › Privacy & Security › Files & Folders, then return to Keybumps.")
                .shown(.folderAccessHelp)
            Button("Open Privacy & Security") { model.permissions.openSystemSettings(.filesAndFolders) }
                .shown(.openPrivacyAndSecurity)
        case .folderUnavailable(let folder):
            Label("\(FileManager.default.displayName(atPath: folder.path)) is unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .shown(.folderUnavailable)
            SettingsNote("Keybumps keeps checking and resumes when the screenshot folder is available.")
                .shown(.folderUnavailableHelp)
        }
    }

    enum Row {
        case screenRecordingRequired
        case off, watching
        case requiresClipboardHistory, enableClipboardHistory
        case folderAccessDenied, folderAccessHelp, openPrivacyAndSecurity
        case folderUnavailable, folderUnavailableHelp
        case copiesScreenshotsToClipboard, about
    }

    /// The rows the group draws, in order.
    struct Shown: PreferenceKey {
        static let defaultValue: [Row] = []
        static func reduce(value: inout [Row], nextValue: () -> [Row]) { value += nextValue() }
    }
}

private extension View {
    func shown(_ row: ScreenshotsSettings.Row) -> some View {
        preference(key: ScreenshotsSettings.Shown.self, value: [row])
    }
}
