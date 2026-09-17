import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case setup = "Setup", search = "Quick Search", clipboard = "Clipboard History", dictation = "Dictation", dictationHistory = "Dictation History"
    case windows = "Window Management", coaching = "Key Bumps", permissions = "Permissions", general = "General", about = "About"
    var id: String { rawValue }
    var icon: String { switch self { case .setup: "checklist"; case .search: "magnifyingglass"; case .clipboard: "clipboard"; case .dictation: "waveform"; case .dictationHistory: "clock.arrow.circlepath"; case .windows: "rectangle.split.2x1"; case .coaching: "keyboard"; case .permissions: "hand.raised"; case .general: "gearshape"; case .about: "info.circle" } }
}

struct SettingsNavigationHistory: Equatable {
    private(set) var selection: SettingsSection = .setup
    private(set) var backStack: [SettingsSection] = []

    var canGoBack: Bool { !backStack.isEmpty }

    mutating func navigate(to section: SettingsSection) {
        guard section != selection else { return }
        backStack.append(selection)
        selection = section
    }

    mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        selection = previous
    }
}

enum SetupCapabilityAction: Equatable {
    case showQuickSearch
    case showClipboardHistory
    case navigate(SettingsSection)
    case beginPermissionWalkthrough(Capability)

    static func resolve(
        capability: Capability,
        isEnabled: Bool,
        missingPermissions: [MacPermission]
    ) -> SetupCapabilityAction {
        guard isEnabled else { return .navigate(destination(for: capability)) }
        guard missingPermissions.isEmpty else { return .beginPermissionWalkthrough(capability) }
        return switch capability {
        case .quickSearch: .showQuickSearch
        case .clipboardHistory: .showClipboardHistory
        case .dictation, .windowManagement, .shortcutCoaching: .navigate(destination(for: capability))
        }
    }

    private static func destination(for capability: Capability) -> SettingsSection {
        switch capability {
        case .quickSearch: .search
        case .clipboardHistory: .clipboard
        case .dictation: .dictation
        case .windowManagement: .windows
        case .shortcutCoaching: .coaching
        }
    }
}

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = SettingsNavigationHistory()

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selectionBinding) { section in Label(section.rawValue, systemImage: section.icon).tag(section) }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch navigation.selection {
                case .setup: SetupView(onNavigate: { navigation.navigate(to: $0) })
                case .search: QuickSearchSettingsView()
                case .clipboard: ClipboardSettingsView()
                case .dictation: DictationSettingsView()
                case .dictationHistory: DictationHistoryView()
                case .windows: WindowSettingsView()
                case .coaching: KeyBumpsSettingsView()
                case .permissions: PermissionsView()
                case .general: GeneralView()
                case .about: AboutView()
                }
            }.environment(model)
        }
        .navigationTitle("SuperMac")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    navigation.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!navigation.canGoBack)
                .help("Return to the previous Settings screen")
                .keyboardShortcut("[", modifiers: .command)
            }
        }
        .sheet(isPresented: Binding(get: { !model.preferences.didCompleteOnboarding }, set: { _ in })) { OnboardingView().environment(model).interactiveDismissDisabled() }
        .onReceive(NotificationCenter.default.publisher(for: .openPermissions)) { _ in navigation.navigate(to: .permissions) }
        .onReceive(NotificationCenter.default.publisher(for: .openDictationHistory)) { _ in navigation.navigate(to: .dictationHistory) }
    }

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { navigation.selection },
            set: { section in
                guard let section else { return }
                navigation.navigate(to: section)
            }
        )
    }
}

private struct SetupView: View {
    @Environment(AppModel.self) private var model
    let onNavigate: (SettingsSection) -> Void

