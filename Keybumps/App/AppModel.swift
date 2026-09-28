import AppKit
import Foundation
import Observation

enum DictationShortcutAction: Equatable {
    case showPermissionSetup
    case toggleDictation
}

enum DictationShortcutRouting {
    static func action(
        phase: DictationPhase,
        missingPermissions: [MacPermission]
    ) -> DictationShortcutAction {
        switch phase {
        case .idle, .failed:
            missingPermissions.isEmpty ? .toggleDictation : .showPermissionSetup
        case .recording, .transcribing, .inserting:
            .toggleDictation
        }
    }
}

enum DictationEscapeRegistration {
    static let ownerID = "dictation.cancel"

    static func shouldRegister(for phase: DictationPhase) -> Bool {
        phase == .recording || phase == .transcribing
    }
}

@MainActor @Observable
final class AppModel {
    let releaseLane = ReleaseLane.current
    let preferences: AppPreferences
    let inbox: InboxStore
    let shortcuts: GlobalShortcutCoordinator
    let permissions: PermissionCoordinator
    let clipboard: ClipboardHistoryService
    let screenshotTools: ScreenshotToolsService
    private let screenshotEditor: ScreenshotEditorPresenter
    let dictationHistory: DictationHistoryService
    let dictationModels: DictationModelManager
    let windows: WindowManagementService
    let launchAtLogin = LaunchAtLoginController()
    let conflicts = ConflictDetector()
    private let spotlightShortcutResolver: any SpotlightShortcutConflictResolving
    let dictation: DictationService
    let updater: any UpdateControlling
    let updateSafetyPolicy: UpdateInstallationSafetyPolicy
    private let delivery: NotificationDeliveryService
    private let nativeNotificationCenter: any NativeNotificationCenterClient
    private let detector: ManualActionDetector
    private let presenter: PresentationWindowController
    private let presenceController: any AppPresenceControlling
    let commandPalette: CommandPaletteController
    private let transcriptionCoordinator: DictationTranscriptionCoordinator
    private let permissionDragAssistant = PermissionDragAssistantController()
    private let dictationIndicator: DictationIndicatorController
    @ObservationIgnored private var permissionWalkthroughPermissions: [MacPermission] = []
    @ObservationIgnored private var presentedWalkthroughPermission: MacPermission?
    @ObservationIgnored private var permissionRelaunchAdvisor = PermissionRelaunchAdvisor()
    private(set) var detectorStatus: ManualActionDetector.Status = .stopped
    private(set) var isAccessibilityTrusted = false
    private(set) var isInputMonitoringAuthorized = false
    private(set) var lastReport: DeliveryReport?
    private(set) var lastPreviewChannel: NotificationChannel?
    private(set) var isStarted = false
    private(set) var isPermissionWalkthroughActive = false
    private(set) var permissionsRequiringRelaunch: [MacPermission] = []
    var relaunchPromptPermission: MacPermission?
    var isPermissionRelaunchPromptPresented: Bool {
        get { relaunchPromptPermission != nil }
        set {
            if !newValue { dismissPermissionRelaunchPrompt() }
        }
    }
    private(set) var nativeNotificationAuthorization: NativeNotificationAuthorization = .notDetermined
    private(set) var updateSnapshot: UpdateSnapshot
    private(set) var quickSearchShortcutConflictStatus: SpotlightShortcutConflictStatus = .unavailable(
        manualRecovery: "Checking the Quick Search shortcut…"
    )
    var quickSearchShortcutOnboardingPresentation: QuickSearchShortcutOnboardingPresentation {
        QuickSearchShortcutOnboardingPresentation.resolve(quickSearchShortcutConflictStatus)
    }
    var unreadCount: Int { inbox.unreadCount }
    var permissionReadiness: PermissionReadinessSnapshot {
        permissionReadiness(for: preferences.enabledCapabilities)
    }
    var nativeNotificationNeedsAttention: Bool { permissionReadiness.nativeNotificationNeedsAttention }
    var missingPermissionCount: Int { permissionReadiness.missingCount }
    var permissionSetupProgress: PermissionSetupProgress {
        let readiness = permissionReadiness
        return PermissionSetupProgress(
            requiredPermissions: readiness.requiredPermissions,
            grantedPermissions: readiness.requiredPermissions.filter {
                readiness.state(for: $0).isGranted
            }
        )
    }

