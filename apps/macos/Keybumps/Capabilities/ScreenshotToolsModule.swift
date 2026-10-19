import SwiftUI

extension CapabilityDescriptor {
    /// ScreenGrabs (ADR 0010): screenshots and recordings, in one plugin that took Screenshot Tools'
    /// ID. Its screenshot code is under `ScreenshotTools/` and its recording code under `Screencast/`.
    static let screenshotTools = CapabilityDescriptor(
        capability: .screenshotTools,
        title: "ScreenGrabs",
        systemImage: "camera.viewfinder",
        iconTint: .purple,
        requiredPermissions: [.screenRecording],
        // For screenshots only: recording works with Clipboard History off.
        dependencies: [.clipboardHistory],
        paletteTab: CapabilityPaletteTab(
            tab: .screenshots,
            name: "ScreenGrabs",
            commandKey: 3,
            systemImage: "camera.viewfinder",
            prompt: "Search ScreenGrabs",
            primaryActionTitle: "Copy",
            secondaryActions: [.paste(), .edit],
            // Its screenshots; its recordings need neither (#494).
            dataSource: .clipboardHistory,
            listsRecordings: true
        ),
        settingsPage: CapabilitySettingsPage(
            section: .screenshotTools,
            summary: "Take screenshots and mark them up, and record your screen with your voice and the Mac’s sound.",
            disableExplanation: "Turning this off stops the screenshot hotkeys, Record Screen, and adding new screenshots to Clipboard History, and gives ⇧⌘3, ⇧⌘4, and ⇧⌘5 back to macOS. Screenshots and recordings already saved stay.",
            // macOS 14: no Record Screen, and macOS keeps its ⇧⌘5 (`takeoverBindings`).
            disableExplanationWithoutRecording: "Turning this off stops the screenshot hotkeys and adding new screenshots to Clipboard History, and gives ⇧⌘3 and ⇧⌘4 back to macOS. Screenshots already saved stay.",
            content: { AnyView(ScreengrabsSettingsPage()) }
        ),
        criticalOperations: [.unsavedWork],
        // Its name as people type it (#512): Quick Search reads the title "ScreenGrabs" as one word.
        searchKeywords: [
            "screengrabs", "screengrab", "screen grabs",
            "screenshots", "screenshot", "screen", "capture", "annotate",
            "screen recording", "recordings", "record", "recorder", "video", "screencast",
        ],
        actions: [.startScreencast],
        category: .media,
        preferences: [
            .screencastRecordsMicrophone, .screencastRecordsSystemAudio,
            .screencastCountdown, .screencastShowsShortcuts, .screencastHighlightsClicks,
        ],
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .accessibility,
                reason: "Lets ⌘P paste a screenshot into the app you were using. Without it, ⌘P copies the screenshot instead."
            ),
            PluginOptionalPermission(
                permission: .microphone,
                reason: "Records your voice with a recording. Without it, recordings have only the screen and the Mac’s sound."
            ),
            PluginOptionalPermission(
                permission: .inputMonitoring,
                reason: "Shows the shortcuts you press in a recording, with Show shortcuts on screen on. Without it, recordings show none."
            ),
        ]
    )
}

