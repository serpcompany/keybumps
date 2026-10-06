import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case search = "Quick Search", clipboard = "Clipboard History", screenshotTools = "Screenshot Tools", dictation = "Dictation"
    case windows = "Window Manager", keyboardShortcutter = "Shortcut Coach", snippets = "Snippets", timer = "Timer"
    case emojiPicker = "Emoji Picker"
    case plugins = "Plugins", permissions = "Permissions", general = "General", account = "Account"
    var id: String { rawValue }

    /// Capability pages in registry order, then the fixed shell destinations. Each capability page
    /// has its own sidebar row, and the Plugins page lists them all.
    static var allCases: [SettingsSection] {
        CapabilityCatalog.descriptors.compactMap(\.settingsPage?.section) + [.plugins, .permissions, .general, .account]
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
        case .plugins: return "puzzlepiece.extension"
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

/// The Settings sidebar: the account row on top (outside these groups); General, Permissions, and
/// Plugins; then a row per plugin, the default ones (Quick Search first, then by name) and the added
/// ones in their own group below; filtered by search.
enum SettingsSidebar {
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What VoiceOver says for a row's attention mark.
    static func attentionLabel(_ count: Int, for section: SettingsSection) -> String {
        section == .permissions ? "\(count) permission items need attention" : "Needs attention"
    }

    static func groups(matching query: String) -> [[SettingsSection]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (SettingsSection) -> Bool = {
            trimmed.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(trimmed)
        }
        let app = [SettingsSection.general, .permissions, .plugins].filter(matches)
        let plugins = PluginsTable.sections.map { $0.plugins.filter(matches) }
        return ([app] + plugins).filter { !$0.isEmpty }
    }
}

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = SettingsNavigationHistory(
        selection: UITestLaunchConfiguration.current.openSettings ?? .permissions
    )
    @State private var query = ""

    /// Locked (no entitled license after onboarding): only the Account page, with the License group, is available.
    private var isLocked: Bool { model.preferences.didCompleteOnboarding && !model.isLicensed }
    private var visibleSelection: SettingsSection { isLocked ? .account : navigation.selection }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                SettingsSearchField(text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !SettingsSidebar.isSearching(query) {
                            SettingsAccountRow(isSelected: visibleSelection == .account) {
                                navigation.navigate(to: .account)
                            }
                            .accessibilityIdentifier("settings.sidebar.account")
                        }
                        ForEach(SettingsSidebar.groups(matching: query), id: \.self) { group in
                            VStack(spacing: 2) {
                                ForEach(group) { section in
                                    SettingsSidebarRow(
                                        section: section,
                                        isSelected: visibleSelection == section,
                                        attentionCount: model.settingsAttentionCount(for: section)
                                    ) {
                                        navigation.navigate(to: section)
                                    }
                                    .disabled(isLocked)
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
                if let page = visibleSelection.capability?.descriptor.settingsPage {
                    page.content()
                } else if visibleSelection == .plugins {
                    PluginsSettingsView { navigation.navigate(to: $0) }
                } else if visibleSelection == .permissions {
                    PermissionsView()
                } else if visibleSelection == .account {
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
                    if let capability = visibleSelection.capability {
                        CapabilityToggle(capability: capability)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.detail.\(visibleSelection.launchToken)")
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
        // A Quick Search command can ask for a capability's page, whether or not this window exists yet.
        .onAppear(perform: showRequestedSection)
        .onReceive(NotificationCenter.default.publisher(for: .settingsSectionRequested, object: MainWindowRouter.shared)) { _ in
            showRequestedSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDictationHistory)) { _ in model.showDictationHistory() }
    }

    private func showRequestedSection() {
        guard let section = MainWindowRouter.shared.consumeRequestedSection() else { return }
        navigation.navigate(to: section)
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
                SettingsIconTile(systemImage: section.icon, tint: section.iconTint, size: 22)
                Text(section.rawValue)
                    .font(.system(size: SettingsTheme.sidebarTextSize))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel(SettingsSidebar.attentionLabel(attentionCount, for: section))
                }
            }
            .frame(minHeight: 32)
        }
        .buttonStyle(SettingsSidebarButtonStyle(isSelected: isSelected))
    }
}

/// The Mac user's name and initials; Keybumps has no account service.
enum SettingsAccount {
    static let name: String = {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }()

    static let initials: String = {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }()
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
                    SettingsNote("Account")
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(SettingsSidebarButtonStyle(isSelected: isSelected))
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
            LicenseSettingsGroup()
        }
        .navigationTitle("Account")
    }
}