    var body: some View {
        Form {
            Section("Readiness") {
                ForEach(Capability.allCases) { capability in
                    HStack(spacing: 14) {
                        Image(systemName: capability.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.title).font(.headline)
                            Text(detail(for: capability)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(status(for: capability))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor(for: capability))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor(for: capability).opacity(0.12), in: Capsule())
                        Button(actionTitle(for: capability)) { performAction(for: capability) }
                            .accessibilityLabel("\(actionTitle(for: capability)) \(capability.title)")
                    }
                    .padding(.vertical, 5)
                }
            }
            if !model.shortcuts.failures.isEmpty {
                Section("Shortcut conflicts") { ForEach(model.shortcuts.failures.keys.sorted(), id: \.self) { key in Text(model.shortcuts.failures[key] ?? key).foregroundStyle(.orange) } }
            }
            Section {
                Button("Review All Permissions…") { onNavigate(.permissions) }
                    .accessibilityLabel("Review all permissions")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }

    private func status(for capability: Capability) -> String {
        guard model.preferences.enabledCapabilities.contains(capability) else { return "Off" }
        return model.missingPermissions(for: capability).isEmpty ? "Ready" : "Setup Needed"
    }

    private func detail(for capability: Capability) -> String {
        guard model.preferences.enabledCapabilities.contains(capability) else { return "Disabled in \(capability.title) settings" }
        let missing = model.missingPermissions(for: capability)
        if !missing.isEmpty { return "Needs \(missing.map(\.title).joined(separator: " and "))" }
        return switch capability {
        case .quickSearch: shortcutDetail(for: .quickSearch, action: "search apps, files, and folders")
        case .clipboardHistory: shortcutDetail(for: .clipboardHistory, action: "open your latest 10 copied text and image items")
        case .dictation: shortcutDetail(for: .dictation, action: "start or stop local dictation")
        case .windowManagement: "Your Rectangle shortcut profile is active"
        case .shortcutCoaching: "Supported manual actions are being monitored"
        }
    }

    private func shortcutDetail(for shortcut: CapabilityShortcut, action: String) -> String {
        guard let binding = model.preferences.capabilityShortcut(for: shortcut) else {
            return "No keyboard shortcut assigned; open from Settings"
        }
        return "Press \(binding.displayName) to \(action)"
    }

    private func statusColor(for capability: Capability) -> Color {
        if !model.preferences.enabledCapabilities.contains(capability) { return .secondary }
        return model.missingPermissions(for: capability).isEmpty ? .green : .orange
    }

    private func actionTitle(for capability: Capability) -> String {
        if !model.preferences.enabledCapabilities.contains(capability) { return "Set Up" }
        if !model.missingPermissions(for: capability).isEmpty { return "Grant Permission" }
        return switch capability {
        case .quickSearch, .clipboardHistory: "Open"
        case .dictation, .windowManagement, .shortcutCoaching: "Settings"
        }
    }

    private func performAction(for capability: Capability) {
        let action = SetupCapabilityAction.resolve(
            capability: capability,
            isEnabled: model.preferences.enabledCapabilities.contains(capability),
            missingPermissions: model.missingPermissions(for: capability)
        )
        switch action {
        case .showQuickSearch:
            model.showQuickSearch()
        case .showClipboardHistory:
            model.showClipboardHistory()
        case .navigate(let section):
            onNavigate(section)
        case .beginPermissionWalkthrough(let capability):
            model.beginPermissionWalkthrough(for: capability)
        }
    }
}

private struct QuickSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .quickSearch)
            CapabilityShortcutEditor(shortcut: .quickSearch)
            Section { Button("Open Quick Search") { model.showQuickSearch() }.disabled(!model.preferences.enabledCapabilities.contains(.quickSearch)) }
            Section { Text("Searches installed applications and Spotlight-indexed local files and folders. Web search and workflows are outside this MVP.").foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("Quick Search")
    }
}

private struct ClipboardSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .clipboardHistory)
            CapabilityShortcutEditor(shortcut: .clipboardHistory)
            Section("Local history") {
                Button("Open Clipboard History") { model.showClipboardHistory() }
                    .disabled(!model.preferences.enabledCapabilities.contains(.clipboardHistory))
                LabeledContent("Stored items", value: "\(model.clipboard.entries.count) of 10")
                HistoryClearButton(
                    title: "Clear History",
                    confirmationTitle: "Clear clipboard history?",
                    confirmationMessage: "This permanently removes all clipboard items saved by SuperMac.",
                    destructiveActionTitle: "Clear Clipboard History",
                    disabled: model.clipboard.entries.isEmpty,
                    clear: model.clipboard.clear
                )
                Text("The latest ten text or image items are stored only on this Mac. Image media is capped at 50 MB per item. Copied secrets remain until removed or displaced.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("Clipboard History")
    }
}

private struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .dictation)
            CapabilityShortcutEditor(shortcut: .dictation)
            if !model.missingPermissions(for: .dictation).isEmpty {
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
                Text("Only languages with Apple on-device recognition on this Mac are shown.").foregroundStyle(.secondary)
            }
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
                Text("SuperMac stops and transcribes automatically at this limit. Choose No limit to stop only with your Dictation shortcut.")
                    .foregroundStyle(.secondary)
                Text("Long recordings use more disk space and may take longer to transcribe. If transcription fails, SuperMac keeps the audio in Dictation History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Dictation", value: model.dictation.phase.label)
                LabeledContent("Saved dictations", value: "\(model.dictationHistory.entries.count)")
                Button("Open Dictation History") { NotificationCenter.default.post(name: .openDictationHistory, object: nil) }
                if let error = model.dictation.lastError { Text(error).foregroundStyle(.orange) }
                if model.dictation.recoveredTranscript != nil {
                    Text("The latest transcript is kept locally so it can be recovered if insertion fails.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Last Dictation") { model.dictation.copyRecoveredTranscript() }
                        Button("Clear Last Dictation", role: .destructive) { model.dictation.clearRecoveredTranscript() }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Dictation")
    }
}

private struct WindowSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ShortcutRecorderState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Toggle("Enable Window Management", isOn: Binding(
                    get: { model.preferences.enabledCapabilities.contains(.windowManagement) },
                    set: { model.setCapability(.windowManagement, enabled: $0) }
                ))
                Spacer()
                Label(
                    model.windows.isAccessibilityGranted ? "Ready" : "Setup Needed",
                    systemImage: model.windows.isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.windows.isAccessibilityGranted ? .green : .orange)
                if !model.windows.isAccessibilityGranted {
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
    }

    private func shortcutColumns(
        leading: [SuperMacWindowAction],
        trailing: [SuperMacWindowAction]
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

    private func beginRecording(_ action: SuperMacWindowAction) {
        recorder.begin(
            identifier: action.rawValue,
            suspend: { model.beginShortcutRecording() },
            capture: { binding in model.finishWindowShortcutRecording(binding, for: action) },
            cancel: { model.cancelShortcutRecording() }
        )
    }

    private func clearShortcut(_ action: SuperMacWindowAction) {
        model.finishWindowShortcutRecording(nil, for: action)
    }
}

