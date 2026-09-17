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
    let shortcuts = GlobalShortcutCoordinator()
    let permissions = PermissionCoordinator()
    let clipboard: ClipboardHistoryService
    let dictationHistory: DictationHistoryService
    let windows = WindowManagementService()
    let launchAtLogin = LaunchAtLoginController()
    let conflicts = ConflictDetector()
    let dictation: DictationService
    private let delivery: NotificationDeliveryService
    private let nativeNotificationCenter: any NativeNotificationCenterClient
    private let detector: ManualActionDetector
    private let presenter: PresentationWindowController
    private let presenceController: any AppPresenceControlling
    private let commandPalette: CommandPaletteController
    private let permissionDragAssistant = PermissionDragAssistantController()
    private let dictationIndicator = DictationIndicatorController()
    @ObservationIgnored private var permissionWalkthroughPermissions: [MacPermission] = []
    @ObservationIgnored private var presentedWalkthroughPermission: MacPermission?
    private(set) var detectorStatus: ManualActionDetector.Status = .stopped
    private(set) var isAccessibilityTrusted = false
    private(set) var isInputMonitoringAuthorized = false
    private(set) var lastReport: DeliveryReport?
    private(set) var lastPreviewChannel: NotificationChannel?
    private(set) var isStarted = false
    private(set) var isPermissionWalkthroughActive = false
    private(set) var nativeNotificationAuthorization: NativeNotificationAuthorization = .notDetermined
    var unreadCount: Int { inbox.unreadCount }
    var nativeNotificationNeedsAttention: Bool {
        guard preferences.selectedChannels.contains(.nativeBanner) else { return false }
        return !nativeNotificationAuthorization.canPresentAlerts
    }
    var missingPermissionCount: Int {
        permissionSetupProgress.requiredPermissions.filter {
            !permissions.state(for: $0).isGranted
        }.count + (nativeNotificationNeedsAttention ? 1 : 0)
    }
    var permissionSetupProgress: PermissionSetupProgress {
        PermissionSetupPlan.progress(for: preferences.enabledCapabilities) { permission in
            permissions.state(for: permission)
        }
    }

    convenience init() {
        self.init(preferences: AppPreferences(), inbox: InboxStore(), presenceController: AppPresenceController(), detector: ManualActionDetector(), presenter: PresentationWindowController())
    }

    init(
        releaseLane: ReleaseLane = .full,
        preferences: AppPreferences,
        inbox: InboxStore,
        presenceController: any AppPresenceControlling,
        detector: ManualActionDetector,
        presenter: PresentationWindowController,
        nativeNotificationCenter: (any NativeNotificationCenterClient)? = nil
    ) {
        self.preferences = preferences; self.inbox = inbox; self.presenceController = presenceController; self.detector = detector; self.presenter = presenter
        let nativeNotificationCenter = nativeNotificationCenter ?? SystemNativeNotificationCenterClient()
        self.nativeNotificationCenter = nativeNotificationCenter
        let clipboard = ClipboardHistoryService()
        let dictationHistory = DictationHistoryService()
        self.clipboard = clipboard
        self.dictationHistory = dictationHistory
        dictation = DictationService(
            language: preferences.dictationLanguage,
            durationLimit: preferences.dictationDurationLimit,
            history: dictationHistory,
            didWritePasteboard: clipboard.suppressCurrentChange
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
    }

    func completeOnboarding() {
        preferences.didCompleteOnboarding = true
        launchAtLogin.setEnabled(true); applyCapabilities()
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
        for action in SuperMacWindowAction.allCases {
            let owner = "window.\(action.rawValue)"
            configure(owner: owner, capability: .windowManagement, binding: preferences.windowShortcut(for: action)) { [weak self] in self?.windows.perform(action) }
        }
        enabled.contains(.clipboardHistory) ? clipboard.start() : clipboard.stop()
        enabled.contains(.windowManagement) ? windows.startDragSnapping() : windows.stop()
        enabled.contains(.shortcutCoaching) ? detector.start() : detector.stop()
        refreshDetectorState()
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
        let presentation = PermissionRecoveryPresentation.resolve(
            permission: permission,
            action: permissions.recoveryAction(for: permission)
        )
        if presentation == .enableSwitch {
            permissionDragAssistant.showEnableSwitch(for: permission)
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
    func retryDetection() { if preferences.enabledCapabilities.contains(.shortcutCoaching) { detector.start() }; refreshDetectorState() }
    func refreshPermissions() {
        permissions.refresh()
        permissionDragAssistant.dismissIfGranted(using: permissions)
        advancePermissionWalkthroughIfNeeded()
        if preferences.enabledCapabilities.contains(.shortcutCoaching), detector.status != .monitoring {
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
        switch capability {
        case .quickSearch, .clipboardHistory:
            []
        case .dictation:
            [.microphone, .speechRecognition].filter { !permissions.state(for: $0).isGranted }
        case .windowManagement:
            permissions.accessibilityGranted ? [] : [.accessibility]
        case .shortcutCoaching:
            [.accessibility, .inputMonitoring].filter { !permissions.state(for: $0).isGranted }
        }
    }
    func setDictationLanguage(_ language: String) { preferences.dictationLanguage = language; dictation.selectedLanguage = language }
    func setDictationDurationLimit(_ limit: DictationDurationLimit) {
        preferences.dictationDurationLimit = limit
        dictation.durationLimit = limit
    }
    func beginShortcutRecording() { shortcuts.unregisterAll() }
    func finishCapabilityShortcutRecording(_ binding: ShortcutBinding?, for shortcut: CapabilityShortcut) {
        preferences.setCapabilityShortcut(binding, for: shortcut)
        applyCapabilities()
    }
    func restoreDefaultCapabilityShortcut(_ shortcut: CapabilityShortcut) {
        preferences.restoreDefaultCapabilityShortcut(shortcut)
        applyCapabilities()
    }
    func finishWindowShortcutRecording(_ binding: ShortcutBinding?, for action: SuperMacWindowAction) {
        preferences.setWindowShortcut(binding, for: action)
        applyCapabilities()
    }
    func cancelShortcutRecording() { applyCapabilities() }
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
    func showKeyBumpsHistory() { commandPalette.show(.keyBumps) }
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
        case .shortcutCoaching:
            detector.stop()
            presenter.dismissAll()
        }
    }
}