/// Activation, status, and deactivation for this Mac's license key (ADR 0002).
private struct LicenseSettingsGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var key = ""

    private var snapshot: LicenseSnapshot { model.licenseSnapshot }

    var body: some View {
        SettingsGroup("License") {
            LabeledContent {
                Text(statusText)
                    .accessibilityIdentifier("license.status")
            } label: {
                SettingsRowLabel(title: "Keybumps License", subtitle: statusDetail)
            }
            if case .locked(let reason) = snapshot.state, reason != .expired {
                LabeledContent {
                    Button(snapshot.isBusy ? "Checking…" : "Check Again") { Task { await model.refreshLicense(force: true) } }
                        .disabled(snapshot.isBusy)
                        .accessibilityIdentifier("license.check")
                } label: {
                    SettingsRowLabel(title: "Check license", subtitle: "Asks Polar about this key now.")
                }
            }
            if snapshot.state != .unlicensed {
                LabeledContent {
                    Button("Deactivate This Mac") { Task { await model.deactivateLicense() } }
                        .disabled(snapshot.isBusy)
                        .accessibilityIdentifier("license.deactivate")
                } label: {
                    SettingsRowLabel(title: "Move to another Mac", subtitle: "Frees this Mac’s activation so the key can be used elsewhere.")
                }
            }
            if !snapshot.isEntitled {
                HStack(spacing: 8) {
                    TextField("KEYBUMPS-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(activate)
                        .accessibilityIdentifier("license.key")
                    Button(snapshot.isBusy ? "Activating…" : "Activate", action: activate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(snapshot.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("license.activate")
                }
            }
            if let error = snapshot.lastError {
                SettingsNote(error.message)
                    .accessibilityIdentifier("license.error")
            }
            HStack(spacing: 12) {
                if !snapshot.isEntitled {
                    Button("Buy Keybumps") { openURL(LicenseLinks.buy) }
                }
                Button("Find My Key or Manage My Purchase") { openURL(LicenseLinks.customerPortal) }
            }
        }
        // Opening the page runs a check when one is due, so a Locked Mac recovers without waiting.
        .task { await model.refreshLicense() }
    }

    private func activate() {
        let entered = key
        Task {
            await model.activateLicense(key: entered)
            if model.isLicensed { key = "" }
        }
    }

    private var statusText: String {
        switch snapshot.state {
        case .active: return "Active"
        case .unlicensed: return "Not activated"
        case .locked(.notAccepted): return "Not accepted"
        case .locked(.expired): return "Expired"
        case .locked(.needsCheck): return "Check required"
        }
    }

    private var statusDetail: String {
        switch snapshot.state {
        case .active(let check):
            let checked = check.validatedAt.formatted(date: .abbreviated, time: .omitted)
            return "Key \(check.maskedKey) · Checked \(checked)"
        case .unlicensed:
            return "Enter the license key from your Polar receipt to use Keybumps on this Mac."
        case .locked(.notAccepted):
            return "Polar no longer accepts this key on this Mac. It may have been refunded or revoked, or this Mac was deactivated in the customer portal. Check again, or enter your key to activate this Mac again."
        case .locked(.expired):
            return "This license has expired."
        case .locked(.needsCheck):
            return "Keybumps hasn’t been able to check your license for 45 days. Connect to the internet and check again."
        }
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    var prompt = "Search settings…"
    var identifier = "settings.search"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsTheme.titleSize))
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .background(SettingsTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityIdentifier(identifier)
    }
}

struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .quickSearch, shortcuts: [.quickSearch])
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
            CapabilityControl(capability: .clipboardHistory, shortcuts: [.clipboardHistory])
            SettingsGroup("History") {
                SettingsNote("Keeps the \(ClipboardHistoryService.capacity) most recent copied text and image items on this Mac. Images up to 50 MB each are stored separately, so a full history can use several gigabytes. Copied secrets remain until you delete them or newer copies replace them.")
            }
        }.navigationTitle("Clipboard History")
    }
}

