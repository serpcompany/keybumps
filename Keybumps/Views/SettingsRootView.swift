import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case search = "Quick Search", clipboard = "Clipboard History", screenshotTools = "Screenshot Tools", dictation = "Dictation"
    case windows = "Window Management", keyboardShortcutter = "Keyboard Shortcutter", permissions = "Permissions", general = "General"
    var id: String { rawValue }

    /// Capability pages in registry order, then the fixed shell destinations.
    static var allCases: [SettingsSection] {
        CapabilityCatalog.descriptors.compactMap(\.settingsPage?.section) + [.permissions, .general]
    }

    /// The module whose Settings page this is; nil for the shell's Permissions and General.
    var capability: Capability? {
        CapabilityCatalog.descriptors.first { $0.settingsPage?.section == self }?.capability
    }

    var icon: String {
        if let capability { return capability.systemImage }
        return self == .permissions ? "hand.raised" : "gearshape"
    }

    var iconTint: Color { capability?.descriptor.iconTint ?? .gray }
}

struct SettingsNavigationHistory: Equatable {
    private(set) var selection: SettingsSection
    private(set) var backStack: [SettingsSection] = []
    private(set) var forwardStack: [SettingsSection] = []

    init(selection: SettingsSection = .permissions) {
        self.selection = selection
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func navigate(to section: SettingsSection) {
        guard section != selection else { return }
        backStack.append(selection)
        forwardStack = []
        selection = section
    }

    mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(selection)
        selection = previous
    }

    mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selection)
        selection = next
    }
}

extension View {
    /// Raycast's Settings window shows no title; macOS 14 keeps the title.
    @ViewBuilder func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// The Settings sidebar, modeled on Raycast's: the app's own pages first, then one row per
/// capability module in alphabetical order, filtered by the search field.
enum SettingsSidebar {
    static func groups(matching query: String) -> [[SettingsSection]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (SettingsSection) -> Bool = {
            trimmed.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
        let app = SettingsSection.allCases.filter { $0.capability == nil && matches($0) }
            .sorted { $0 == .general && $1 != .general }
        let capabilities = SettingsSection.allCases.filter { $0.capability != nil && matches($0) }
            .sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
        return [app, capabilities].filter { !$0.isEmpty }
    }
}

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = SettingsNavigationHistory(
        selection: UITestLaunchConfiguration.current.openSettings ?? .permissions
    )
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 14) {
                SettingsSearchField(text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(SettingsSidebar.groups(matching: query), id: \.self) { group in
                            VStack(spacing: 2) {
                                ForEach(group) { section in
                                    SettingsSidebarRow(
                                        section: section,
                                        isSelected: navigation.selection == section,
                                        attentionCount: model.settingsAttentionCount(for: section)
                                    ) {
                                        navigation.navigate(to: section)
                                    }
                                    .accessibilityIdentifier("settings.sidebar.\(section.launchToken)")
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 300)
        } detail: {
            Group {
                if let page = navigation.selection.capability?.descriptor.settingsPage {
                    page.content()
                } else if navigation.selection == .permissions {
                    PermissionsView()
                } else {
                    GeneralView()
                }
            }
            .environment(model)
            .accessibilityIdentifier("settings.detail.\(navigation.selection.launchToken)")
        }
        .navigationTitle("Keybumps")
        .hidingWindowTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        navigation.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!navigation.canGoBack)
                    .help("Return to the previous Settings screen")
                    .keyboardShortcut("[", modifiers: .command)
                    Button {
                        navigation.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!navigation.canGoForward)
                    .help("Go to the next Settings screen")
                    .keyboardShortcut("]", modifiers: .command)
                }
                .controlGroupStyle(.navigation)
            }
        }
        .sheet(isPresented: Binding(get: { !model.preferences.didCompleteOnboarding }, set: { _ in })) { OnboardingView().environment(model).interactiveDismissDisabled() }
        .onReceive(NotificationCenter.default.publisher(for: .openPermissions)) { _ in navigation.navigate(to: .permissions) }
        .onReceive(NotificationCenter.default.publisher(for: .openDictationHistory)) { _ in model.showDictationHistory() }
    }
}