/// Owns ScreenGrabs: the screenshot watcher and the Screenshot Editor, which run only while Clipboard
/// History, its dependency, is enabled, and contribute the edit action to Clipboard tab image rows;
/// the ScreenGrabs tab's rows (`ScreengrabsPaletteContent`), its screenshots and recordings; and its
/// recording (`recording`), which doesn't need Clipboard History and runs only where
/// `PluginCompatibility.supportsRecording`.
@MainActor
final class ScreenshotToolsModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.screenshotTools
    let paletteContent: (any CapabilityPaletteContent)?
    /// The screenshot hotkeys: what each captures, and whether it then opens the Screenshot Editor.
    static let captureShortcuts: [(shortcut: CapabilityShortcut, mode: ScreenshotCaptureMode, opensEditor: Bool)] = [
        (.screenshotScreen, .screens, false),
        (.screenshotScreenAndEdit, .screens, true),
        (.screenshotAreaAndEdit, .area, true)
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
    /// Recording: Record Screen, the picker, the control bar, and the recording window.
    let recording: ScreencastModule
    /// Set by the shell: asks for Screen Recording when a hotkey is pressed without it.
    var onNeedsScreenRecording: (() -> Void)?
    /// Set by the shell: runs just before a hotkey captures, so the key display is off the screen.
    var willCapture: (() -> Void)?

    init(
        service: ScreenshotToolsService,
        palette: CommandPaletteController,
        clipboard: ClipboardHistoryService,
        preferences: AppPreferences,
        delivery: ScreenshotClipboardDelivery,
        capturer: ScreenshotCapturer,
        systemShortcuts: SystemScreenshotShortcutTakeover,
        permissions: PermissionCoordinator,
        recording: ScreencastModule,
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
        self.recording = recording
        let review = recording.review
        paletteContent = ScreengrabsPaletteContent(
            clipboard: clipboard,
            preferences: preferences,
            recordings: recording.recordings,
            openRecording: { [weak review] recording in review?.open(recording) ?? false },
            trash: review.trash,
            filter: { [weak palette] in palette?.state.filter }
        )
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
        for (shortcut, mode, opensEditor) in Self.captureShortcuts {
            let binding = context.preferences.capabilityShortcut(for: shortcut)
            context.configureShortcut(owner: shortcut.ownerID, for: capability, binding: binding) { [weak self] in
                self?.capture(mode, opensEditor: opensEditor)
            }
        }
        systemShortcuts.apply(bindings: Self.takeoverBindings(context.preferences), isEnabled: isEnabled)
        recording.apply(context)
    }

    /// The keys that take macOS's own screenshot shortcuts while ScreenGrabs is on: the screenshot
    /// hotkeys', and Record Screen's (⇧⌘5 by default) only where it can record, so macOS 14 keeps
    /// its own ⇧⌘5.
    static func takeoverBindings(_ preferences: AppPreferences) -> [ShortcutBinding] {
        var shortcuts = captureShortcuts.map(\.shortcut)
        if preferences.compatibility.supportsRecording { shortcuts.append(.screencast) }
        return shortcuts.compactMap(preferences.capabilityShortcut(for:))
    }

    func deactivate(_ context: CapabilityContext) {
        service.stop()
        editor.close()
        recording.deactivate(context)
    }

    /// Screen Recording while it's on and missing, and setup the watcher needs. Requires Clipboard
    /// History counts only while a screenshot hotkey is assigned, so someone who only records, with
    /// Clipboard History off, isn't shown a Settings dot that never clears.
    func attentionCount(_ context: CapabilityContext) -> Int {
        let takesScreenshots = Self.captureShortcuts.contains { context.preferences.capabilityShortcut(for: $0.shortcut) != nil }
        let setup = switch service.status {
        case .requiresClipboardHistory: takesScreenshots ? 1 : 0
        case .folderAccessDenied: 1
        case .stopped, .watching, .folderUnavailable: 0
        }
        let permission = context.isEnabled(capability) && !context.permissions.screenRecordingGranted ? 1 : 0
        return setup + permission
    }

    /// Quick Search's Record Screen.
    func perform(_ action: PluginAction, _ context: CapabilityContext) {
        recording.perform(action, context)
    }

    func offers(_ action: PluginAction, _ context: CapabilityContext) -> Bool {
        recording.offers(action, context)
    }

    private func capture(_ mode: ScreenshotCaptureMode, opensEditor: Bool) {
        permissions.refresh()
        guard permissions.screenRecordingGranted else {
            onNeedsScreenRecording?()
            return
        }
        willCapture?()
        delivery.capture(mode, with: capturer, watcher: service, forEditing: opensEditor) { [weak self] files in
            guard opensEditor, let self, let file = files.first,
                  let entry = clipboard.entries.first(where: { $0.sourcePath == file.path }) else { return }
            _ = editor.edit(entry)
        }
    }
}