private struct WindowShortcutColumn: View {
    let actions: [SuperMacWindowAction]
    let activeRecorderID: String?
    let binding: (SuperMacWindowAction) -> ShortcutBinding?
    let record: (SuperMacWindowAction) -> Void
    let clear: (SuperMacWindowAction) -> Void

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
    let action: SuperMacWindowAction

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

private struct KeyBumpsSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CapabilityControl(capability: .shortcutCoaching)
            if !model.missingPermissions(for: .shortcutCoaching).isEmpty {
                Section("Setup required") {
                    Text("Key Bumps needs Accessibility and Input Monitoring access to recognize supported actions outside this app.").foregroundStyle(.secondary)
                    Button("Open Permissions…") { NotificationCenter.default.post(name: .openPermissions, object: nil) }
                }
            }
            Section("Status") {
                if model.detectorStatus == .monitoring {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if model.missingPermissions(for: .shortcutCoaching).isEmpty {
                    Label("Key Bumps needs to reconnect", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { model.retryDetection() }
                }
                Button("Send Test Key Bump") { Task { await model.deliverSample() } }
            }
            Section("Presentation channels") {
                ForEach(NotificationChannel.allCases.filter { $0 != .sound }) { channel in
                    channelControl(channel)
                }
            }
            Section("Sound") {
                channelControl(.sound)
            }
            Section("History") {
                LabeledContent("Events", value: "\(model.inbox.events.count)")
                Button("Mark All Read") { model.markAllRead() }.disabled(model.unreadCount == 0)
                HistoryClearButton(
                    title: "Clear Key Bumps History",
                    confirmationTitle: "Clear Key Bumps history?",
                    confirmationMessage: "This permanently removes all saved Key Bumps events.",
                    destructiveActionTitle: "Clear Key Bumps History",
                    disabled: model.inbox.events.isEmpty,
                    clear: model.clearHistory
                )
            }
            Section("Key Bumps History") {
                if model.inbox.events.isEmpty {
                    Text("Manual actions with known shortcuts will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.inbox.events.prefix(30)) { event in
                        Button { model.markRead(event.id) } label: {
                            CoachingEventRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Supported shortcuts") {
                ForEach(ShortcutCatalog.tips) { tip in
                    LabeledContent("\(tip.applicationName): \(tip.actionTitle)", value: tip.shortcut)
                }
            }
        }.formStyle(.grouped).navigationTitle("Key Bumps")
    }

    @ViewBuilder
    private func channelControl(_ channel: NotificationChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(channel.title, isOn: Binding(
                    get: { model.preferences.selectedChannels.contains(channel) },
                    set: { model.setChannel(channel, enabled: $0) }
                ))
                Button("Preview") { Task { await model.previewSample(channel: channel) } }
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

private struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section {
                PermissionWalkthroughView()
            }
            Section {
                DisclosureGroup("Review individual permissions") {
                    VStack(spacing: 8) {
                        ForEach(MacPermission.allCases) { permission in
                            PermissionRow(permission: permission, compact: true)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            Section {
                Button("Refresh Status") { model.refreshPermissions() }
                Text("After changing a switch in System Settings, return here and the status will refresh automatically.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }
}

private struct GeneralView: View {
    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Automatic updates", value: "Not configured")
                Text("This local preview has no release feed, so update controls are intentionally unavailable. Updates will be enabled only in a signed distributable release.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle("General")
    }
}

private struct AboutView: View {
    var body: some View { VStack(spacing: 16) { Image(ProductIdentity.inAppBrandImageName).resizable().scaledToFit().frame(width: 100, height: 100); Text("SuperMac").font(.largeTitle.bold()); Text("Functional MVP · local-only").foregroundStyle(.secondary); Text("Window Management includes software derived from Rectangle. See LICENSE.rectangle in the source distribution.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40).navigationTitle("About") }
}

private struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(ProductIdentity.inAppBrandImageName).resizable().scaledToFit().frame(width: 72, height: 72)
            Group {
                switch step {
                case 0:
                    VStack(spacing: 12) { Text("Welcome to SuperMac").font(.largeTitle.bold()); Text("Set up the local preview").font(.headline); Text("This build is ready for hands-on testing. Purchasing and license activation are not part of this local preview.").foregroundStyle(.secondary).multilineTextAlignment(.center) }
                case 1:
                    VStack(spacing: 12) { Text("Five capabilities, one app").font(.largeTitle.bold()); ForEach(Capability.allCases) { Label($0.title, systemImage: $0.systemImage) } }
                case 2:
                    VStack(spacing: 12) {
                        Text("Enable macOS permissions").font(.largeTitle.bold())
                        Text("Grant one permission at a time. When macOS reports it enabled, the next required permission appears automatically.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        PermissionWalkthroughView(compact: true)
                    }
                case 3:
                    VStack(spacing: 12) { Text("Resolve shortcut conflicts").font(.largeTitle.bold()); ForEach(ReferenceApp.allCases) { app in HStack { Text(app.name); Spacer(); if !model.conflicts.isRunning(app) { Text("Not running").foregroundStyle(.secondary) } else { Button("Quit") { model.conflicts.quit(app) } } } } }
                default:
                    VStack(spacing: 12) { Text("Ready").font(.largeTitle.bold()); Text("Setup will show what is working and what still needs attention.").foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: 620)
            Spacer()
            HStack { if step > 0 { Button("Back") { step -= 1 } }; Spacer(); if step < 4 { Button("Continue") { step += 1 }.buttonStyle(.borderedProminent) } else { Button("Start SuperMac") { model.completeOnboarding() }.buttonStyle(.borderedProminent) } }
        }.padding(36).frame(width: 760, height: 520)
    }
}

private struct PermissionWalkthroughView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let progress = model.permissionSetupProgress
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(progress.completedCount) of \(progress.totalCount) complete")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let permission = progress.currentPermission {
                PermissionRow(permission: permission, compact: true)
                Text("After changing a macOS setting, return to SuperMac. This step advances as soon as macOS confirms access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("All permissions needed by your enabled features are ready.", systemImage: "checkmark.circle.fill")
                    .font(compact ? .headline : .body)
                    .foregroundStyle(.green)
            }
        }
        .padding(compact ? 12 : 4)
        .background(compact ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided permission setup")
    }
}

private struct CapabilityControl: View {
    @Environment(AppModel.self) private var model
    let capability: Capability

    var body: some View {
        Section("Capability") {
            Toggle("Enable \(capability.title)", isOn: Binding(
                get: { model.preferences.enabledCapabilities.contains(capability) },
                set: { model.setCapability(capability, enabled: $0) }
            ))
            if let disableExplanation {
                Text(disableExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disableExplanation: String? {
        switch capability {
        case .quickSearch: "Turning this off closes Quick Search and releases its global shortcut."
        case .clipboardHistory: "Turning this off stops clipboard monitoring, closes its panel, and releases its global shortcut."
        case .dictation: "Turning this off cancels active Dictation and releases its global shortcut."
        case .windowManagement: "Turning this off stops drag-to-snap and releases all window shortcuts."
        case .shortcutCoaching: nil
        }
    }
}

private struct CapabilityShortcutEditor: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ShortcutRecorderState()
    let shortcut: CapabilityShortcut

    var body: some View {
        let binding = model.preferences.capabilityShortcut(for: shortcut)
        Section("Shortcut") {
            Text("Record a new shortcut, clear it, or restore the default. Escape cancels recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(shortcut.title)
                Spacer()
                Button(recorder.identifier == shortcut.rawValue ? "Press shortcut…" : (binding?.displayName ?? "Record Shortcut")) {
                    recorder.begin(
                        identifier: shortcut.rawValue,
                        suspend: { model.beginShortcutRecording() },
                        capture: { model.finishCapabilityShortcutRecording($0, for: shortcut) },
                        cancel: { model.cancelShortcutRecording() }
                    )
                }
                .accessibilityLabel("Record shortcut for \(shortcut.title)")
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
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let permission: MacPermission
    var compact = false

    var body: some View {
        let state = model.permissions.state(for: permission)
        let action = model.permissions.recoveryAction(for: permission)
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
    private func content(state: PermissionAuthorizationState, action: PermissionRecoveryAction) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if compact { Text(permission.title).font(.headline) }
                Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.isGranted ? .green : .orange)
            if action.buttonTitle != nil {
                Button(actionTitle(for: action)) { Task { await model.recoverPermission(permission) } }
                    .disabled(model.permissions.activeRequest != nil)
                    .accessibilityLabel("\(actionTitle(for: action)) for \(permission.title)")
            }
        }
    }

    private func actionTitle(for action: PermissionRecoveryAction) -> String {
        if permission.usesApplicationDragAssistant {
            return "Add SuperMac…"
        }
        return action.buttonTitle ?? "Open System Settings…"
    }
}

extension Notification.Name {
    static let openPermissions = Notification.Name("SuperMac.openPermissions")
    static let openDictationHistory = Notification.Name("SuperMac.openDictationHistory")
}

@MainActor @Observable
private final class ShortcutRecorderState {
    private(set) var identifier: String?
    private(set) var error: String?
    private var monitor: Any?

    func begin(
        identifier: String,
        suspend: () -> Void,
        capture: @escaping (ShortcutBinding?) -> Void,
        cancel: @escaping () -> Void
    ) {
        stopMonitor()
        self.identifier = identifier
        error = nil
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

    private func finish() {
        stopMonitor()
        identifier = nil
        error = nil
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
