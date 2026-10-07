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
    let snippets: SnippetStore
    /// The Timers tab's countdowns, run by `TimerModule`.
    let timers: TimerStore
    /// Keyword auto-expansion, run by `SnippetsModule`; Settings reads whether it's listening.
    let keywordExpansion: KeywordExpansionController
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
    /// The capability a walkthrough sets up, or nil for every enabled capability.
    @ObservationIgnored private var permissionWalkthroughCapability: Capability?
    private let permissionPollInterval: Duration
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
    private(set) var updateSnapshot: UpdateSnapshot {
        didSet {
            updateReminder.evaluate()
            refreshUpdateAttention()
        }
    }
    /// Asks to restart while an update waits (#225).
    let updateReminder: UpdateReminder
    private let whatsNew: any WhatsNewPresenting
    let problemReports: any ProblemReportPresenting
    /// The menu bar icon's red dot: a waiting update, or a capability with something waiting.
    @ObservationIgnored let menuBarAttention = MenuBarAttention()
    /// Text beside the menu bar icon and capability sections in its menu, such as running timers.
    @ObservationIgnored let menuBarStatus = MenuBarStatus()
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
        snippets injectedSnippets: SnippetStore? = nil,
        textPaster injectedTextPaster: (any TextPasting)? = nil,
        keyTypingMonitor injectedKeyTypingMonitor: (any KeyTypingMonitoring)? = nil,
        updatePrompt injectedUpdatePrompt: (any UpdatePromptPresenting)? = nil,
        whatsNew injectedWhatsNew: (any WhatsNewPresenting)? = nil,
        problemReports injectedProblemReports: (any ProblemReportPresenting)? = nil,
        timers injectedTimers: TimerStore? = nil,
        timerAlerts injectedTimerAlerts: (any TimerAlerting)? = nil,
        translator injectedTranslator: (any TextTranslating)? = nil,
        dictationHistory injectedDictationHistory: DictationHistoryService? = nil,
        quickSearch injectedQuickSearch: QuickSearchModel? = nil,
        windows injectedWindows: WindowManagementService? = nil,
        screenshotTools injectedScreenshotTools: ScreenshotToolsService? = nil,
        dictationIndicator injectedDictationIndicator: DictationIndicatorController? = nil,
        coachTips: (any CoachTipPresenting)? = nil,
        dictationFileManager: FileManager = .default,
        allowsDictationSystemAccess: Bool = !UnitTestHost.isActive,
        screenshotEditorFallbackFolder: (() -> URL)? = nil,
        screenshotCapturer: ScreenshotCapturer? = nil,
        symbolicHotKeyPreferences: (any SymbolicHotKeyPreferences)? = nil,
        permissionPollInterval: Duration = .seconds(1)
    ) {
        self.preferences = preferences; self.inbox = inbox; self.presenceController = presenceController; self.detector = detector
        self.permissionPollInterval = permissionPollInterval
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
        // Unit tests never show these windows.
        self.updateReminder = UpdateReminder(
            snapshot: { updater.snapshot },
            isSafe: { updateSafetyPolicy.isSafeToInstall },
            restart: { updater.restartWhenSafe() },
            presenter: injectedUpdatePrompt ?? (UnitTestHost.isActive ? InertUpdatePromptPresenter() : UpdatePromptWindowController())
        )
        self.whatsNew = injectedWhatsNew ?? (UnitTestHost.isActive ? InertWhatsNewPresenter() : WhatsNewWindowController())
        self.problemReports = injectedProblemReports ?? (UnitTestHost.isActive ? InertProblemReportPresenter() : ProblemReportWindowController())
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
        let snippets = injectedSnippets ?? SnippetStore.makeDefault()
        self.snippets = snippets
        let timers = injectedTimers ?? TimerStore.makeDefault()
        self.timers = timers
        // Dictation and Snippets share one paste step. Unit tests and the UI-test composition never
        // synthesize ⌘V.
        let textPaster = injectedTextPaster
            ?? Self.makeTextPaster(clipboard: clipboard, allowsSystemAccess: allowsDictationSystemAccess)
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
            downloader: DictationModelDownloadRouter(
                whisperKit: WhisperKitModelDownloader(),
                whisperCpp: WhisperCppModelDownloader()
            )
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
            paster: textPaster,
            allowsSystemAccess: allowsDictationSystemAccess,
            // Re-read at paste time, through the same coordinator that drives setup and Settings.
            accessibilityTrusted: {
                permissions.refresh()
                return permissions.accessibilityGranted
            }
        )
        commandPalette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: dictation,
            preferences: preferences,
            snippets: snippets,
            paster: textPaster,
            search: injectedQuickSearch
        )
        // The restart prompt never appears over the palette, so it never takes the palette's keys.
        updateReminder.isSuppressed = { [commandPalette] in commandPalette.isVisible }
        // The palette's Settings button, Command-comma, and Quick Search commands take the status
        // menu's route; a capability's command asks for its page.
        commandPalette.openSettings = { section in MainWindowRouter.shared.open(section) }
        // Posting ⌘V into another app needs Accessibility, re-read from macOS on every paste. It's
        // optional for Snippets: without it ⌘Return copies and offers the usual permission setup.
        commandPalette.canPaste = {
            permissions.refresh()
            return permissions.accessibilityGranted
        }
        // Keyword auto-expansion listens only in the production composition: unit tests and the
        // UI-test composition never hear the keyboard, and their paste step never posts keys.
        let keywordExpansion = KeywordExpansionController(
            snippets: snippets,
            monitor: injectedKeyTypingMonitor ?? (UnitTestHost.isActive ? InertKeyTypingMonitor() : KeyTypingMonitor()),
            replacer: textPaster,
            // One restorer for keyword expansion and the palette's pastes, so quick pastes from
            // either put back the clipboard from before the first.
            restorer: commandPalette.clipboardRestorer
        )
        self.keywordExpansion = keywordExpansion
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
            KeyboardShortcutterModule(detector: detector, inbox: inbox, preferences: preferences),
            SnippetsModule(palette: commandPalette, snippets: snippets, expansion: keywordExpansion),
            TimerModule(
                palette: commandPalette,
                store: timers,
                preferences: preferences,
                attention: CapabilityMenuBarAttention(attention: menuBarAttention, capability: .timer),
                menuBar: CapabilityMenuBarStatus(status: menuBarStatus, capability: .timer),
                // Unit tests never play a sound or show a notice.
                alerts: injectedTimerAlerts ?? (UnitTestHost.isActive ? InertTimerAlerts() : SystemTimerAlerts())
            ),
            EmojiPickerModule(palette: commandPalette, preferences: preferences, recents: .makeDefault()),
            // Unit tests and the UI-test composition never download a language or translate.
            TranslationModule(
                palette: commandPalette,
                preferences: preferences,
                translator: injectedTranslator ?? TextTranslatorFactory.makeDefault()
            ),
        ])
        commandPalette.tabContents = capabilities.paletteContents
        detector.onEvent = { [weak self] event in Task { @MainActor in self?.deliver(event) } }
        dictationModule.onShortcut = { [weak self] in self?.handleDictationShortcut() }
        commandPalette.offerPasteSetup = { [weak self] plugin in self?.offerPasteSetup(for: plugin) }
        screenshotModule.onNeedsScreenRecording = { [weak self] in self?.screenshotHotkeyNeedsScreenRecording() }
        updater.onChange = { [weak self] snapshot in self?.updateSnapshot = snapshot }
        licensing.onChange = { [weak self] snapshot in self?.licenseDidChange(snapshot) }
        refreshDetectorState()
        refreshUpdateAttention()
    }

    private func refreshUpdateAttention() {
        if MenuBarAttention.updateIsWaiting(updateSnapshot) {
            menuBarAttention.show(.updateReady, saying: "update ready")
        } else {
            menuBarAttention.clear(.updateReady)
        }
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
        CrashReporter.recordPlugins(preferences.enabledCapabilities)
        updater.start()
        updateReminder.start()
        updateReminder.evaluate()
        showWhatsNewIfNeeded()
        previewUpdateWindowsIfAsked()
    }

    /// QA and Debug builds only: shows both update windows (`UpdatePreview`).
    private func previewUpdateWindowsIfAsked() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard UpdatePreview.isAllowed(version: version),
              UpdatePreview.isRequested else { return }
        if let notes = WhatsNew.bundledNotes() { whatsNew.show(ReleaseNotesDocument(markdown: notes)) }
        let prompt = updateReminder.presenter
        prompt.show(version: "\(version) (preview)", restart: { prompt.close() }, later: { prompt.close() })
    }

    /// After an update, shows that version's release notes once (#225), then records the version.
    func showWhatsNewIfNeeded(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        notes: String? = WhatsNew.bundledNotes()
    ) {
        // QA candidates carry notes only for the preview: they never show What's New or record a
        // version, so going back to a release afterwards doesn't show its notes again.
        guard !currentVersion.contains("-dev.") else { return }
        let shows = notes != nil && WhatsNew.shouldShow(
            currentVersion: currentVersion,
            lastLaunchedVersion: preferences.lastLaunchedVersion,
            completedOnboarding: preferences.didCompleteOnboarding,
            hasNotes: true
        )
        // Recorded first, so a problem showing it can't repeat it on every launch.
        preferences.lastLaunchedVersion = currentVersion
        if shows, let notes { whatsNew.show(ReleaseNotesDocument(markdown: notes)) }
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
        // Locked runs no capability, so there's nothing to set up.
        if !snapshot.isEntitled { endPermissionWalkthrough(); dismissDictationSetupCards() }
        guard wasLicensed != snapshot.isEntitled, isStarted, preferences.didCompleteOnboarding else { return }
        if !snapshot.isEntitled {
            // Locked: stop every capability's resources and shortcuts, and close the palette.
            let context = capabilityContext
            for capability in preferences.enabledCapabilities {
                capabilities.deactivate(capability, context: context)
                menuBarAttention.clear(.capability(capability))
                menuBarStatus.clear(capability)
            }
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
        if !enabled {
            capabilities.deactivate(capability, context: capabilityContext)
            // Nothing is left to open that would clear a turned-off capability's dot.
            menuBarAttention.clear(.capability(capability))
            menuBarStatus.clear(capability)
            // Setup for a capability that's now off would prompt for nothing.
            if isPermissionWalkthroughActive, permissionWalkthroughCapability == capability { endPermissionWalkthrough() }
            if capability == .dictation { dismissDictationSetupCards() }
        }
        preferences.setCapability(capability, enabled: enabled)
        applyCapabilities()
        CrashReporter.recordPlugins(preferences.enabledCapabilities)
    }

    /// Report a Problem… (ADR 0007): what the person writes, with this Mac's details attached.
    func showProblemReport() {
        problemReports.show(diagnostics: .current(model: self)) { [preferences] report in
            CrashReporter.send(report, plugins: preferences.enabledCapabilities)
        }
    }

    /// Settings › General's crash reports switch (ADR 0007): takes effect at once.
    func setSendsCrashReports(_ enabled: Bool) {
        preferences.sendsCrashReports = enabled
        CrashReporter.setEnabled(enabled)
        CrashReporter.recordPlugins(preferences.enabledCapabilities)
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

    /// Sets a plugin's declared preference from its Settings page, then applies the capabilities
    /// again, so its module picks it up at once.
    func setPluginPreference(_ preference: PluginPreference, to value: PluginPreference.Value, for capability: Capability) {
        preferences.set(value, of: preference, for: capability)
        applyCapabilities()
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
            if showSystemSettingsFollowUpIfNeeded(for: missing) { return }
            permissionDragAssistant.showDictationSetup(missingPermissions: missing) { [weak self] in
                self?.beginPermissionWalkthrough(for: .dictation)
            }
        case .continuePermissionSetup:
            continuePermissionWalkthrough()
        case .toggleDictation:
            dictation.toggle()
        }
    }

    /// The Dictation shortcut while setup is running. It never shows a second setup card; the
    /// time limit restarts, and the current step decides what the press shows.
    private func continuePermissionWalkthrough() {
        startPermissionWalkthroughMonitor()
        guard let current = presentedWalkthroughPermission else { return }
        switch permissions.recoveryAction(for: current) {
        case .openSystemSettings:
            if showSystemSettingsFollowUpIfNeeded(for: [current]) { return }
            Task { [weak self] in await self?.recoverPermission(current, fromSetupCard: true) }
        case .request:
            // While its request is outstanding, the prompt is on screen: leave it alone. Without
            // one, the prompt never appeared, so ask again; macOS shows it only while undecided.
            guard permissions.activeRequest == nil else { return }
            Task { [weak self] in await self?.recoverPermission(current, fromSetupCard: true) }
        case .none:
            break
        }
    }

    /// After System Settings was opened for a step that's still missing, Keybumps can't tell
    /// whether the user turned it on and macOS wants a relaunch (rare), or didn't turn it on.
    /// So instead of guessing, one card offers both: Open System Settings… and Restart Keybumps.
    /// It never records a relaunch as needed.
    @discardableResult
    private func showSystemSettingsFollowUpIfNeeded(for permissions: [MacPermission]) -> Bool {
        guard let permission = permissions.first(where: { permissionRelaunchAdvisor.hasOpenedSystemSettings(for: $0) }) else {
            return false
        }
        permissionDragAssistant.showSystemSettingsFollowUp(
            for: permission,
            openSystemSettings: { [weak self] in self?.beginPermissionWalkthrough(for: .dictation) },
            restart: { [weak self] in self?.restartForPermissionRelaunch() }
        )
        return true
    }

    /// After ⌘Return had to copy for lack of Accessibility: offers the usual Accessibility setup.
    private func offerPasteSetup(for plugin: Capability) {
        permissionDragAssistant.showPasteSetup(plugin: plugin.title) { [weak self] in
            Task { await self?.setUpPaste() }
        }
    }

    /// Set Up Paste…, offered after a plugin's ⌘Return had to copy. Like Dictation's card, it opens
    /// System Settings over another app, so that opening stays out of the Settings window's
    /// relaunch check.
    func setUpPaste() async {
        await recoverPermission(.accessibility, fromSetupCard: true)
    }

    /// `fromSetupCard`: started from a setup card over another app, as every setup walkthrough
    /// step and a plugin's Set Up Paste… are. Its System Settings opening stays out of the Settings
    /// window's relaunch check, so Keybumps becoming active later never claims a relaunch for it.
    func recoverPermission(_ permission: MacPermission, fromSetupCard: Bool = false) async {
        let isSetupStep = isPermissionWalkthroughActive
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
            if fromSetupCard {
                permissionRelaunchAdvisor.didOpenSystemSettingsFromCard(for: permission)
            } else {
                permissionRelaunchAdvisor.didOpenSystemSettings(for: permission)
            }
        }
        await permissions.performRecovery(for: permission)
        refreshPermissions()
        guard !permissions.state(for: permission).isGranted else { return }
        switch presentation {
        case .applicationDrag:
            try? await Task.sleep(for: .milliseconds(450))
            // Setup ended meanwhile: nothing would re-check the grant to take the card down.
            guard !isSetupStep || isPermissionWalkthroughActive else { return }
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
        permissionWalkthroughCapability = capability
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
            // A shortcut press may have started a new monitor since the last check.
            guard !Task.isCancelled else { return }
            self?.endPermissionWalkthrough()
        }
    }

    /// Stops setup and its re-checks, and takes down the current step's card: nothing re-checks
    /// its grant any more, and the next Dictation shortcut offers System Settings again.
    func endPermissionWalkthrough() {
        if let step = presentedWalkthroughPermission,
           [.applicationDrag(step), .enableSwitch(step)].contains(permissionDragAssistant.presentation) {
            permissionDragAssistant.dismiss()
        }
        isPermissionWalkthroughActive = false
        permissionWalkthroughPermissions = []
        permissionWalkthroughCapability = nil
        presentedWalkthroughPermission = nil
        presentedWalkthroughAction = nil
        permissionWalkthroughMonitor?.cancel()
        permissionWalkthroughMonitor = nil
    }

    /// Takes down the cards only the Dictation shortcut shows (its setup card, and Open System
    /// Settings… with Restart Keybumps) once Dictation can't run: their setup would end at once.
    private func dismissDictationSetupCards() {
        switch permissionDragAssistant.presentation {
        case .dictationSetup, .systemSettingsFollowUp: permissionDragAssistant.dismiss()
        default: break
        }
    }

    /// Re-reads Accessibility and Input Monitoring silently; neither ever prompts. Only tests call these.
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
        // Setup only for capabilities that can run: turning its capability off, or the app
        // locking, ends it.
        let running = capabilityContext.enabledCapabilities
        if let capability = permissionWalkthroughCapability, !running.contains(capability) {
            endPermissionWalkthrough()
            return
        }
        // A native prompt is on screen. Its own completion advances setup; moving on now would
        // start the next request while this one holds the coordinator, which then skips it.
        guard permissions.activeRequest == nil else { return }
        let needed = Set(PermissionSetupPlan.requiredPermissions(
            for: permissionWalkthroughCapability.map { [$0] } ?? running
        ))
        guard let next = permissionWalkthroughPermissions.first(where: {
            needed.contains($0) && !permissions.state(for: $0).isGranted
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
            // Setup may have ended before the step starts, for example on the monitor's last check.
            guard let self, self.isPermissionWalkthroughActive else { return }
            await self.recoverPermission(next, fromSetupCard: true)
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
    /// Sets a shortcut without ending a recording, as Replace does once recording has stopped.
    func setShortcut(_ binding: ShortcutBinding?, for owner: ShortcutOwner) {
        preferences.setShortcut(binding, for: owner)
        applyCapabilities()
    }
    func cancelShortcutRecording() {
        guard shortcuts.isSuspendedForRecording else { return }
        shortcuts.resumeAfterRecording()
    }
    /// Returns the plugin shortcuts that lost their keys to a window default.
    @discardableResult
    func restoreDefaultWindowShortcuts() -> [ShortcutOwner] {
        let moved = preferences.restoreDefaultWindowShortcuts()
        applyCapabilities()
        return moved
    }
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
