import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case search = "Quick Search", clipboard = "Clipboard History", dictation = "Dictation"
    case windows = "Window Management", keyboardShortcutter = "Keyboard Shortcutter", permissions = "Permissions", general = "General"
    var id: String { rawValue }
    var icon: String { switch self { case .search: "magnifyingglass"; case .clipboard: "clipboard"; case .dictation: "waveform"; case .windows: "rectangle.split.2x1"; case .keyboardShortcutter: "keyboard"; case .permissions: "hand.raised"; case .general: "gearshape" } }
}

struct SettingsNavigationHistory: Equatable {
    private(set) var selection: SettingsSection = .permissions
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

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = SettingsNavigationHistory()

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selectionBinding) { section in
                SettingsSidebarRow(
                    section: section,
                    attentionCount: attentionCount(for: section)
                )
                .tag(section)
            }
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch navigation.selection {
                case .search: QuickSearchSettingsView()
                case .clipboard: ClipboardSettingsView()
                case .dictation: DictationSettingsView()
                case .windows: WindowSettingsView()
                case .keyboardShortcutter: KeyboardShortcutterSettingsView()
                case .permissions: PermissionsView()
                case .general: GeneralView()
                }
            }.environment(model)
        }
        .navigationTitle("Keybumps")
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
        .onReceive(NotificationCenter.default.publisher(for: .openDictationHistory)) { _ in model.showDictationHistory() }
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

    private func attentionCount(for section: SettingsSection) -> Int {
        switch section {
        case .permissions:
            return model.missingPermissionCount
        case .keyboardShortcutter:
            guard model.preferences.enabledCapabilities.contains(.keyboardShortcutter) else { return 0 }
            return model.permissionReadiness(for: [.keyboardShortcutter]).missingCount
        default:
            return 0
        }
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let attentionCount: Int

    var body: some View {
        HStack {
            Label(section.rawValue, systemImage: section.icon)
            Spacer()
            if attentionCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(attentionCount) permission items need attention")
            }
        }
    }
}

private struct QuickSearchSettingsView: View {
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

private struct ClipboardSettingsView: View {
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

private struct DictationSettingsView: View {
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

private struct WindowSettingsView: View {
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

private struct KeyboardShortcutterSettingsView: View {
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

private struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    var body: some View {
        let shortcutPresentation = model.quickSearchShortcutOnboardingPresentation
        VStack(spacing: 24) {
            Spacer()
            Image(ProductIdentity.inAppBrandImageName).resizable().scaledToFit().frame(width: 72, height: 72)
            Group {
                switch step {
                case 0:
                    VStack(spacing: 12) { Text("Welcome to Keybumps").font(.largeTitle.bold()); Text("Set up the local preview").font(.headline); Text("This build is ready for hands-on testing. Purchasing and license activation are not part of this local preview.").foregroundStyle(.secondary).multilineTextAlignment(.center) }
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
                    VStack(spacing: 12) {
                        Text("Resolve shortcut conflicts").font(.largeTitle.bold())
                        Text("Keybumps checks whether Spotlight owns your Quick Search shortcut. For an exact conflict, Keybumps turns off only Spotlight's keyboard shortcut and leaves Spotlight search available everywhere else.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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
                default:
                    VStack(spacing: 12) {
                        Text("Ready").font(.largeTitle.bold())
                        Text("Permissions shows what is working and what still needs attention.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: 620)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 4 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(step == 3 && !shortcutPresentation.canContinue)
                } else {
                    Button("Start Keybumps") { model.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(36)
        .frame(width: 760, height: 520)
        .task(id: step) {
            if step == 3 {
                model.refreshQuickSearchShortcutConflict()
            }
        }
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
        switch capability {
        case .quickSearch: "Turning this off closes Quick Search and releases its global shortcut."
        case .clipboardHistory: "Turning this off stops clipboard monitoring, closes its panel, and releases its global shortcut."
        case .dictation: "Turning this off cancels active Dictation and releases its global shortcut."
        case .windowManagement: "Turning this off stops drag-to-snap and releases all window shortcuts."
        case .keyboardShortcutter: nil
        }
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
