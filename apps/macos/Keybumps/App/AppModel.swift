import AppKit
import Foundation
import Observation

enum DictationShortcutAction: Equatable {
    case showPermissionSetup
    /// Setup is already running: continue it rather than show a second setup card.
    case continuePermissionSetup
    case toggleDictation
}

enum DictationShortcutRouting {
    static func action(
        phase: DictationPhase,
        missingPermissions: [MacPermission],
        isPermissionSetupRunning: Bool = false
    ) -> DictationShortcutAction {
        switch phase {
        case .idle, .failed:
            if missingPermissions.isEmpty { return .toggleDictation }
            return isPermissionSetupRunning ? .continuePermissionSetup : .showPermissionSetup
        case .recording, .transcribing, .inserting:
            return .toggleDictation
        }
    }
}

@MainActor @Observable
final class AppModel {
    let releaseLane = ReleaseLane.current
    let preferences: AppPreferences
    let inbox: InboxStore
    let shortcuts: GlobalShortcutCoordinator
    let permissions: PermissionCoordinator
    @ObservationIgnored private let notice = PaletteHUD.shared
    @ObservationIgnored private let coachTips: any CoachTipPresenting
    let clipboard: ClipboardHistoryService
    let screenshotTools: ScreenshotToolsService
    let dictationHistory: DictationHistoryService
    let dictationModels: DictationModelManager
    let windows: WindowManagementService
    let launchAtLogin = LaunchAtLoginController()
    let conflicts = ConflictDetector()
    /// Read by the unit-test isolation guard.
    let spotlightShortcutResolver: any SpotlightShortcutConflictResolving
    let dictation: DictationService
    let updater: any UpdateControlling
    /// The app-shell licensing seam (ADR 0002). Capability modules start only while it is entitled.
    let licensing: any LicenseControlling
    let updateSafetyPolicy: UpdateInstallationSafetyPolicy
    private let detector: ManualActionDetector
    private let presenceController: any AppPresenceControlling
    let commandPalette: CommandPaletteController
    let capabilities: CapabilityRegistry
    private let transcriptionCoordinator: DictationTranscriptionCoordinator
    private let permissionDragAssistant = PermissionDragAssistantController()
    /// The permission card on screen, if any.
    var permissionAssistantPresentation: PermissionDragAssistantController.Presentation? {
        permissionDragAssistant.presentation
    }
    @ObservationIgnored private var permissionWalkthroughPermissions: [MacPermission] = []
    @ObservationIgnored private var presentedWalkthroughPermission: MacPermission?
    /// How the current walkthrough step was presented, so a declined native prompt ends setup.
    @ObservationIgnored private var presentedWalkthroughAction: PermissionRecoveryAction?
    @ObservationIgnored private var permissionWalkthroughMonitor: Task<Void, Never>?
    private let permissionPollInterval: Duration
    private let applicationActivations: any ApplicationActivationObserving
    @ObservationIgnored private var permissionRelaunchAdvisor = PermissionRelaunchAdvisor()
    private(set) var detectorStatus: ManualActionDetector.Status = .stopped
    private(set) var isAccessibilityTrusted = false
    private(set) var isInputMonitoringAuthorized = false
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
    private(set) var updateSnapshot: UpdateSnapshot
    private(set) var licenseSnapshot: LicenseSnapshot
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
            permissionsRequiringRelaunch: Set(permissionsRequiringRelaunch)
        )
    }

    convenience init() {
        self.init(
            preferences: AppPreferences(),
            inbox: InboxStore(),
            presenceController: AppPresenceController(),
            detector: ManualActionDetector(),
            licensing: LicenseControllerFactory.makeDefault(),
            screenshotDirectoryReader: FileSystemScreenshotDirectoryReader()
        )
    }

    init(
        releaseLane: ReleaseLane = .full,
        preferences: AppPreferences,
        inbox: InboxStore,
        presenceController: any AppPresenceControlling,
        detector: ManualActionDetector,
        shortcutCoordinator: GlobalShortcutCoordinator? = nil,
        permissionCoordinator: PermissionCoordinator? = nil,
        updater injectedUpdater: (any UpdateControlling)? = nil,
        licensing injectedLicensing: (any LicenseControlling)? = nil,
        dictationModelManager injectedDictationModelManager: DictationModelManager? = nil,
        spotlightShortcutResolver injectedSpotlightShortcutResolver: (any SpotlightShortcutConflictResolving)? = nil,
        screenshotDirectoryReader: (any ScreenshotDirectoryReading)? = nil,
        clipboard injectedClipboard: ClipboardHistoryService? = nil,
        dictationHistory injectedDictationHistory: DictationHistoryService? = nil,
        windows injectedWindows: WindowManagementService? = nil,
        screenshotTools injectedScreenshotTools: ScreenshotToolsService? = nil,
        dictationIndicator injectedDictationIndicator: DictationIndicatorController? = nil,
        coachTips: (any CoachTipPresenting)? = nil,
        dictationFileManager: FileManager = .default,
        allowsDictationSystemAccess: Bool = !UnitTestHost.isActive,
        screenshotEditorFallbackFolder: (() -> URL)? = nil,
        screenshotCapturer: ScreenshotCapturer? = nil,
        symbolicHotKeyPreferences: (any SymbolicHotKeyPreferences)? = nil,
        dictationPasteStep: DictationPasteStep? = nil,
        permissionPollInterval: Duration = .seconds(1),
        applicationActivations injectedApplicationActivations: (any ApplicationActivationObserving)? = nil
    ) {
        self.preferences = preferences; self.inbox = inbox; self.presenceController = presenceController; self.detector = detector
        self.permissionPollInterval = permissionPollInterval
        // Unit tests never read which app is in front.
        applicationActivations = injectedApplicationActivations
            ?? (UnitTestHost.isActive ? InertActivationObserver() : WorkspaceActivationObserver())
        self.coachTips = coachTips ?? PaletteHUD.shared
        let permissions = permissionCoordinator ?? PermissionCoordinator()
        self.permissions = permissions
        self.shortcuts = shortcutCoordinator ?? GlobalShortcutCoordinator()
        self.spotlightShortcutResolver = injectedSpotlightShortcutResolver
            ?? SpotlightShortcutConflictResolver(preferences: Self.defaultSymbolicHotKeyPreferences)
        let updateSafetyPolicy = UpdateInstallationSafetyPolicy.shared
        self.updateSafetyPolicy = updateSafetyPolicy
        let updater = injectedUpdater ?? UpdateControllerFactory.makeDefault(safetyPolicy: updateSafetyPolicy)
        self.updater = updater
        self.updateSnapshot = updater.snapshot
        #if DEBUG
        // Unit tests and injected compositions run entitled unless they pass a license state.
        let licensing = injectedLicensing ?? FixedLicenseController()
        #else
        let licensing = injectedLicensing ?? LicenseControllerFactory.makeDefault()
        #endif
        self.licensing = licensing
        self.licenseSnapshot = licensing.snapshot
        let clipboard = injectedClipboard
            ?? ClipboardHistoryService(sourceApps: UnitTestHost.isActive ? .inert : .system)
        let dictationHistory = injectedDictationHistory ?? DictationHistoryService()
        self.clipboard = clipboard
        self.windows = injectedWindows ?? WindowManagementService()
        let screenshotDelivery = ScreenshotClipboardDelivery(
            clipboard: clipboard,
            copiesToClipboard: { preferences.copiesScreenshotsToClipboard }
        )
        // Only the production composition reads the real screenshot folder; injected models stay inert.
        screenshotTools = injectedScreenshotTools ?? ScreenshotToolsService(
            reader: screenshotDirectoryReader ?? UnavailableScreenshotDirectoryReader(),
            ingest: { screenshotDelivery.add($0) }
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
            allowsSystemAccess: allowsDictationSystemAccess,
            // Re-read at paste time, through the same coordinator that drives setup and Settings.
            accessibilityTrusted: {
                permissions.refresh()
                return permissions.accessibilityGranted
            },
            // Nil takes `DictationPasteStep.current`, which is inert in the unit-test host.
            pasteStep: dictationPasteStep
        )
        commandPalette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: dictation,
            inbox: inbox,
            preferences: preferences
        )
        // The palette's Settings button, Command-comma, and Keybumps Settings result take the status menu's route.
        commandPalette.openSettings = { MainWindowRouter.shared.open() }
        // Unit tests must never rewrite the owner's macOS shortcuts.
        let symbolicHotKeys = symbolicHotKeyPreferences ?? Self.defaultSymbolicHotKeyPreferences
        let screenshotModule = ScreenshotToolsModule(
            service: screenshotTools,
            palette: commandPalette,
            clipboard: clipboard,
            delivery: screenshotDelivery,
            capturer: screenshotCapturer ?? ScreenshotCapturer(),
            systemShortcuts: SystemScreenshotShortcutTakeover(
                preferences: symbolicHotKeys,
                takenOver: { preferences.takenOverSystemShortcuts },
                setTakenOver: { preferences.takenOverSystemShortcuts = $0 }
            ),
            permissions: permissions,
            editorFallbackFolder: screenshotEditorFallbackFolder ?? { ScreenshotLocationResolver.system.resolve() },
            updateSafety: CapabilityUpdateSafety(policy: updateSafetyPolicy, updater: updater, descriptor: .screenshotTools)
        )
        let dictationModule = DictationModule(
            dictation: dictation,
            indicator: injectedDictationIndicator ?? DictationIndicatorController(),
            shortcuts: shortcuts,
            updateSafety: CapabilityUpdateSafety(policy: updateSafetyPolicy, updater: updater, descriptor: .dictation)
        )
        capabilities = CapabilityRegistry(modules: [
            QuickSearchModule(palette: commandPalette),
            ClipboardHistoryModule(clipboard: clipboard, palette: commandPalette),
            screenshotModule,
            dictationModule,
            WindowManagementModule(
                windows: windows,
                updateSafety: CapabilityUpdateSafety(policy: updateSafetyPolicy, updater: updater, descriptor: .windowManagement)
            ),
            KeyboardShortcutterModule(detector: detector)
        ])
        detector.onEvent = { [weak self] event in Task { @MainActor in self?.deliver(event) } }
        dictationModule.onShortcut = { [weak self] in self?.handleDictationShortcut() }
        screenshotModule.onNeedsScreenRecording = { [weak self] in self?.screenshotHotkeyNeedsScreenRecording() }
        updater.onChange = { [weak self] snapshot in self?.updateSnapshot = snapshot }
        licensing.onChange = { [weak self] snapshot in self?.licenseDidChange(snapshot) }
        applicationActivations.onActivate = { [weak self] bundleIdentifier in
            self?.applicationDidActivate(bundleIdentifier: bundleIdentifier)
        }
        refreshDetectorState()
    }

    /// The symbolic-hotkey preferences Quick Search's Spotlight check and the Screenshot Tools
    /// takeover use unless a composition injects its own: the owner's `com.apple.symbolichotkeys`,
    /// or inert ones under the unit-test host, so unit tests never rewrite the owner's macOS shortcuts.
    static var defaultSymbolicHotKeyPreferences: any SymbolicHotKeyPreferences {
        UnitTestHost.isActive ? InertSymbolicHotKeyPreferences() : SystemSymbolicHotKeyPreferences()
    }

    func start() {
        guard !isStarted else { return }; isStarted = true
        presenceController.apply(showInDockAndSwitcher: true)
        launchAtLogin.refresh()
        licensing.start()
        if preferences.didCompleteOnboarding && isLicensed { applyCapabilities() }
        refreshPermissions(); conflicts.refresh()
        updater.start()
    }

    func checkForUpdates() { updater.checkNow() }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { updater.setAutomaticallyChecks(enabled) }
    func restartToUpdate() { updater.restartWhenSafe() }

    /// Whether Keybumps may run its capabilities. When false the app is Locked (ADR 0002).
    var isLicensed: Bool { licenseSnapshot.isEntitled }
    func activateLicense(key: String) async { await licensing.activate(key: key) }
    func deactivateLicense() async { await licensing.deactivate() }
    func refreshLicense(force: Bool = false) async { await licensing.refresh(force: force) }
    /// What the Dock, the status menu, and the palette shortcuts open while Locked: Settings, which shows the License page.
    var openLicenseSettings: () -> Void = { MainWindowRouter.shared.open() }

    private func licenseDidChange(_ snapshot: LicenseSnapshot) {
        let wasLicensed = isLicensed
        licenseSnapshot = snapshot
        guard wasLicensed != snapshot.isEntitled, isStarted, preferences.didCompleteOnboarding else { return }
        if !snapshot.isEntitled {
            // Locked: stop every capability's resources and shortcuts, and close the palette.
            let context = capabilityContext
            for capability in preferences.enabledCapabilities { capabilities.deactivate(capability, context: context) }
            commandPalette.dismiss()
        }
        applyCapabilities()
    }

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
            guard let self else { return }
            // Onboarding registers this before activation; it opens Quick Search only once licensed.
            guard self.isLicensed else { self.openLicenseSettings(); return }
            self.commandPalette.toggle(.search)
        }
        quickSearchShortcutConflictStatus = registered
            ? .noConflict
            : .unavailable(
                manualRecovery: "Open System Settings → Keyboard → Keyboard Shortcuts, remove the conflicting shortcut, then return to Keybumps."
            )
    }

    func openKeyboardShortcutSettings() {
        permissions.openSystemSettings(.keyboardShortcuts)
    }

    func setCapability(_ capability: Capability, enabled: Bool) {
        if !enabled { capabilities.deactivate(capability, context: capabilityContext) }
        preferences.setCapability(capability, enabled: enabled)
        applyCapabilities()
    }

    /// What every capability module receives when the shell applies, deactivates, or refreshes it.
    var capabilityContext: CapabilityContext {
        CapabilityContext(
            // Locked runs no capability at all.
            enabledCapabilities: isLicensed ? preferences.enabledCapabilities : [],
            preferences: preferences,
            shortcuts: shortcuts,
            permissions: permissions,
            permissionReadiness: { self.permissionReadiness(for: $0) }
        )
    }

    func applyCapabilities() {
        capabilities.apply(capabilityContext)
        refreshDetectorState()
    }

    private func handleDictationShortcut() {
        refreshPermissions()
        let missing = missingPermissions(for: .dictation)
        switch DictationShortcutRouting.action(
            phase: dictation.phase,
            missingPermissions: missing,
            isPermissionSetupRunning: isPermissionWalkthroughActive
        ) {
        case .showPermissionSetup:
            // Access granted in System Settings that macOS applies only after a relaunch: sending
            // the user back to System Settings wouldn't help.
            if showRelaunchCardIfNeeded(for: missing) { return }
            permissionDragAssistant.showDictationSetup(missingPermissions: missing) { [weak self] in
                self?.beginPermissionWalkthrough(for: .dictation)
            }
        case .continuePermissionSetup:
            continuePermissionWalkthrough()
        case .toggleDictation:
            dictation.toggle()
        }
    }

    /// The Dictation shortcut while setup is running. There's no second card: the time limit
    /// restarts, and a System Settings step comes back. A native prompt already on screen is
    /// left alone.
    private func continuePermissionWalkthrough() {
        startPermissionWalkthroughMonitor()
        if showRelaunchCardIfNeeded(for: permissionWalkthroughPermissions) { return }
        guard let current = presentedWalkthroughPermission,
              permissions.recoveryAction(for: current) == .openSystemSettings else { return }
        Task { [weak self] in
            await self?.recoverPermission(current)
        }
    }

    /// Shows Restart on a setup card when one of `permissions` needs Keybumps to relaunch. The card
    /// doesn't activate Keybumps, so it works while the Settings window, and its alert, is closed.
    @discardableResult
    private func showRelaunchCardIfNeeded(for permissions: [MacPermission]) -> Bool {
        guard let permission = permissionsRequiringRelaunch.first(where: permissions.contains) else { return false }
        permissionDragAssistant.showRelaunch(for: permission) { [weak self] in
            self?.restartForPermissionRelaunch()
        }
        return true
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
            // Granted while System Settings opened: no card to drag.
            permissions.refresh()
            guard !permissions.state(for: permission).isGranted else { return }
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
        presentedWalkthroughAction = nil
        isPermissionWalkthroughActive = true
        startPermissionWalkthroughMonitor()
        advancePermissionWalkthroughIfNeeded()
    }

    /// How many permission re-checks a setup walkthrough gets (10 minutes at one per second) before
    /// it stops waiting; the next Dictation shortcut then offers setup again.
    static let permissionWalkthroughMaximumChecks = 600

    /// Re-reads permissions while setup runs. The setup cards don't activate Keybumps, so without
    /// this nothing would notice access granted in System Settings until Keybumps became active.
    private func startPermissionWalkthroughMonitor() {
        permissionWalkthroughMonitor?.cancel()
        let interval = permissionPollInterval
        permissionWalkthroughMonitor = Task { [weak self] in
            for _ in 0..<AppModel.permissionWalkthroughMaximumChecks {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.isPermissionWalkthroughActive else { return }
                self.refreshPermissions()
            }
            self?.endPermissionWalkthrough()
        }
    }

    /// Stops setup and its re-checks. Cards already on screen stay until dismissed or granted.
    func endPermissionWalkthrough() {
        isPermissionWalkthroughActive = false
        permissionWalkthroughPermissions = []
        presentedWalkthroughPermission = nil
        presentedWalkthroughAction = nil
        permissionWalkthroughMonitor?.cancel()
        permissionWalkthroughMonitor = nil
    }

    /// Re-reads Accessibility and Input Monitoring silently; neither ever prompts. Only tests call these.
    func requestAccessibilityPermission() { detector.requestAccessibilityPermission(); refreshPermissions() }
    func requestInputMonitoringPermission() { detector.requestInputMonitoringPermission(); refreshPermissions() }
    func retryDetection() { if preferences.enabledCapabilities.contains(.keyboardShortcutter) { detector.start() }; refreshDetectorState() }
    func applicationDidBecomeActive() {
        checkPermissionsAfterReturn()
        if relaunchPromptPermission == nil {
            relaunchPromptPermission = permissionsRequiringRelaunch.first
        }
    }

    /// Another app came to the front. Leaving System Settings for another app counts as returning
    /// from a permission step, since the setup cards never make Keybumps active. If macOS applies
    /// the access only after a relaunch, Restart appears on a card. Keybumps' own activation takes
    /// `applicationDidBecomeActive`. The bundle identifier is only compared, never kept.
    func applicationDidActivate(bundleIdentifier: String?) {
        guard permissionRelaunchAdvisor.isAwaitingReturn,
              bundleIdentifier != SystemSettingsPage.applicationBundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        checkPermissionsAfterReturn()
        showRelaunchCardIfNeeded(for: MacPermission.allCases)
    }

    private func checkPermissionsAfterReturn() {
        refreshPermissions()
        permissionRelaunchAdvisor.didBecomeActive { [permissions] permission in
            permissions.state(for: permission)
        }
        permissionsRequiringRelaunch = permissionRelaunchAdvisor.permissionsRequiringRelaunch
    }

    func applicationDidResignActive() {
        cancelShortcutRecording()
    }

    func dismissPermissionRelaunchPrompt() {
        relaunchPromptPermission = nil
    }

    /// A screenshot hotkey without Screen Recording asks macOS once (which may open System
    /// Settings); afterwards a brief notice points to Screenshot Tools settings, where Allow and
    /// Restart live (macOS reports a new grant only after Keybumps reopens).
    private func screenshotHotkeyNeedsScreenRecording() {
        guard preferences.didRequestScreenRecording else {
            preferences.didRequestScreenRecording = true
            permissions.requestScreenRecordingAccess()
            return
        }
        notice.show("Screen Recording needed · Keybumps Settings › Screenshot Tools", systemImage: "exclamationmark.triangle.fill", tint: .orange)
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
        capabilities.permissionsDidRefresh(capabilityContext)
        refreshDetectorState()
        updateMissingPermissionBadge()
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

    private func advancePermissionWalkthroughIfNeeded() {
        guard isPermissionWalkthroughActive else { return }
        guard let next = permissionWalkthroughPermissions.first(where: {
            !permissions.state(for: $0).isGranted
        }) else {
            endPermissionWalkthrough()
            return
        }
        let action = permissions.recoveryAction(for: next)
        guard next != presentedWalkthroughPermission else {
            // The user answered a native prompt with Don't Allow. Setup stops rather than open
            // System Settings unasked; the next Dictation shortcut offers System Settings recovery.
            if presentedWalkthroughAction == .request, action == .openSystemSettings {
                endPermissionWalkthrough()
            }
            return
        }
        presentedWalkthroughPermission = next
        presentedWalkthroughAction = action
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
        guard isLicensed else { openLicenseSettings(); return }
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
        guard isLicensed, preferences.enabledCapabilities.contains(.clipboardHistory) else { return }
        commandPalette.show(.clipboard)
    }
    func showDictationHistory() { guard isLicensed else { return }; commandPalette.show(.dictation) }
    func showKeyboardShortcutterHistory() { guard isLicensed else { return }; commandPalette.show(.keyboardShortcutter) }
    func showCommandPalette(_ tab: CommandPaletteTab) { guard isLicensed else { return }; commandPalette.show(tab) }
    /// Shows the sample tip in the notch without adding it to history.
    func showSampleTip() { coachTips.showCoach(NotchCoachPresentation(event: .sample)) }
    func openPermissionSettings(_ permission: MacPermission) {
        permissions.openSettings(permission)
    }
    func setShowInDockAndSwitcher(_ show: Bool) { preferences.showInDockAndSwitcher = show; presenceController.apply(showInDockAndSwitcher: show) }
    func markRead(_ id: UUID) { inbox.markRead(id) }
    func markAllRead() { inbox.markAllRead() }
    func clearHistory() { inbox.clear() }
    /// Records a detected action in history, then shows its tip in the notch.
    func deliver(_ event: CoachingEvent) {
        guard preferences.enabledCapabilities.contains(.keyboardShortcutter),
              (try? inbox.append(event)) != nil else { return }
        coachTips.showCoach(NotchCoachPresentation(event: event))
    }

    private func updateMissingPermissionBadge() {
        NSApplication.shared.dockTile.badgeLabel = missingPermissionCount > 0 ? "!" : nil
    }

}