extension AppModel {
    func settingsAttentionCount(for section: SettingsSection) -> Int {
        if section == .permissions { return missingPermissionCount }
        guard let capability = section.capability else { return 0 }
        return capabilities.attentionCount(for: capability, context: capabilityContext)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let attentionCount: Int
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(section.iconTint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(section.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("\(attentionCount) permission items need attention")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.primary.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityIdentifier("settings.search")
    }
}

struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .quickSearch)
            CapabilityShortcutEditor(shortcut: .quickSearch)
            Section {
                Button("Open Quick Search") { model.showQuickSearch() }
                    .disabled(!model.preferences.enabledCapabilities.contains(.quickSearch))
            }
        }.formStyle(.grouped).navigationTitle("Quick Search")
    }
}

struct ClipboardSettingsView: View {
    var body: some View {
        Form {
            CapabilityControl(capability: .clipboardHistory)
            CapabilityShortcutEditor(shortcut: .clipboardHistory, showsInstructions: false)
            Section("History") {
                Text("Keeps the \(ClipboardHistoryService.capacity) most recent copied text and image items on this Mac. Images up to 50 MB each are stored separately, so a full history can use several gigabytes. Copied secrets remain until you delete them or newer copies replace them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("Clipboard History")
    }
}

struct ScreenshotToolsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            CapabilityControl(capability: .screenshotTools)
            Section("Screenshots") {
                status
                Text("Screenshots you take with Shift-Command-3, 4, or 5 appear in Clipboard History, ready to paste. Keybumps never captures your screen itself, and the original files stay where macOS saved them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("Screenshot Tools")
    }

    @ViewBuilder private var status: some View {
        switch model.screenshotTools.status {
        case .stopped:
            Label("Off", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .watching(let folder):
            Label("Watching \(FileManager.default.displayName(atPath: folder.path))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .requiresClipboardHistory:
            Label("Requires Clipboard History", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Button("Enable Clipboard History") { model.setCapability(.clipboardHistory, enabled: true) }
        case .folderAccessDenied(let folder):
            Label("Keybumps can’t read \(FileManager.default.displayName(atPath: folder.path))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Allow access in System Settings › Privacy & Security › Files & Folders, then return to Keybumps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Privacy & Security") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .folderUnavailable(let folder):
            Label("\(FileManager.default.displayName(atPath: folder.path)) is unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Keybumps keeps checking and resumes when the screenshot folder is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .dictation)
            CapabilityShortcutEditor(shortcut: .dictation, showsInstructions: false)
            if model.preferences.enabledCapabilities.contains(.dictation),
               !model.missingPermissions(for: .dictation).isEmpty {
                Section("Setup required") {
                    Text("Dictation needs Microphone and Speech Recognition access before its shortcut can record.")
                        .foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            }
            Section("Language") {
                Picker("Recognition language", selection: Binding(get: { model.preferences.dictationLanguage }, set: { model.setDictationLanguage($0) })) {
                    ForEach(model.dictation.availableLanguages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
            }
            DictationTranscriptionEngineSection()
            Section("Recording length") {
                Picker(
                    "Maximum recording length",
                    selection: Binding(
                        get: { model.preferences.dictationDurationLimit },
                        set: { model.setDictationDurationLimit($0) }
                    )
                ) {
                    ForEach(DictationDurationLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(model.dictation.phase == .recording || model.dictation.phase == .transcribing)
                Text("Keybumps stops and transcribes automatically at this limit. Choose No limit to stop only with your Dictation shortcut.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("Dictation")
    }
}

private struct DictationTranscriptionEngineSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Transcription model") {
            ForEach(DictationTranscriptionEngine.allCases) { engine in
                DictationTranscriptionEngineRow(engine: engine)
            }
            Text("Downloaded models stay on this Mac. Dictation audio is transcribed locally with the selected model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DictationTranscriptionEngineRow: View {
    @Environment(AppModel.self) private var model
    let engine: DictationTranscriptionEngine
    @State private var confirmsDeletion = false

    private var state: DictationModelInstallationState {
        model.dictationModels.state(for: engine)
    }

    private var isSelected: Bool {
        model.preferences.dictationTranscriptionEngine == engine
    }

    private var isCompatible: Bool {
        engine.supports(language: model.preferences.dictationLanguage)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.title)
                Text(isCompatible ? engine.detail : "English language selection required")
                    .font(.caption)
                    .foregroundStyle(isCompatible ? Color.secondary : Color.orange)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            switch state {
            case .notInstalled:
                Button("Download") {
                    Task { await model.downloadDictationModel(engine) }
                }
                .disabled(!isCompatible)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading")
                }
                .progressViewStyle(.linear)
                .frame(width: 140)
            case .installed:
                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Use") { model.selectDictationTranscriptionEngine(engine) }
                        .disabled(!isCompatible)
                }
                if engine.requiresDownload {
                    Button("Delete", role: .destructive) { confirmsDeletion = true }
                }
            case .failed:
                Button("Retry") {
                    Task { await model.downloadDictationModel(engine) }
                }
                .disabled(!isCompatible)
            }
        }
        .confirmationDialog(
            "Delete \(engine.title)?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                model.deleteDictationModel(engine)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download this model again later.")
        }
    }
}

struct WindowSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ShortcutRecorderState()

    var body: some View {
        let readiness = model.permissionReadiness(for: [.windowManagement])
        let isEnabled = model.preferences.enabledCapabilities.contains(.windowManagement)
        let isReady = isEnabled && readiness.isReady
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                CapabilityToggle(capability: .windowManagement)
                Spacer()
                Label(
                    isEnabled ? (isReady ? "Ready" : "Setup Needed") : "Off",
                    systemImage: isEnabled ? (isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "power"
                )
                .foregroundStyle(isEnabled ? (isReady ? .green : .orange) : .secondary)
                if isEnabled && !isReady {
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
                Button("Restore Defaults") { model.restoreDefaultWindowShortcuts() }
                    .disabled(recorder.identifier != nil)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    Text("Click a shortcut to record a new combination. Press Delete to clear it or Escape to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    shortcutColumns(
                        leading: WindowSettingsLayout.primaryLeading,
                        trailing: WindowSettingsLayout.primaryTrailing
                    )

                    Divider()

                    shortcutColumns(
                        leading: WindowSettingsLayout.secondaryLeading,
                        trailing: WindowSettingsLayout.secondaryTrailing
                    )
                }
                .padding(18)
            }

            if let error = recorder.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle("Window Management")
        .onDisappear { recorder.cancel() }
    }

    private func shortcutColumns(
        leading: [WindowAction],
        trailing: [WindowAction]
    ) -> some View {
        HStack(alignment: .top, spacing: 30) {
            WindowShortcutColumn(
                actions: leading,
                activeRecorderID: recorder.identifier,
                binding: model.preferences.windowShortcut,
                record: beginRecording,
                clear: clearShortcut
            )
            WindowShortcutColumn(
                actions: trailing,
                activeRecorderID: recorder.identifier,
                binding: model.preferences.windowShortcut,
                record: beginRecording,
                clear: clearShortcut
            )
        }
    }

    private func beginRecording(_ action: WindowAction) {
        recorder.begin(
            identifier: action.rawValue,
            suspend: { model.beginShortcutRecording() },
            capture: { binding in model.finishWindowShortcutRecording(binding, for: action) },
            cancel: { model.cancelShortcutRecording() }
        )
    }

    private func clearShortcut(_ action: WindowAction) {
        model.finishWindowShortcutRecording(nil, for: action)
    }
}

private struct WindowShortcutColumn: View {
    let actions: [WindowAction]
    let activeRecorderID: String?
    let binding: (WindowAction) -> ShortcutBinding?
    let record: (WindowAction) -> Void
    let clear: (WindowAction) -> Void

    var body: some View {
        VStack(spacing: 7) {
            ForEach(actions) { action in
                let shortcut = binding(action)
                HStack(spacing: 8) {
                    Text(action.title)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    WindowActionPreviewView(action: action)
                        .frame(width: 25, height: 18)

                    Button(activeRecorderID == action.rawValue ? "Press shortcut…" : (shortcut?.displayName ?? "Record Shortcut")) {
                        record(action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: 126)
                    .disabled(activeRecorderID != nil && activeRecorderID != action.rawValue)
                    .accessibilityLabel("Record shortcut for \(action.title)")

                    Button {
                        clear(action)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .disabled(shortcut == nil || activeRecorderID != nil)
                    .help("Clear \(action.title) shortcut")
                    .accessibilityLabel("Clear shortcut for \(action.title)")
                }
                .frame(minHeight: 25)
                .padding(.top, action.startsSettingsSubgroup ? 9 : 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WindowActionPreviewView: View {
    let action: WindowAction

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(.secondary.opacity(0.75), lineWidth: 1)
            if let preview = action.preview {
                switch preview {
                case .region(let region):
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.secondary.opacity(0.75))
                            .frame(
                                width: geometry.size.width * region.width,
                                height: geometry.size.height * region.height
                            )
                            .offset(
                                x: geometry.size.width * region.minX,
                                y: geometry.size.height * region.minY
                            )
                    }
                    .padding(2)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct KeyboardShortcutterSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isEnabled = model.preferences.enabledCapabilities.contains(.keyboardShortcutter)
        let readiness = model.permissionReadiness(for: [.keyboardShortcutter])
        Form {
            CapabilityControl(capability: .keyboardShortcutter)
            if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
               model.requiresPermissionRelaunch(for: .keyboardShortcutter) {
                Section("Restart required") {
                    Text("Restart Keybumps to finish applying Accessibility or Input Monitoring access.")
                        .foregroundStyle(.secondary)
                    Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                }
            } else if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
                      !model.missingPermissions(for: .keyboardShortcutter).isEmpty {
                Section("Setup required") {
                    Text("Keyboard Shortcutter needs Accessibility and Input Monitoring access to recognize supported actions outside this app.").foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            } else if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
                      model.permissionReadiness(for: [.keyboardShortcutter]).nativeNotificationNeedsAttention {
                Section("Setup required") {
                    Text("Native macOS Banner needs Notifications access before it can appear.")
                        .foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            }
            Section("Status") {
                if !isEnabled {
                    Label("Off", systemImage: "power")
                        .foregroundStyle(.secondary)
                } else if !readiness.isReady {
                    Label("Setup Needed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if model.detectorStatus == .monitoring {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Keyboard Shortcutter needs to reconnect", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { model.retryDetection() }
                }
                Button("Send Test Suggestion") { Task { await model.deliverSample() } }
                    .disabled(!isEnabled || !readiness.isReady)
            }
            Section("Presentation channels") {
                ForEach(NotificationChannel.allCases.filter { $0 != .sound }) { channel in
                    channelControl(channel)
                }
            }
            Section("Sound") {
                channelControl(.sound)
            }
            Section("Keyboard symbols") {
                KeyboardGlyphLegendContent(entries: KeyboardShortcutRegistry.legendEntries)
            }
            Section {
                Button("Open Keyboard Shortcutter History") { model.showKeyboardShortcutterHistory() }
                Text("View, filter, and clear detected actions in the quick switcher.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcutter")
    }

    @ViewBuilder
    private func channelControl(_ channel: NotificationChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(channel.title, isOn: Binding(
                    get: { model.preferences.selectedChannels.contains(channel) },
                    set: { model.setChannel(channel, enabled: $0) }
                ))
                if channel.supportsPreview {
                    Button("Preview") { Task { await model.previewSample(channel: channel) } }
                }
            }
            ForEach(model.previewOutcomes(for: channel).keys.sorted(by: { $0.rawValue < $1.rawValue })) { deliveredChannel in
                if let outcome = model.previewOutcomes(for: channel)[deliveredChannel] {
                    switch outcome {
                    case .delivered:
                        Text("\(deliveredChannel.title) preview sent")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Text("\(deliveredChannel.title) preview failed: \(message)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if deliveredChannel == .nativeBanner {
                            Button("Open Notification Settings…") {
                                model.openNotificationSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

struct KeyboardGlyphLegendContent: View {
    let entries: [KeyboardGlyphLegendEntry]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    KeyboardKeycap(label: entry.symbol)
                        .accessibilityHidden(true)
                    Text(entry.name)
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.name), \(entry.symbol)")
            }
        }
    }
}

private struct PermissionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Permissions") {
                VStack(spacing: 8) {
                    ForEach(PermissionSettingsPresentation.visiblePermissions) { permission in
                        PermissionRow(permission: permission, compact: true)
                    }
                    NotificationPermissionRow()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .task {
            await model.monitorSystemPermissionChanges()
        }
    }
}

private struct NotificationPermissionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Notifications").font(.headline)
                Text("Lets the native macOS banner presentation appear in Notification Center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.nativeNotificationAuthorization.canPresentAlerts ? .green : .red)
            if !model.nativeNotificationAuthorization.canPresentAlerts {
                Button(actionTitle) {
                    Task { await model.requestNotificationPermission() }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task {
            await model.monitorNotificationPermissionChanges()
        }
    }

    private var statusText: String {
        switch model.nativeNotificationAuthorization {
        case .authorized, .provisional, .ephemeral: "Granted"
        case .notDetermined: "Not Requested"
        case .authorizedWithoutAlerts: "Banners Off"
        case .denied: "Denied"
        case .unknown: "Unavailable"
        }
    }

    private var actionTitle: String {
        model.nativeNotificationAuthorization == .notDetermined
            ? "Request Access…"
            : "Open System Settings…"
    }
}

private struct GeneralView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { model.updateSnapshot.automaticallyChecks },
                        set: model.setAutomaticallyChecksForUpdates
                    )
                )
                .disabled(!model.updateSnapshot.canCheck)

                LabeledContent("Status", value: model.updateSnapshot.status.summary)

                HStack {
                    Button("Check for Updates…") { model.checkForUpdates() }
                        .disabled(!model.updateSnapshot.canCheck)
                    if model.updateSnapshot.canRestart {
                        Button("Restart to Update") { model.restartToUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if case .unavailable = model.updateSnapshot.status {
                    Text("This build does not contain a configured update feed. Keybumps remains fully usable offline.")
                        .foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).navigationTitle("General")
    }
}

/// Onboarding is one screen; the conflict screen appears only when Quick Search's shortcut still
/// needs attention or a supported reference app that may claim the same shortcuts is running.
enum OnboardingFlow {
    static func needsConflictScreen(
        shortcut: QuickSearchShortcutOnboardingPresentation,
        runningReferenceApps: [ReferenceApp]
    ) -> Bool {
        !shortcut.canContinue || !runningReferenceApps.isEmpty
    }
}

private struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showsConflicts = false

    var body: some View {
        let shortcutPresentation = model.quickSearchShortcutOnboardingPresentation
        VStack(spacing: 24) {
            Spacer()
            Image(ProductIdentity.inAppBrandImageName).resizable().scaledToFit().frame(width: 72, height: 72)
            Group {
                if showsConflicts {
                    conflicts(shortcutPresentation)
                } else {
                    welcome
                }
            }.frame(maxWidth: 620)
            Spacer()
            HStack {
                if showsConflicts { Button("Back") { showsConflicts = false } }
                Spacer()
                Button("Start Keybumps") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(showsConflicts && !shortcutPresentation.canContinue)
            }
        }
        .padding(36)
        .frame(width: 760, height: 520)
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text("Welcome to Keybumps").font(.largeTitle.bold())
            Text("Grant the permissions your features need.")
                .foregroundStyle(.secondary)
            PermissionWalkthroughView(compact: true)
            if let shortcut = model.preferences.capabilityShortcut(for: .quickSearch),
               model.preferences.enabledCapabilities.contains(.quickSearch) {
                Text("Quick Search opens with \(shortcut.displayName). If Spotlight uses the same shortcut, Keybumps turns off only Spotlight's keyboard shortcut; Spotlight search stays available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Purchasing and license activation are not part of this local preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func conflicts(_ shortcutPresentation: QuickSearchShortcutOnboardingPresentation) -> some View {
        VStack(spacing: 12) {
            Text("Resolve shortcut conflicts").font(.largeTitle.bold())
            if shortcutPresentation.canContinue {
                Label("Quick Search is ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let manualRecovery = shortcutPresentation.manualRecovery {
                Label("Quick Search still needs attention.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(manualRecovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Open Keyboard Shortcuts…") { model.openKeyboardShortcutSettings() }
                    Button("Check Again") { model.refreshQuickSearchShortcutConflict() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Resolving the Spotlight shortcut…")
            }
            ForEach(ReferenceApp.allCases) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    if !model.conflicts.isRunning(app) {
                        Text("Not running").foregroundStyle(.secondary)
                    } else {
                        Button("Quit") { model.conflicts.quit(app) }
                    }
                }
            }
        }
    }

    /// The first press applies the default Quick Search shortcut through the Spotlight check and
    /// finishes, unless something still conflicts.
    private func start() {
        if !showsConflicts {
            model.refreshQuickSearchShortcutConflict()
            model.conflicts.refresh()
            if OnboardingFlow.needsConflictScreen(
                shortcut: model.quickSearchShortcutOnboardingPresentation,
                runningReferenceApps: ReferenceApp.allCases.filter(model.conflicts.isRunning)
            ) {
                showsConflicts = true
                return
            }
        }
        model.completeOnboarding()
    }
}

private struct PermissionWalkthroughView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let readiness = model.permissionReadiness
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(readiness.completedCount) of \(readiness.totalCount) complete")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let permission = readiness.currentPermission {
                if readiness.requiresRelaunch(permission) {
                    Label("Restart Keybumps to finish \(permission.title) setup.", systemImage: "arrow.clockwise.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                        .buttonStyle(.borderedProminent)
                } else {
                    PermissionRow(permission: permission, compact: true)
                    Text("After changing a macOS setting, return to Keybumps. This step advances as soon as macOS confirms access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if readiness.nativeNotificationNeedsAttention {
                NotificationPermissionRow()
                Text("After changing Notification settings, return to Keybumps and choose Refresh Status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if readiness.isReady {
                Label("All permissions needed by your enabled features are ready.", systemImage: "checkmark.circle.fill")
                    .font(compact ? .headline : .body)
                    .foregroundStyle(.green)
            }
        }
        .padding(compact ? 12 : 4)
        .background(compact ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided permission setup")
        .task {
            await model.monitorSystemPermissionChanges()
        }
    }
}

private struct CapabilityControl: View {
    let capability: Capability

    var body: some View {
        Section("Capability") {
            CapabilityToggle(capability: capability)
            if let disableExplanation {
                Text(disableExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disableExplanation: String? {
        capability.descriptor.settingsPage?.disableExplanation
    }
}

private struct CapabilityToggle: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        Toggle(
            "Enable \(capability.title)",
            isOn: CapabilityToggleBinding(model: model, capability: capability).value
        )
        .accessibilityIdentifier("capability.toggle.\(capability.rawValue)")
    }
}

@MainActor
struct CapabilityToggleBinding {
    let model: AppModel
    let capability: Capability

    var value: Binding<Bool> {
        Binding(
            get: { model.preferences.enabledCapabilities.contains(capability) },
            set: { model.setCapability(capability, enabled: $0) }
        )
    }
}

private struct CapabilityShortcutEditor: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ShortcutRecorderState()
    let shortcut: CapabilityShortcut
    var showsInstructions = true

    var body: some View {
        let binding = model.preferences.capabilityShortcut(for: shortcut)
        Section("Shortcut") {
            if showsInstructions {
                Text("Record a new shortcut, clear it, or restore the default. Escape cancels recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(shortcut.title)
                Spacer()
                Button {
                    recorder.begin(
                        identifier: shortcut.rawValue,
                        suspend: { model.beginShortcutRecording() },
                        capture: { model.finishCapabilityShortcutRecording($0, for: shortcut) },
                        cancel: { model.cancelShortcutRecording() }
                    )
                } label: {
                    if recorder.identifier == shortcut.rawValue {
                        Text("Press shortcut…")
                    } else if let binding {
                        ShortcutKeycaps(shortcut: binding.displayName, compact: true)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .accessibilityLabel("Record shortcut for \(shortcut.title)")
                .accessibilityValue(shortcutAccessibilityValue(binding: binding))
                Button("Clear") {
                    model.finishCapabilityShortcutRecording(nil, for: shortcut)
                }
                .disabled(binding == nil || recorder.identifier != nil)
                Button("Restore Default") {
                    model.restoreDefaultCapabilityShortcut(shortcut)
                }
                .disabled(binding?.usesSameKeys(as: shortcut.defaultBinding) == true || recorder.identifier != nil)
            }
            if let error = recorder.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let failure = model.shortcuts.failures[shortcut.ownerID] {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private func shortcutAccessibilityValue(binding: ShortcutBinding?) -> String {
        if recorder.identifier == shortcut.rawValue { return "Waiting for shortcut" }
        guard let binding else { return "No shortcut assigned" }
        return KeyboardShortcutRegistry.accessibilityCopy(for: binding.displayName)
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let permission: MacPermission
    var compact = false

    var body: some View {
        let readiness = model.permissionReadiness
        let state = readiness.state(for: permission)
        let action = PermissionSettingsRowAction.resolve(
            permission: permission,
            state: state,
            requiresRelaunch: model.requiresPermissionRelaunch(permission)
        )
        Group {
            if compact {
                content(state: state, action: action)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Section(permission.title) { content(state: state, action: action) }
            }
        }
    }

    @ViewBuilder
    private func content(state: PermissionAuthorizationState, action: PermissionSettingsRowAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if compact { Text(permission.title).font(.headline) }
                Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.requiresPermissionRelaunch(permission) ? "Restart Required" : state.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.isGranted ? .green : .orange)
            switch action {
            case .restartKeybumps:
                Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
            case .requestAccess:
                Button("Request Access…") { Task { await model.recoverPermission(permission) } }
                    .disabled(model.permissions.activeRequest != nil)
                    .accessibilityLabel("Request access for \(permission.title)")
            case .recoverInSystemSettings:
                Button("Open System Settings…") { Task { await model.recoverPermission(permission) } }
                    .disabled(model.permissions.activeRequest != nil)
                    .accessibilityLabel("Open System Settings for \(permission.title)")
            case .openSystemSettings:
                Button("Open System Settings…") { model.openPermissionSettings(permission) }
                    .accessibilityLabel("Open System Settings for \(permission.title)")
            }
        }
    }
}

extension Notification.Name {
    static let openPermissions = Notification.Name("Keybumps.openPermissions")
    static let openDictationHistory = Notification.Name("Keybumps.openDictationHistory")
}

@MainActor @Observable
private final class ShortcutRecorderState {
    private(set) var identifier: String?
    private(set) var error: String?
    private var monitor: Any?
    private var cancelAction: (() -> Void)?

    func begin(
        identifier: String,
        suspend: () -> Void,
        capture: @escaping (ShortcutBinding?) -> Void,
        cancel: @escaping () -> Void
    ) {
        stopMonitor()
        self.identifier = identifier
        error = nil
        cancelAction = cancel
        suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.finish()
                cancel()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Delete), flags.isEmpty {
                self.finish()
                capture(nil)
                return nil
            }
            guard let binding = ShortcutBinding(event: event) else {
                self.error = "Use at least one modifier key such as Control, Option, Shift, or Command."
                return nil
            }
            self.finish()
            capture(binding)
            return nil
        }
    }

    func cancel() {
        guard identifier != nil else { return }
        let action = cancelAction
        finish()
        action?()
    }

    private func finish() {
        stopMonitor()
        identifier = nil
        error = nil
        cancelAction = nil
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