/// Settings › ScreenGrabs, on the plugin template: Commands, then Permissions (Screen Recording,
/// which both kinds need, and the optional ones), then the Screenshots group in the slot above the
/// declared preferences, then Recordings, its declared preferences, ending with the Recordings
/// folder. Where ScreenGrabs can't record, Recordings says so and its preferences can't change.
struct ScreengrabsSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recordingUnavailable = !model.preferences.compatibility.supportsRecording
        PluginSettingsPage(
            capability: .screenshotTools,
            unavailableGroups: recordingUnavailable ? [PluginPreference.recordingsGroup] : []
        ) {
            ScreenshotsSettings()
        } groupRows: { group in
            if group == PluginPreference.recordingsGroup {
                ScreencastCapturesSettings()
            }
        } custom: {
            EmptyView()
        }
        .navigationTitle(Capability.screenshotTools.title)
    }
}

/// ScreenGrabs' Screenshots group, in its page's slot above the declared preferences: the watcher's
/// status, which names the screenshot folder macOS saves to, with what fixes it; the Screenshots
/// folder the hotkeys save in (`ScreengrabFolderRow`, #504); and Copy new screenshots to the
/// clipboard, which keeps its own key (`AppPreferences.copiesScreenshotsToClipboard`).
/// Each row reports itself through `Shown`, so a test can lay out the page in each of the watcher's
/// states.
struct ScreenshotsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup("Screenshots") {
            // A `@ViewBuilder` property, not a view of its own, so each of its views is a row.
            status
            ScreengrabFolderRow(kind: .screenshots)
            Toggle("Copy new screenshots to the clipboard", isOn: Binding(
                get: { model.preferences.copiesScreenshotsToClipboard },
                set: { model.preferences.copiesScreenshotsToClipboard = $0 }
            ))
            .shown(.copiesScreenshotsToClipboard)
            SettingsNote(Self.about(on: model.preferences.compatibility))
                .shown(.about)
        }
    }

    /// The group's note on this Mac. Keybumps takes macOS's ⇧⌘5 only where ScreenGrabs can record
    /// (`ScreenshotToolsModule.takeoverBindings`), so on macOS 14 the note names only ⇧⌘3 and ⇧⌘4.
    static func about(on compatibility: PluginCompatibility) -> String {
        let keys = compatibility.supportsRecording ? "⇧⌘3, ⇧⌘4, and ⇧⌘5" : "⇧⌘3 and ⇧⌘4"
        return "Screenshots from these hotkeys are saved in the Screenshots folder, and ones you take with macOS's own tools where macOS saves screenshots; both appear in Clipboard History, ready to paste. With Copy new screenshots on, each also goes on the clipboard unless you've copied something since it was saved; Screenshot Screen and Edit and Screenshot Area and Edit copy only when you Save. While ScreenGrabs is on, Keybumps uses \(keys) in place of macOS's own; turning it off gives them back."
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
        case off, watching, screenshotsFolder
        case requiresClipboardHistory, enableClipboardHistory
        case folderAccessDenied, folderAccessHelp, openPrivacyAndSecurity
        case folderUnavailable, folderUnavailableHelp
        case copiesScreenshotsToClipboard, about
        /// The Recordings group's own rows (`ScreencastCapturesSettings`).
        case recordingRequirement, recordingsFolder
    }

    /// The rows the group draws, in order, and the Recordings group's own.
    struct Shown: PreferenceKey {
        static let defaultValue: [Row] = []
        static func reduce(value: inout [Row], nextValue: () -> [Row]) { value += nextValue() }
    }
}

extension View {
    /// Reports a row of Settings › ScreenGrabs' own to `ScreenshotsSettings.Shown`.
    func shown(_ row: ScreenshotsSettings.Row) -> some View {
        preference(key: ScreenshotsSettings.Shown.self, value: [row])
    }
}