    func permissionReadiness(for capabilities: Set<Capability>) -> PermissionReadinessSnapshot {
        PermissionReadinessSnapshot.resolve(
            enabledCapabilities: capabilities,
            states: Dictionary(uniqueKeysWithValues: MacPermission.allCases.map {
                ($0, permissions.state(for: $0))
            }),
            permissionsRequiringRelaunch: Set(permissionsRequiringRelaunch),
            selectedChannels: preferences.selectedChannels,
            notificationAuthorization: nativeNotificationAuthorization
        )
    }

    convenience init() {
        self.init(
            preferences: AppPreferences(),
            inbox: InboxStore(),
            presenceController: AppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            screenshotDirectoryReader: FileSystemScreenshotDirectoryReader()
        )
    }

    init(
        releaseLane: ReleaseLane = .full,
        preferences: AppPreferences,
        inbox: InboxStore,
        presenceController: any AppPresenceControlling,
        detector: ManualActionDetector,
        presenter: PresentationWindowController,
        shortcutCoordinator: GlobalShortcutCoordinator? = nil,
        permissionCoordinator: PermissionCoordinator? = nil,
        nativeNotificationCenter: (any NativeNotificationCenterClient)? = nil,
        updater injectedUpdater: (any UpdateControlling)? = nil,
        dictationModelManager injectedDictationModelManager: DictationModelManager? = nil,
        spotlightShortcutResolver injectedSpotlightShortcutResolver: (any SpotlightShortcutConflictResolving)? = nil,
        screenshotDirectoryReader: (any ScreenshotDirectoryReading)? = nil,
        clipboard injectedClipboard: ClipboardHistoryService? = nil,
        dictationHistory injectedDictationHistory: DictationHistoryService? = nil,
        windows injectedWindows: WindowManagementService? = nil,
        screenshotTools injectedScreenshotTools: ScreenshotToolsService? = nil,
        dictationIndicator injectedDictationIndicator: DictationIndicatorController? = nil,
        dictationFileManager: FileManager = .default,
        allowsDictationSystemAccess: Bool = true,
        screenshotEditorFallbackFolder: (() -> URL)? = nil
    ) {
        self.preferences = preferences; self.inbox = inbox; self.presenceController = presenceController; self.detector = detector; self.presenter = presenter
        self.permissions = permissionCoordinator ?? PermissionCoordinator()
        self.shortcuts = shortcutCoordinator ?? GlobalShortcutCoordinator()
        self.spotlightShortcutResolver = injectedSpotlightShortcutResolver
            ?? SpotlightShortcutConflictResolver(preferences: SystemSymbolicHotKeyPreferences())
        let nativeNotificationCenter = nativeNotificationCenter ?? SystemNativeNotificationCenterClient()
        self.nativeNotificationCenter = nativeNotificationCenter
        let updateSafetyPolicy = UpdateInstallationSafetyPolicy.shared
        self.updateSafetyPolicy = updateSafetyPolicy
        let updater = injectedUpdater ?? UpdateControllerFactory.makeDefault(safetyPolicy: updateSafetyPolicy)
        self.updater = updater
        self.updateSnapshot = updater.snapshot
        let clipboard = injectedClipboard ?? ClipboardHistoryService()
        let dictationHistory = injectedDictationHistory ?? DictationHistoryService()
        self.clipboard = clipboard
        self.windows = injectedWindows ?? WindowManagementService()
        self.dictationIndicator = injectedDictationIndicator ?? DictationIndicatorController()
        // Only the production composition reads the real screenshot folder; injected models stay inert.
        screenshotTools = injectedScreenshotTools ?? ScreenshotToolsService(
            reader: screenshotDirectoryReader ?? UnavailableScreenshotDirectoryReader(),
            ingest: { clipboard.ingestImageFile(at: $0, isScreenCapture: true) }
        )
        self.dictationHistory = dictationHistory
        let dictationModelManager = injectedDictationModelManager ?? DictationModelManager(
            modelsRoot: ProductPaths.keybumps().dictationModels,
            downloader: WhisperKitModelDownloader()
        )
        self.dictationModels = dictationModelManager
        if dictationModelManager.state(for: preferences.dictationTranscriptionEngine) != .installed
            || !preferences.dictationTranscriptionEngine.supports(language: preferences.dictationLanguage) {
            preferences.dictationTranscriptionEngine = .appleSpeech
        }
        let transcriptionCoordinator = DictationTranscriptionCoordinator(
            selectedEngine: { preferences.dictationTranscriptionEngine },
            modelManager: dictationModelManager
        )
        self.transcriptionCoordinator = transcriptionCoordinator
        dictation = DictationService(
            language: preferences.dictationLanguage,
            durationLimit: preferences.dictationDurationLimit,
            fileManager: dictationFileManager,
            history: dictationHistory,
            transcriber: transcriptionCoordinator,
            didWritePasteboard: clipboard.suppressCurrentChange,
            allowsSystemAccess: allowsDictationSystemAccess
        )
        screenshotEditor = ScreenshotEditorPresenter(
            fallbackFolder: screenshotEditorFallbackFolder ?? { ScreenshotLocationResolver.system.resolve() },
            editingChanged: { isEditing in
                updateSafetyPolicy.updateCriticalOperation(.unsavedWork, active: isEditing)
                updater.installationSafetyDidChange()
            }
        )
        commandPalette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: dictation,
            inbox: inbox,
            preferences: preferences
        )
        var adapters: [NotificationChannel: any ChannelDelivering] = [.nativeBanner: NativeNotificationAdapter(center: nativeNotificationCenter), .sound: SoundAdapter()]
        for channel in NotificationChannel.allCases where adapters[channel] == nil { adapters[channel] = PanelChannelAdapter(channel: channel, presenter: presenter) }
        delivery = NotificationDeliveryService(inbox: inbox, adapters: adapters)
        detector.onEvent = { [weak self] event in Task { @MainActor in await self?.deliver(event) } }
        dictation.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.dictationIndicator.update(phase)
            self.updateDictationEscapeRegistration(for: phase)
            self.updateSafetyPolicy.update(dictationPhase: phase)
            self.updater.installationSafetyDidChange()
        }
        updater.onChange = { [weak self] snapshot in self?.updateSnapshot = snapshot }
        windows.onDragActivityChange = { [weak self] isActive in
            guard let self else { return }
            self.updateSafetyPolicy.updateCriticalOperation(.windowDrag, active: isActive)
            self.updater.installationSafetyDidChange()
        }
        refreshDetectorState()
    }

    func start() {
        guard !isStarted else { return }; isStarted = true
        presenceController.apply(showInDockAndSwitcher: true)
        launchAtLogin.refresh()
        if preferences.didCompleteOnboarding { applyCapabilities() }
        refreshPermissions(); conflicts.refresh()
        Task { await refreshNotificationPermission() }
        updater.start()
    }

    func checkForUpdates() { updater.checkNow() }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { updater.setAutomaticallyChecks(enabled) }
    func restartToUpdate() { updater.restartWhenSafe() }

    func completeOnboarding() {
        preferences.didCompleteOnboarding = true
        launchAtLogin.setEnabled(true); applyCapabilities()
    }

    func refreshQuickSearchShortcutConflict() {
        guard !preferences.didCompleteOnboarding,
              preferences.enabledCapabilities.contains(.quickSearch),
              let binding = preferences.capabilityShortcut(for: .quickSearch) else {
            quickSearchShortcutConflictStatus = .noConflict
            return
        }

        let status = spotlightShortcutResolver.status(for: binding)
        if status == .conflict {
            switch spotlightShortcutResolver.disableIfConflicting(binding) {
            case .resolved, .noLongerConflicting:
                break
            case .failed(let manualRecovery):
                quickSearchShortcutConflictStatus = .unavailable(manualRecovery: manualRecovery)
                return
            }
        } else if case .unavailable = status {
            quickSearchShortcutConflictStatus = status
            return
        }

        let registered = shortcuts.register(
            owner: CapabilityShortcut.quickSearch.ownerID,
            binding: binding
        ) { [weak self] in
            self?.commandPalette.toggle(.search)
        }
        quickSearchShortcutConflictStatus = registered
            ? .noConflict
            : .unavailable(
                manualRecovery: "Open System Settings → Keyboard → Keyboard Shortcuts, remove the conflicting shortcut, then return to Keybumps."
            )
    }

    func openKeyboardShortcutSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setCapability(_ capability: Capability, enabled: Bool) {
        if !enabled { deactivate(capability) }
        preferences.setCapability(capability, enabled: enabled)
        applyCapabilities()
    }

    func applyCapabilities() {
        let enabled = preferences.enabledCapabilities
        configure(owner: CapabilityShortcut.quickSearch.ownerID, capability: .quickSearch, binding: preferences.capabilityShortcut(for: .quickSearch)) { [weak self] in self?.commandPalette.toggle(.search) }
        configure(owner: CapabilityShortcut.clipboardHistory.ownerID, capability: .clipboardHistory, binding: preferences.capabilityShortcut(for: .clipboardHistory)) { [weak self] in self?.commandPalette.toggle(.clipboard) }
        configure(owner: CapabilityShortcut.dictation.ownerID, capability: .dictation, binding: preferences.capabilityShortcut(for: .dictation)) { [weak self] in self?.handleDictationShortcut() }
        for action in WindowAction.allCases {
            let owner = "window.\(action.rawValue)"
            configure(owner: owner, capability: .windowManagement, binding: preferences.windowShortcut(for: action)) { [weak self] in self?.performWindowAction(action) }
        }
        enabled.contains(.clipboardHistory) ? clipboard.start() : clipboard.stop()
        screenshotTools.apply(
            enabled: enabled.contains(.screenshotTools),
            clipboardHistoryEnabled: enabled.contains(.clipboardHistory)
        )
        commandPalette.editImage = enabled.contains(.screenshotTools)
            ? { [weak self] entry in self?.screenshotEditor.edit(entry) ?? false }
            : nil
        enabled.contains(.windowManagement) ? windows.startDragSnapping() : windows.stop()
        enabled.contains(.keyboardShortcutter) ? detector.start() : detector.stop()
        refreshDetectorState()
    }

    private func performWindowAction(_ action: WindowAction) {
        updateSafetyPolicy.performSynchronousCriticalOperation(
            .windowAction,
            notify: updater.installationSafetyDidChange,
            operation: { windows.perform(action) }
        )
    }

    private func configure(owner: String, capability: Capability, binding: ShortcutBinding?, handler: @escaping () -> Void) {
        guard preferences.enabledCapabilities.contains(capability), let binding else {
            shortcuts.unregister(owner: owner)
            return
        }
        shortcuts.register(owner: owner, binding: binding, handler: handler)
    }

    private func handleDictationShortcut() {
        refreshPermissions()
        switch DictationShortcutRouting.action(
            phase: dictation.phase,
            missingPermissions: missingPermissions(for: .dictation)
        ) {
        case .showPermissionSetup:
            let missing = missingPermissions(for: .dictation)
            permissionDragAssistant.showDictationSetup(missingPermissions: missing) { [weak self] in
                self?.beginPermissionWalkthrough(for: .dictation)
            }
        case .toggleDictation:
            dictation.toggle()
        }
    }

    private func updateDictationEscapeRegistration(for phase: DictationPhase) {
        guard DictationEscapeRegistration.shouldRegister(for: phase) else {
            shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
            return
        }
        shortcuts.register(
            owner: DictationEscapeRegistration.ownerID,
            binding: DefaultShortcut.cancelDictation
        ) { [weak self] in
            self?.dictation.cancel()
        }
    }

    func recoverPermission(_ permission: MacPermission) async {
        refreshPermissions()
        guard !permissions.state(for: permission).isGranted else { return }
        let presentation = PermissionRecoveryPresentation.resolve(
            permission: permission,
            action: permissions.recoveryAction(for: permission)
        )
        if presentation == .enableSwitch {
            permissionDragAssistant.showEnableSwitch(for: permission)
        }
        if presentation == .applicationDrag {
            permissionRelaunchAdvisor.didOpenSystemSettings(for: permission)
        }
        await permissions.performRecovery(for: permission)
        refreshPermissions()
        guard !permissions.state(for: permission).isGranted else { return }
        switch presentation {
        case .applicationDrag:
            try? await Task.sleep(for: .milliseconds(450))
            permissionDragAssistant.show(for: permission)
        case .enableSwitch:
            break
        case .none, .nativePrompt:
            break
        }
    }

    func beginPermissionWalkthrough(for capability: Capability? = nil) {
        permissions.refresh()
        permissionDragAssistant.dismiss()
        permissionWalkthroughPermissions = PermissionSetupPlan.requiredPermissions(
            for: capability.map { Set([$0]) } ?? preferences.enabledCapabilities
        )
        presentedWalkthroughPermission = nil
        isPermissionWalkthroughActive = true
        advancePermissionWalkthroughIfNeeded()
    }

    func requestAccessibilityPermission() { detector.requestAccessibilityPermission(); refreshPermissions() }
    func requestInputMonitoringPermission() { detector.requestInputMonitoringPermission(); refreshPermissions() }
    func retryDetection() { if preferences.enabledCapabilities.contains(.keyboardShortcutter) { detector.start() }; refreshDetectorState() }
    func applicationDidBecomeActive() {
        refreshPermissions()
        permissionRelaunchAdvisor.didBecomeActive { [permissions] permission in
            permissions.state(for: permission)
        }
        permissionsRequiringRelaunch = permissionRelaunchAdvisor.permissionsRequiringRelaunch
        if relaunchPromptPermission == nil {
            relaunchPromptPermission = permissionsRequiringRelaunch.first
        }
    }

    func applicationDidResignActive() {
        cancelShortcutRecording()
    }

    func dismissPermissionRelaunchPrompt() {
        relaunchPromptPermission = nil
    }

    func restartForPermissionRelaunch() {
        guard updateSafetyPolicy.isSafeToInstall else { return }
        do {
            try PermissionRelauncher.schedule()
            relaunchPromptPermission = nil
            NSApplication.shared.terminate(nil)
        } catch {
            // Keep the recovery state visible so the user can retry rather than quitting without a relaunch helper.
        }
    }

    func requiresPermissionRelaunch(_ permission: MacPermission) -> Bool {
        permissionsRequiringRelaunch.contains(where: { $0 == permission })
    }

    func requiresPermissionRelaunch(for capability: Capability) -> Bool {
        let readiness = permissionReadiness(for: [capability])
        return readiness.requiredPermissions.contains(where: readiness.requiresRelaunch)
    }

    func refreshPermissions() {
        permissions.refresh()
        for permission in MacPermission.allCases where permissions.state(for: permission).isGranted {
            permissionRelaunchAdvisor.permissionDidBecomeUsable(permission)
            if relaunchPromptPermission == permission {
                relaunchPromptPermission = nil
            }
        }
        permissionsRequiringRelaunch = permissionRelaunchAdvisor.permissionsRequiringRelaunch
        permissionDragAssistant.dismissIfGranted(using: permissions)
        advancePermissionWalkthroughIfNeeded()
        if preferences.enabledCapabilities.contains(.keyboardShortcutter), detector.status != .monitoring {
            detector.start()
        }
        if preferences.enabledCapabilities.contains(.windowManagement), permissions.accessibilityGranted {
            windows.startDragSnapping()
        }
        refreshDetectorState()
        updateMissingPermissionBadge()
    }

    func refreshNotificationPermission() async {
        nativeNotificationAuthorization = await nativeNotificationCenter.authorizationStatus()
        updateMissingPermissionBadge()
    }

    func monitorNotificationPermissionChanges(
        interval: Duration = .seconds(1),
        maximumRefreshes: Int? = nil
    ) async {
        await monitorPermissionChanges(interval: interval, maximumRefreshes: maximumRefreshes) { [weak self] in
            await self?.refreshNotificationPermission()
        }
    }

    func monitorSystemPermissionChanges(
        interval: Duration = .seconds(1),
        maximumRefreshes: Int? = nil
    ) async {
        await monitorPermissionChanges(interval: interval, maximumRefreshes: maximumRefreshes) { [weak self] in
            self?.refreshPermissions()
        }
    }

    private func monitorPermissionChanges(
        interval: Duration,
        maximumRefreshes: Int?,
        refresh: @escaping @MainActor () async -> Void
    ) async {
        var refreshCount = 0
        while !Task.isCancelled {
            if let maximumRefreshes, refreshCount >= maximumRefreshes { return }
            await refresh()
            refreshCount += 1
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func requestNotificationPermission() async {
        do {
            if nativeNotificationAuthorization == .notDetermined {
                _ = try await nativeNotificationCenter.requestAuthorization()
            } else if !nativeNotificationAuthorization.canPresentAlerts {
                openNotificationSettings()
            }
        } catch {
            // The row remains in its truthful attention state and offers Settings recovery.
        }
        await refreshNotificationPermission()
    }

    private func advancePermissionWalkthroughIfNeeded() {
        guard isPermissionWalkthroughActive else { return }
        guard let next = permissionWalkthroughPermissions.first(where: {
            !permissions.state(for: $0).isGranted
        }) else {
            isPermissionWalkthroughActive = false
            permissionWalkthroughPermissions = []
            presentedWalkthroughPermission = nil
            return
        }
        guard next != presentedWalkthroughPermission else { return }
        presentedWalkthroughPermission = next
        Task { [weak self] in
            await self?.recoverPermission(next)
        }
    }
    func refreshDetectorState() { detectorStatus = detector.status; isAccessibilityTrusted = detector.isAccessibilityTrusted; isInputMonitoringAuthorized = detector.isInputMonitoringAuthorized }

    func missingPermissions(for capability: Capability) -> [MacPermission] {
        permissionReadiness(for: [capability]).missingPermissions
    }
    func setDictationLanguage(_ language: String) {
        preferences.dictationLanguage = language
        dictation.selectedLanguage = language
        if !preferences.dictationTranscriptionEngine.supports(language: language) {
            preferences.dictationTranscriptionEngine = .appleSpeech
            transcriptionCoordinator.selectedModelDidChange()
        }
    }
    func selectDictationTranscriptionEngine(_ engine: DictationTranscriptionEngine) {
        guard engine.supports(language: preferences.dictationLanguage) else { return }
        guard dictationModels.state(for: engine) == .installed else { return }
        guard preferences.dictationTranscriptionEngine != engine else { return }
        preferences.dictationTranscriptionEngine = engine
        transcriptionCoordinator.selectedModelDidChange()
    }
    func downloadDictationModel(_ engine: DictationTranscriptionEngine) async {
        await dictationModels.download(engine)
    }
    func deleteDictationModel(_ engine: DictationTranscriptionEngine) {
        if preferences.dictationTranscriptionEngine == engine {
            transcriptionCoordinator.selectedModelWasDeleted()
            preferences.dictationTranscriptionEngine = .appleSpeech
        }
        try? dictationModels.delete(engine)
    }
    func setDictationDurationLimit(_ limit: DictationDurationLimit) {
        preferences.dictationDurationLimit = limit
        dictation.durationLimit = limit
    }
    func beginShortcutRecording() { shortcuts.suspendForRecording() }
    func finishCapabilityShortcutRecording(_ binding: ShortcutBinding?, for shortcut: CapabilityShortcut) {
        preferences.setCapabilityShortcut(binding, for: shortcut)
        applyCapabilities()
        shortcuts.resumeAfterRecording()
    }
    func restoreDefaultCapabilityShortcut(_ shortcut: CapabilityShortcut) {
        preferences.restoreDefaultCapabilityShortcut(shortcut)
        applyCapabilities()
    }
    func finishWindowShortcutRecording(_ binding: ShortcutBinding?, for action: WindowAction) {
        preferences.setWindowShortcut(binding, for: action)
        applyCapabilities()
        shortcuts.resumeAfterRecording()
    }
    func cancelShortcutRecording() {
        guard shortcuts.isSuspendedForRecording else { return }
        shortcuts.resumeAfterRecording()
    }
    func restoreDefaultWindowShortcuts() { preferences.restoreDefaultWindowShortcuts(); applyCapabilities() }
    func showQuickSearch() {
        guard preferences.enabledCapabilities.contains(.quickSearch) else { return }
        commandPalette.show(.search)
    }
    var isQuickSearchVisible: Bool { commandPalette.isDisplaying(.search) }
    func setQuickSearchVisible(_ isVisible: Bool) {
        if isVisible {
            showQuickSearch()
        } else {
            commandPalette.dismiss(ifDisplaying: .search)
        }
    }
    func showClipboardHistory() {
        guard preferences.enabledCapabilities.contains(.clipboardHistory) else { return }
        commandPalette.show(.clipboard)
    }
    func showDictationHistory() { commandPalette.show(.dictation) }
    func showKeyboardShortcutterHistory() { commandPalette.show(.keyboardShortcutter) }
    func showCommandPalette(_ tab: CommandPaletteTab) { commandPalette.show(tab) }
    func deliverSample(channel: NotificationChannel? = nil) async { await deliver(.sample, through: channel.map { Set([$0]) } ?? preferences.selectedChannels) }
    func previewSample(channel: NotificationChannel) async {
        let channels = PreviewChannelPlan.channels(
            for: channel,
            selectedChannels: preferences.selectedChannels
        )
        let outcomes = await delivery.preview(.sample, through: channels)
        lastPreviewChannel = channel
        lastReport = DeliveryReport(eventID: CoachingEvent.sample.id, inboxRecorded: false, outcomes: outcomes)
        if channel == .nativeBanner {
            await refreshNotificationPermission()
        }
    }
    func previewOutcomes(for channel: NotificationChannel) -> [NotificationChannel: DeliveryOutcome] {
        guard lastPreviewChannel == channel else { return [:] }
        return lastReport?.outcomes ?? [:]
    }
    func openNotificationSettings() {
        NSWorkspace.shared.open(NotificationSettingsRecovery.url)
    }
    func openPermissionSettings(_ permission: MacPermission) {
        permissions.openSettings(permission)
    }
    func setChannel(_ channel: NotificationChannel, enabled: Bool) {
        preferences.set(channel, enabled: enabled)
        updateMissingPermissionBadge()
        if channel == .nativeBanner, enabled {
            Task { await requestNotificationPermission() }
        }
    }
    func setShowInDockAndSwitcher(_ show: Bool) { preferences.showInDockAndSwitcher = show; presenceController.apply(showInDockAndSwitcher: show) }
    func markRead(_ id: UUID) { inbox.markRead(id) }
    func markAllRead() { inbox.markAllRead() }
    func clearHistory() { inbox.clear() }
    private func deliver(_ event: CoachingEvent, through channels: Set<NotificationChannel>? = nil) async { lastReport = await delivery.deliver(event, through: channels ?? preferences.selectedChannels) }

    private func updateMissingPermissionBadge() {
        NSApplication.shared.dockTile.badgeLabel = missingPermissionCount > 0 ? "!" : nil
    }

    private func deactivate(_ capability: Capability) {
        switch capability {
        case .quickSearch:
            commandPalette.dismiss(ifDisplaying: .search)
        case .clipboardHistory:
            commandPalette.dismiss(ifDisplaying: .clipboard)
            clipboard.stop()
        case .dictation:
            dictation.cancel()
            shortcuts.unregister(owner: DictationEscapeRegistration.ownerID)
        case .windowManagement:
            windows.stop()
        case .keyboardShortcutter:
            detector.stop()
            presenter.dismissAll()
        case .screenshotTools:
            screenshotTools.stop()
            screenshotEditor.close()
        }
    }

}
