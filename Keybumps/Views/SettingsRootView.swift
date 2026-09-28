import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case search = "Quick Search", clipboard = "Clipboard History", screenshotTools = "Screenshot Tools", dictation = "Dictation"
    case windows = "Window Manager", keyboardShortcutter = "Keyboard Shortcutter", permissions = "Permissions", general = "General"
    case account = "Account"
    var id: String { rawValue }

    /// Capability pages in registry order, then the fixed shell destinations.
    static var allCases: [SettingsSection] {
        CapabilityCatalog.descriptors.compactMap(\.settingsPage?.section) + [.permissions, .general, .account]
    }

    /// The module whose Settings page this is; nil for the shell's Permissions and General.
    var capability: Capability? {
        CapabilityCatalog.descriptors.first { $0.settingsPage?.section == self }?.capability
    }

    var icon: String {
        if let capability { return capability.systemImage }
        switch self {
        case .permissions: return "hand.raised"
        case .account: return "person.crop.circle"
        default: return "gearshape"
        }
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

/// The Settings sidebar, modeled on Raycast's: the account row on top (outside these groups), the
/// app's own pages, then one row per capability module (Quick Search first, then alphabetical),
/// filtered by search.
enum SettingsSidebar {
    static func groups(matching query: String) -> [[SettingsSection]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (SettingsSection) -> Bool = {
            trimmed.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
        let app = SettingsSection.allCases.filter { $0.capability == nil && $0 != .account && matches($0) }
            .sorted { $0 == .general && $1 != .general }
        // Quick Search first, then alphabetical.
        let capabilities = SettingsSection.allCases.filter { $0.capability != nil && matches($0) }
            .sorted { lhs, rhs in
                if (lhs == .search) != (rhs == .search) { return lhs == .search }
                return lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
            }
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
            VStack(spacing: 12) {
                SettingsSearchField(text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            SettingsAccountRow(isSelected: navigation.selection == .account) {
                                navigation.navigate(to: .account)
                            }
                            .accessibilityIdentifier("settings.sidebar.account")
                        }
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
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SettingsTheme.sidebarBackground)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
        } detail: {
            Group {
                if let page = navigation.selection.capability?.descriptor.settingsPage {
                    page.content()
                } else if navigation.selection == .permissions {
                    PermissionsView()
                } else if navigation.selection == .account {
                    AccountView()
                } else {
                    GeneralView()
                }
            }
            .environment(model)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let capability = navigation.selection.capability {
                        CapabilityToggle(capability: capability)
                    }
                }
            }
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(section.iconTint.gradient, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                Text(section.rawValue)
                    .font(.system(size: SettingsTheme.sidebarTextSize))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("\(attentionCount) permission items need attention")
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? SettingsTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Mac user's name and initials; Keybumps has no account service.
enum SettingsAccount {
    static var name: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }

    static var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct SettingsAvatar: View {
    let size: CGFloat

    var body: some View {
        Text(SettingsAccount.initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.gray.gradient, in: Circle())
    }
}

private struct SettingsAccountRow: View {
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                SettingsAvatar(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SettingsAccount.name)
                        .font(.system(size: SettingsTheme.sidebarTextSize, weight: .medium))
                        .lineLimit(1)
                    Text("Account")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? SettingsTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AccountView: View {
    var body: some View {
        SettingsPage {
            VStack(spacing: 8) {
                SettingsAvatar(size: 88)
                    .padding(.bottom, 6)
                Text(SettingsAccount.name)
                    .font(.system(size: 20, weight: .semibold))
                Text("Signed in on this Mac")
                    .font(.system(size: SettingsTheme.titleSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 12)
            SettingsGroup("License") {
                SettingsRowLabel(
                    title: "Local Preview",
                    subtitle: "Purchasing and license activation are not part of this local preview."
                )
            }
        }
        .navigationTitle("Account")
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
                .font(.system(size: SettingsTheme.titleSize))
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .background(SettingsTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityIdentifier("settings.search")
    }
}

struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .quickSearch, shortcut: .quickSearch)
            SettingsGroup {
                LabeledContent {
                    Button("Open") { model.showQuickSearch() }
                        .disabled(!model.preferences.enabledCapabilities.contains(.quickSearch))
                } label: {
                    SettingsRowLabel(title: "Open Quick Search", subtitle: "Search apps, files, and folders.")
                }
            }
        }.navigationTitle("Quick Search")
    }
}

struct ClipboardSettingsView: View {
    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .clipboardHistory, shortcut: .clipboardHistory)
            SettingsGroup("History") {
                Text("Keeps the \(ClipboardHistoryService.capacity) most recent copied text and image items on this Mac. Images up to 50 MB each are stored separately, so a full history can use several gigabytes. Copied secrets remain until you delete them or newer copies replace them.")
                    .font(.system(size: SettingsTheme.subtitleSize))
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Clipboard History")
    }
}

struct ScreenshotToolsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .screenshotTools)
            SettingsGroup("Screenshots") {
                status
                Text("Screenshots you take with Shift-Command-3, 4, or 5 appear in Clipboard History, ready to paste. Keybumps never captures your screen itself, and the original files stay where macOS saved them.")
                    .font(.system(size: SettingsTheme.subtitleSize))
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Screenshot Tools")
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
                .font(.system(size: SettingsTheme.subtitleSize))
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
                .font(.system(size: SettingsTheme.subtitleSize))
                .foregroundStyle(.secondary)
        }
    }
}

struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .dictation, shortcut: .dictation)
            if model.preferences.enabledCapabilities.contains(.dictation),
               !model.missingPermissions(for: .dictation).isEmpty {
                SettingsGroup("Setup required") {
                    Text("Dictation needs Microphone and Speech Recognition access before its shortcut can record.")
                        .foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            }
            SettingsGroup("Language") {
                LabeledContent("Recognition language") {
                    SettingsDropdown(
                        title: "Recognition language",
                        selection: Binding(get: { model.preferences.dictationLanguage }, set: { model.setDictationLanguage($0) }),
                        options: model.dictation.availableLanguages.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
                    )
                }
            }
            DictationTranscriptionEngineSection()
            SettingsGroup("Recording length") {
                LabeledContent {
                    SettingsDropdown(
                        title: "Maximum recording length",
                        selection: Binding(
                            get: { model.preferences.dictationDurationLimit },
                            set: { model.setDictationDurationLimit($0) }
                        ),
                        options: DictationDurationLimit.allCases.map { ($0, $0.title) }
                    )
                    .disabled(model.dictation.phase == .recording || model.dictation.phase == .transcribing)
                } label: {
                    SettingsRowLabel(
                        title: "Maximum recording length",
                        subtitle: "Keybumps stops and transcribes automatically at this limit. Choose No limit to stop only with your Dictation shortcut."
                    )
                }
            }
        }.navigationTitle("Dictation")
    }
}

private struct DictationTranscriptionEngineSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup("Transcription model") {
            ForEach(DictationTranscriptionEngine.allCases) { engine in
                DictationTranscriptionEngineRow(engine: engine)
            }
            Text("Downloaded models stay on this Mac. Dictation audio is transcribed locally with the selected model.")
                .font(.system(size: SettingsTheme.subtitleSize))
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
                    .font(.system(size: SettingsTheme.subtitleSize))
                    .foregroundStyle(isCompatible ? Color.secondary : Color.orange)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.system(size: SettingsTheme.subtitleSize))
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
        SettingsPage {
            CapabilityControl(capability: .windowManagement)
            SettingsGroup {
                LabeledContent {
                    HStack(spacing: 8) {
                        Label(
                            isEnabled ? (isReady ? "Ready" : "Setup Needed") : "Off",
                            systemImage: isEnabled ? (isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "power"
                        )
                        .foregroundStyle(isEnabled ? (isReady ? .green : .orange) : .secondary)
                        if isEnabled && !isReady {
                            Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                        }
                    }
                } label: {
                    SettingsRowLabel(title: "Status", subtitle: "Window Manager needs Accessibility access to move other apps' windows.")
                }
                LabeledContent {
                    Button("Restore Defaults") { model.restoreDefaultWindowShortcuts() }
                        .disabled(recorder.identifier != nil)
                } label: {
                    SettingsRowLabel(title: "Default Shortcuts", subtitle: "Reset every window shortcut to its default.")
                }
            }
            if let error = recorder.error {
                SettingsNote(error).foregroundStyle(.orange)
            }
            SettingsGroup("Commands") {
                shortcutColumns(WindowSettingsLayout.primaryLeading, WindowSettingsLayout.primaryTrailing)
            }
            SettingsGroup {
                shortcutColumns(WindowSettingsLayout.secondaryLeading, WindowSettingsLayout.secondaryTrailing)
            }
        }
        .navigationTitle("Window Manager")
        .onDisappear { recorder.cancel() }
    }

    /// The two-column shortcut grid, one card per pair of columns.
    private func shortcutColumns(_ leading: [WindowAction], _ trailing: [WindowAction]) -> some View {
        HStack(alignment: .top, spacing: 28) {
            shortcutColumn(leading)
            shortcutColumn(trailing)
        }
        .padding(.vertical, 8)
    }

    private func shortcutColumn(_ actions: [WindowAction]) -> some View {
        VStack(spacing: 4) {
            ForEach(actions) { action in
                WindowCommandRow(
                    action: action,
                    shortcut: model.preferences.windowShortcut(for: action),
                    activeRecorderID: recorder.identifier,
                    liveModifiers: recorder.liveModifiers,
                    record: { beginRecording(action) },
                    clear: { model.finishWindowShortcutRecording(nil, for: action) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func beginRecording(_ action: WindowAction) {
        recorder.begin(
            identifier: action.rawValue,
            suspend: { model.beginShortcutRecording() },
            capture: { binding in model.finishWindowShortcutRecording(binding, for: action) },
            cancel: { model.cancelShortcutRecording() }
        )
    }
}

/// One cell of Window Manager's shortcut grid: preview, name, and hotkey field.
private struct WindowCommandRow: View {
    let action: WindowAction
    let shortcut: ShortcutBinding?
    let activeRecorderID: String?
    let liveModifiers: String
    let record: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            WindowActionPreviewView(action: action)
                .frame(width: 22, height: 16)
            Text(action.title)
                .lineLimit(1)
            Spacer(minLength: 12)
            SettingsHotkeyField(
                shortcut: shortcut,
                isRecording: activeRecorderID == action.rawValue,
                liveModifiers: liveModifiers,
                title: action.title,
                width: 136,
                record: record,
                clear: clear
            )
            .disabled(activeRecorderID != nil && activeRecorderID != action.rawValue)
        }
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
        SettingsPage {
            CapabilityControl(capability: .keyboardShortcutter)
            if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
               model.requiresPermissionRelaunch(for: .keyboardShortcutter) {
                SettingsGroup("Restart required") {
                    Text("Restart Keybumps to finish applying Accessibility or Input Monitoring access.")
                        .foregroundStyle(.secondary)
                    Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                }
            } else if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
                      !model.missingPermissions(for: .keyboardShortcutter).isEmpty {
                SettingsGroup("Setup required") {
                    Text("Keyboard Shortcutter needs Accessibility and Input Monitoring access to recognize supported actions outside this app.").foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            } else if model.preferences.enabledCapabilities.contains(.keyboardShortcutter),
                      model.permissionReadiness(for: [.keyboardShortcutter]).nativeNotificationNeedsAttention {
                SettingsGroup("Setup required") {
                    Text("Native macOS Banner needs Notifications access before it can appear.")
                        .foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            }
            SettingsGroup("Status") {
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
            SettingsGroup("Presentation channels") {
                ForEach(NotificationChannel.allCases.filter { $0 != .sound }) { channel in
                    channelControl(channel)
                }
            }
            SettingsGroup("Sound") {
                channelControl(.sound)
            }
            SettingsGroup("Keyboard symbols") {
                KeyboardGlyphLegendContent(entries: KeyboardShortcutRegistry.legendEntries)
            }
            SettingsGroup {
                Button("Open Keyboard Shortcutter History") { model.showKeyboardShortcutterHistory() }
                Text("View, filter, and clear detected actions in the quick switcher.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keyboard Shortcutter")
    }

    @ViewBuilder
    private func channelControl(_ channel: NotificationChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(channel.title)
                Spacer(minLength: 12)
                if channel.supportsPreview {
                    Button("Preview") { Task { await model.previewSample(channel: channel) } }
                }
                Toggle(channel.title, isOn: Binding(
                    get: { model.preferences.selectedChannels.contains(channel) },
                    set: { model.setChannel(channel, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            ForEach(model.previewOutcomes(for: channel).keys.sorted(by: { $0.rawValue < $1.rawValue })) { deliveredChannel in
                if let outcome = model.previewOutcomes(for: channel)[deliveredChannel] {
                    switch outcome {
                    case .delivered:
                        Text("\(deliveredChannel.title) preview sent")
                            .font(.system(size: SettingsTheme.subtitleSize))
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Text("\(deliveredChannel.title) preview failed: \(message)")
                            .font(.system(size: SettingsTheme.subtitleSize))
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
        SettingsPage {
            SettingsGroup {
                ForEach(PermissionSettingsPresentation.visiblePermissions) { permission in
                    PermissionRow(permission: permission, compact: true)
                }
                NotificationPermissionRow()
            }
        }
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
                Text("Notifications")
                Text("Lets the native macOS banner presentation appear in Notification Center.")
                    .font(.system(size: 12))
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
        }.navigationTitle("General")
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

/// The top of a capability's page, as on a Raycast extension page: its icon, name, and summary,
/// then its command with the hotkey. The enable switch lives in the toolbar.
private struct CapabilityControl: View {
    let capability: Capability
    var shortcut: CapabilityShortcut?

    var body: some View {
        let descriptor = capability.descriptor
        SettingsHero(
            systemImage: descriptor.systemImage,
            tint: descriptor.iconTint,
            title: descriptor.title,
            summary: descriptor.settingsPage?.summary ?? ""
        )
        if let shortcut {
            SettingsGroup("Commands") {
                CapabilityShortcutEditor(shortcut: shortcut)
            }
        }
    }
}

private struct CapabilityToggle: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        Toggle("Enable \(capability.title)", isOn: CapabilityToggleBinding(model: model, capability: capability).value)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(capability.descriptor.settingsPage?.disableExplanation ?? "Turn \(capability.title) on or off.")
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

    var body: some View {
        let binding = model.preferences.capabilityShortcut(for: shortcut)
        Group {
            HStack(spacing: 8) {
                SettingsCommandIcon(systemImage: shortcut.capability.systemImage, tint: shortcut.capability.descriptor.iconTint)
                Text(shortcut.title)
                Spacer(minLength: 12)
                SettingsHotkeyField(
                    shortcut: binding,
                    isRecording: recorder.identifier == shortcut.rawValue,
                    liveModifiers: recorder.liveModifiers,
                    title: shortcut.title,
                    record: {
                        recorder.begin(
                            identifier: shortcut.rawValue,
                            suspend: { model.beginShortcutRecording() },
                            capture: { model.finishCapabilityShortcutRecording($0, for: shortcut) },
                            cancel: { model.cancelShortcutRecording() }
                        )
                    },
                    clear: { model.finishCapabilityShortcutRecording(nil, for: shortcut) }
                )
                .accessibilityValue(shortcutAccessibilityValue(binding: binding))
                if binding?.usesSameKeys(as: shortcut.defaultBinding) != true {
                    SettingsIconButton(systemImage: "arrow.counterclockwise", help: "Restore default shortcut") {
                        model.restoreDefaultCapabilityShortcut(shortcut)
                    }
                    .disabled(recorder.identifier != nil)
                }
            }
            if let error = recorder.error {
                SettingsNote(error).foregroundStyle(.orange)
            }
            if let failure = model.shortcuts.failures[shortcut.ownerID] {
                SettingsNote(failure).foregroundStyle(.orange)
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
            } else {
                SettingsGroup(permission.title) { content(state: state, action: action) }
            }
        }
    }

    @ViewBuilder
    private func content(state: PermissionAuthorizationState, action: PermissionSettingsRowAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if compact { Text(permission.title) }
                Text(permission.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
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
    /// The modifier symbols held down while recording, shown live in the field.
    private(set) var liveModifiers = ""
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
        liveModifiers = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.liveModifiers = Self.symbols(for: event.modifierFlags)
                return event
            }
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
        liveModifiers = ""
        cancelAction = nil
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined(separator: " ")
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