struct ScreenshotToolsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            CapabilityControl(
                capability: .screenshotTools,
                shortcuts: [.screenshotScreen, .screenshotScreenAndEdit, .screenshotArea]
            )
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
                }
                status
                Toggle("Copy new screenshots to the clipboard", isOn: Binding(
                    get: { model.preferences.copiesScreenshotsToClipboard },
                    set: { model.preferences.copiesScreenshotsToClipboard = $0 }
                ))
                SettingsNote("Screenshots from these hotkeys, and ones you take with macOS's own ⇧⌘5, are saved where macOS saves screenshots and appear in Clipboard History, ready to paste. With Copy new screenshots on, each also goes on the clipboard unless you've copied something since it was saved; Screenshot Screen and Edit copies only when you Save. While Screenshot Tools is on, Keybumps uses ⇧⌘3 and ⇧⌘4 in place of macOS's own; turning it off gives them back.")
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
            SettingsNote("Allow access in System Settings › Privacy & Security › Files & Folders, then return to Keybumps.")
            Button("Open Privacy & Security") { model.permissions.openSystemSettings(.filesAndFolders) }
        case .folderUnavailable(let folder):
            Label("\(FileManager.default.displayName(atPath: folder.path)) is unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            SettingsNote("Keybumps keeps checking and resumes when the screenshot folder is available.")
        }
    }
}

struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .dictation, shortcuts: [.dictation, .cancelDictation])
            let missingPermissions = model.missingPermissions(for: .dictation)
            if model.preferences.enabledCapabilities.contains(.dictation), !missingPermissions.isEmpty {
                SettingsGroup("Setup required") {
                    Text(DictationSetupCopy.settingsNote(missing: missingPermissions))
                        .foregroundStyle(.secondary)
                    OpenPermissionsButton()
                }
            }
            SettingsGroup("Language") {
                LabeledContent("Recognition language") {
                    SettingsDropdown(
                        title: "Recognition language",
                        selection: Binding(get: { model.preferences.dictationLanguage }, set: { model.setDictationLanguage($0) }),
                        options: model.dictation.availableLanguages.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
                    )
                    .accessibilityIdentifier("settings.dictation.language")
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
                    .accessibilityIdentifier("settings.dictation.durationLimit")
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
            SettingsNote("Downloaded models stay on this Mac. Dictation audio is transcribed locally with the selected model.")
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
                HStack(spacing: 6) {
                    Text(engine.title)
                    if engine.isRecommended {
                        SettingsBadge("Recommended")
                            .accessibilityIdentifier("dictationEngine.recommended")
                    }
                }
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
                            OpenPermissionsButton()
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
                SettingsNote(error, tint: .orange)
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

    /// The two-column shortcut grid, one card per pair of columns, or one column when the page is
    /// too narrow for two without cutting off names.
    private func shortcutColumns(_ leading: [WindowAction], _ trailing: [WindowAction]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                shortcutColumn(leading)
                shortcutColumn(trailing)
            }
            VStack(spacing: 4) {
                shortcutColumn(leading)
                shortcutColumn(trailing)
            }
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
                    liveModifiers: recorder.identifier == action.rawValue ? recorder.liveModifiers : "",
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
                    Text("Shortcut Coach needs Accessibility and Input Monitoring access to recognize supported actions outside this app.").foregroundStyle(.secondary)
                    OpenPermissionsButton()
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
                    Label("Shortcut Coach needs to reconnect", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { model.retryDetection() }
                }
                Button("Send Test Suggestion") { model.showSampleTip() }
                    .disabled(!isEnabled || !readiness.isReady)
            }
            SettingsGroup("Keyboard symbols") {
                KeyboardGlyphLegendContent(entries: KeyboardShortcutRegistry.legendEntries)
            }
            SettingsGroup {
                Toggle("Show Hotkeys tab in the Command Palette", isOn: Binding(
                    get: { model.preferences.showsHotkeysTab },
                    set: { model.preferences.showsHotkeysTab = $0 }
                ))
                Button("Open Shortcut Coach History") { model.showKeyboardShortcutterHistory() }
                Text("View, filter, and clear detected actions in the Command Palette.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shortcut Coach")
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
                    PermissionRow(permission: permission)
                }
            }
        }
        .navigationTitle("Permissions")
        .task {
            await model.monitorSystemPermissionChanges()
        }
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
            SettingsGroup("Crash reports") {
                Toggle("Send crash reports", isOn: Binding(
                    get: { model.preferences.sendsCrashReports },
                    set: model.setSendsCrashReports
                ))
                .accessibilityIdentifier("settings.general.sendsCrashReports")
                SettingsNote(CrashReportingCopy.settingsNote)
            }
            SettingsGroup("Problems") {
                LabeledContent {
                    Button("Report a Problem…") { model.showProblemReport() }
                        .accessibilityIdentifier("settings.general.reportProblem")
                } label: {
                    SettingsRowLabel(
                        title: "Report a Problem",
                        subtitle: "Something not working, like a button or menu that doesn't respond? Tell us, and Keybumps attaches your Mac's details."
                    )
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
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 96, height: 96)
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
            Text("After setup, activate your license key in Settings → Account.")
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
                    PermissionRow(permission: permission)
                    Text("After changing a macOS setting, return to Keybumps. This step advances as soon as macOS confirms access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
/// a banner while it's turned off, then its command with the hotkey. The enable switch lives in the
/// toolbar.
struct CapabilityControl: View {
    let capability: Capability
    var shortcuts: [CapabilityShortcut] = []
    var byline: String?

    var body: some View {
        let descriptor = capability.descriptor
        SettingsHero(
            systemImage: descriptor.systemImage,
            tint: descriptor.iconTint,
            title: descriptor.title,
            summary: descriptor.settingsPage?.summary ?? "",
            byline: byline
        )
        CapabilityOffBanner(capability: capability)
        if !shortcuts.isEmpty {
            SettingsGroup("Commands") {
                ForEach(shortcuts) { CapabilityShortcutEditor(shortcut: $0) }
            }
        }
    }
}

/// Says plainly, under a plugin's header, that the plugin is off, with a button to turn it on
/// (#254). The toolbar switch alone was easy to miss, such as for a plugin that ships off and is
/// opened from Quick Search. It goes away once the plugin is on.
struct CapabilityOffBanner: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        if !model.preferences.enabledCapabilities.contains(capability) {
            HStack(spacing: 12) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                SettingsRowLabel(title: Self.title(capability), subtitle: Self.subtitle)
                Spacer(minLength: 12)
                Button("Turn On") { model.setCapability(capability, enabled: true) }
                    .buttonStyle(SettingsButtonStyle(isProminent: true))
                    .accessibilityLabel("Turn On \(capability.title)")
                    .accessibilityIdentifier("capability.offBanner.turnOn.\(capability.rawValue)")
            }
            .padding(.horizontal, SettingsTheme.rowInset + 3)
            .padding(.vertical, 12)
            // The fill and border are both behind the row: a border overlaid on top took the Turn
            // On button's clicks.
            .background {
                let shape = RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                shape.fill(Color.orange.opacity(0.12))
                    .overlay(shape.strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capability.offBanner.\(capability.rawValue)")
        }
    }

    static func title(_ capability: Capability) -> String { "\(capability.title) is turned off" }
    static let subtitle = "Its shortcuts and features don't work until you turn it on."
}

/// A plugin's switch: on its page's toolbar, and in its row on the Plugins page.
struct CapabilityToggle: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        Toggle("Enable \(capability.title)", isOn: CapabilityToggleBinding(model: model, capability: capability).value)
            .settingsCompactSwitch()
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
                SettingsIconTile(systemImage: shortcut.capability.systemImage, tint: shortcut.capability.descriptor.iconTint, size: 16)
                SettingsRowLabel(title: shortcut.title, subtitle: shortcut.detail)
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
                // A shortcut that starts unassigned has no default to restore; its field clears it.
                if let defaultBinding = shortcut.defaultBinding, binding?.usesSameKeys(as: defaultBinding) != true {
                    SettingsIconButton(systemImage: "arrow.counterclockwise", help: "Restore default shortcut") {
                        model.restoreDefaultCapabilityShortcut(shortcut)
                    }
                    .disabled(recorder.identifier != nil)
                }
            }
            if let error = recorder.error {
                SettingsNote(error, tint: .orange)
            }
            if let failure = model.shortcuts.failures[shortcut.ownerID] {
                SettingsNote(failure, tint: .orange)
            }
        }
        .onDisappear { recorder.cancel() }
    }
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let permission: MacPermission
    /// For a permission a plugin can use but doesn't need: why it helps. The row is then marked
    /// Optional, and a missing grant isn't shown as a problem.
    var optionalReason: String?

    var body: some View {
        let readiness = model.permissionReadiness
        let state = readiness.state(for: permission)
        let action = PermissionSettingsRowAction.resolve(
            permission: permission,
            state: state,
            requiresRelaunch: model.requiresPermissionRelaunch(permission)
        )
        content(state: state, action: action)
    }

    /// The status beside the row. An optional permission that isn't granted reads "Not Granted",
    /// never "Required".
    static func status(_ state: PermissionAuthorizationState, requiresRelaunch: Bool, isOptional: Bool) -> String {
        if requiresRelaunch { return "Restart Required" }
        return isOptional && !state.isGranted ? "Not Granted" : state.rawValue
    }

    @ViewBuilder
    private func content(state: PermissionAuthorizationState, action: PermissionSettingsRowAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(title: optionalReason == nil ? permission.title : "\(permission.title) (Optional)",
                             subtitle: optionalReason ?? permission.explanation)
            Spacer()
            Text(Self.status(state, requiresRelaunch: model.requiresPermissionRelaunch(permission), isOptional: optionalReason != nil))
                .font(.caption.weight(.medium))
                .foregroundStyle(state.isGranted ? .green : (optionalReason == nil ? .orange : .secondary))
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

/// Jumps to the Permissions page from a capability page.
struct OpenPermissionsButton: View {
    var body: some View {
        Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
    }
}

extension Notification.Name {
    static let openPermissions = Notification.Name("Keybumps.openPermissions")
    static let openDictationHistory = Notification.Name("Keybumps.openDictationHistory")
}

@MainActor @Observable
final class ShortcutRecorderState {
    /// Whether any hotkey field is recording, so Escape cancels it rather than closing Settings.
    @ObservationIgnored static private(set) var isRecordingAny = false
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
        Self.isRecordingAny = true
        error = nil
        cancelAction = cancel
        suspend()
        liveModifiers = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.liveModifiers = ShortcutBinding.modifierSymbols(for: event.modifierFlags)
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
        Self.isRecordingAny = false
        error = nil
        liveModifiers = ""
        cancelAction = nil
    }


    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// The Settings window's sizes, and how it is kept on its screen (#294).
enum SettingsWindowFrame {
    /// Low enough that the window, with its title bar and toolbar, fits above the Dock on the
    /// smallest screens: CI's 1024×768 leaves 674pt (a 31pt menu bar and a 63pt Dock), and a 13-inch
    /// MacBook at Larger Text (1024×640) about 546pt. Every page and the sidebar scroll.
    static let minimumContentSize = CGSize(width: 960, height: 440)
    /// What Settings asks for when macOS has nothing saved; `SettingsWindowFiller` fits it to the
    /// screen once it shows.
    static let defaultContentSize = CGSize(width: 1240, height: 944)

    /// The frame for a window wider or taller than its screen's visible frame (the part the menu
    /// bar and Dock leave): shrunk to that frame, but not below `minimumSize`, and moved inside it,
    /// keeping its top edge on the screen when even the minimum doesn't fit. Nil when the window is
    /// no larger than the visible frame, so its position stays as the person put it, or when it is
    /// already as small and as far inside as it can be, so it doesn't jump each time.
    static func fitted(_ frame: CGRect, in visible: CGRect, minimumSize: CGSize = .zero) -> CGRect? {
        guard frame.width > visible.width || frame.height > visible.height else { return nil }
        let width = max(min(frame.width, visible.width), minimumSize.width)
        let height = max(min(frame.height, visible.height), minimumSize.height)
        let fitted = CGRect(
            x: max(min(frame.minX, visible.maxX - width), visible.minX),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
        return fitted == frame ? nil : fitted
    }
}

/// Fills the screen with the Settings window the first time it opens, as the window's Zoom does,
/// leaving the menu bar and Dock showing. After that macOS restores whatever size it was left at,
/// except that a window larger than its screen's visible frame is shrunk to fit whenever it comes
/// forward, moves to another screen, or the screen changes (the Dock resized or moved, the
/// resolution changed), so it never reaches under the Dock (#294). Its position is kept where it
/// can be; a size reaching under the Dock is not.
struct SettingsWindowFiller: NSViewRepresentable {
    let preferences: AppPreferences

    func makeNSView(context: Context) -> NSView { FillerView(preferences: preferences) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FillerView: NSView {
        private let preferences: AppPreferences
        private var observers: [Any] = []
        private var workspaceObservers: [Any] = []

        init(preferences: AppPreferences) {
            self.preferences = preferences
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            observers = []
            workspaceObservers = []
            guard let window, !UnitTestHost.isActive else { return }
            // Each time Settings comes forward or changes screen. Until it has filled once, this
            // fills, so a first open that was closed straight away fills the next time instead.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fillOrFit() }
                })
            }
            // The screen's visible frame changing under a window that stays key, such as the Dock
            // moving or the resolution changing.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fillOrFit() }
            })
            // A full Dock resizes as apps open and quit, without that notification: once its icons
            // have settled, fit again (#294, seen on CI's 1024pt-wide screen).
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.fillOrFit() }
                })
            }
            // After this turn, so the frame macOS restores for the window doesn't replace it. Then
            // again shortly after, as the Dock may still be resizing for an app that just quit.
            DispatchQueue.main.async { [weak self] in self?.fillOrFit() }
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.fillOrFit() }
            }
        }

        private func fillOrFit() {
            if preferences.didFillSettingsWindow {
                fitToScreen()
            } else {
                fill(attempt: 1)
            }
        }

        /// Fills the screen, then checks once the window has settled: if macOS restored a saved
        /// size over it, fills again, up to three times. Only a fill that held, or the last try,
        /// counts as the first open. A window that isn't showing is left alone, so this never
        /// brings a closed Settings window back.
        private func fill(attempt: Int) {
            guard let window, window.isVisible, let screen = window.screen ?? NSScreen.main,
                  !preferences.didFillSettingsWindow else { return }
            window.setFrame(screen.visibleFrame, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let window = self.window, window.isVisible, !preferences.didFillSettingsWindow else { return }
                // Against the visible frame now, which the Dock may have changed meanwhile.
                if window.frame != (window.screen ?? screen).visibleFrame, attempt < 3 {
                    fill(attempt: attempt + 1)
                } else {
                    preferences.didFillSettingsWindow = true
                    fitToScreen()
                }
            }
        }

        /// Shrinks a window larger than its screen's visible frame to fit, such as a frame saved
        /// on a larger screen or before #294. Waits while a mouse button is down, so a window being
        /// dragged to another screen is fitted once it is let go. Full screen is left alone.
        private func fitToScreen() {
            guard let window, window.isVisible, !window.styleMask.contains(.fullScreen),
                  let screen = window.screen else { return }
            guard NSEvent.pressedMouseButtons == 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fitToScreen() }
                return
            }
            // AppKit's own minimum frame for the content's minimum, title bar and toolbar included.
            let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            let minimum = CGSize(
                width: max(window.minSize.width, contentMinimum.width),
                height: max(window.minSize.height, contentMinimum.height)
            )
            if let fitted = SettingsWindowFrame.fitted(window.frame, in: screen.visibleFrame, minimumSize: minimum) {
                window.setFrame(fitted, display: true)
            }
        }
    }
}

/// Escape closes the Settings window like Command-W, unless something inside it is using Escape:
/// a hotkey field that is recording, a sheet or alert, or a text field with text in it.
struct SettingsEscapeCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { EscapeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class EscapeView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let window = self?.window, SettingsEscapePolicy.shouldClose(event: event, window: window) else {
                    return event
                }
                window.performClose(nil)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

@MainActor
enum SettingsEscapePolicy {
    static func shouldClose(event: NSEvent, window: NSWindow) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !ShortcutRecorderState.isRecordingAny else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.string.isEmpty {
            return false
        }
        return true
    }
}
