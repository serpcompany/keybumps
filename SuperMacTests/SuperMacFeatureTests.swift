import Carbon.HIToolbox
import Security
import XCTest
@testable import SuperMac

@MainActor
final class SuperMacFeatureTests: XCTestCase {
    func testDictationInsertionTargetCanResolveAStillRunningApplication() throws {
        let currentApplication = NSRunningApplication.current
        let target = DictationInsertionTarget(application: currentApplication)

        XCTAssertEqual(target.processIdentifier, currentApplication.processIdentifier)
        XCTAssertEqual(
            try XCTUnwrap(target.runningApplication()).processIdentifier,
            currentApplication.processIdentifier
        )
    }

    func testSignedAppHasMicrophoneCaptureEntitlement() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        ) as? Bool

        XCTAssertEqual(value, true)
    }

    func testDictationShortcutStartsPermissionRecoveryInsteadOfFailingSilently() {
        XCTAssertEqual(
            DictationShortcutRouting.action(
                phase: .idle,
                missingPermissions: [.microphone, .speechRecognition]
            ),
            .showPermissionSetup
        )
        XCTAssertEqual(
            DictationShortcutRouting.action(phase: .idle, missingPermissions: []),
            .toggleDictation
        )
        XCTAssertEqual(
            DictationShortcutRouting.action(phase: .recording, missingPermissions: [.microphone]),
            .toggleDictation
        )
    }

    func testWindowShortcutCustomizationPersistsAndMovesDuplicateBinding() {
        let suite = "SuperMacWindowShortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let binding = SuperMacWindowAction.left.defaultShortcut!

        preferences.setWindowShortcut(binding, for: .right)

        XCTAssertNil(preferences.windowShortcut(for: .left))
        XCTAssertEqual(preferences.windowShortcut(for: .right), binding)
        XCTAssertEqual(AppPreferences(defaults: defaults).windowShortcut(for: .right), binding)
        preferences.setWindowShortcut(nil, for: .right)
        XCTAssertNil(preferences.windowShortcut(for: .right))
    }

    func testCapabilityShortcutsCanBeRecordedClearedPersistedAndReassigned() throws {
        let suite = "SuperMacCapabilityShortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.capabilityShortcut(for: .quickSearch), DefaultShortcut.quickSearch)
        XCTAssertEqual(preferences.capabilityShortcut(for: .clipboardHistory), DefaultShortcut.clipboard)
        XCTAssertEqual(preferences.capabilityShortcut(for: .dictation), DefaultShortcut.dictation)

        preferences.setCapabilityShortcut(nil, for: .dictation)
        XCTAssertNil(AppPreferences(defaults: defaults).capabilityShortcut(for: .dictation))

        let custom = ShortcutBinding(keyCode: 2, modifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥D")
        preferences.setCapabilityShortcut(custom, for: .dictation)
        XCTAssertEqual(AppPreferences(defaults: defaults).capabilityShortcut(for: .dictation), custom)

        preferences.setCapabilityShortcut(custom, for: .quickSearch)
        XCTAssertNil(preferences.capabilityShortcut(for: .dictation))
        XCTAssertEqual(preferences.capabilityShortcut(for: .quickSearch), custom)

        preferences.setWindowShortcut(custom, for: .left)
        XCTAssertNil(preferences.capabilityShortcut(for: .quickSearch))
        XCTAssertEqual(preferences.windowShortcut(for: .left), custom)

        let migrationSuite = "SuperMacCapabilityShortcutMigration-\(UUID().uuidString)"
        let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
        migrationDefaults.set(
            try JSONEncoder().encode([SuperMacWindowAction.left.rawValue: DefaultShortcut.dictation]),
            forKey: "windowShortcuts"
        )
        let migrated = AppPreferences(defaults: migrationDefaults)
        XCTAssertEqual(migrated.windowShortcut(for: .left), DefaultShortcut.dictation)
        XCTAssertNil(migrated.capabilityShortcut(for: .dictation))
    }

    func testPermissionRecoveryActionsNeverLeaveARequiredPermissionInert() {
        for permission in MacPermission.allCases {
            XCTAssertEqual(
                PermissionCoordinator.recoveryAction(for: permission, state: .granted),
                .none
            )
            XCTAssertNotEqual(
                PermissionCoordinator.recoveryAction(for: permission, state: .denied),
                .none,
                "\(permission.title) must provide a recovery action when denied"
            )
        }
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .microphone, state: .notDetermined), .request)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .speechRecognition, state: .notDetermined), .request)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .accessibility, state: .required), .requestAndOpenSystemSettings)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .inputMonitoring, state: .required), .requestAndOpenSystemSettings)
    }

    func testEverySystemSettingsRecoveryShowsTheMatchingVisibleAssistant() {
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .accessibility,
                action: .requestAndOpenSystemSettings
            ),
            .applicationDrag
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .microphone,
                action: .openSystemSettings
            ),
            .enableSwitch
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .speechRecognition,
                action: .openSystemSettings
            ),
            .enableSwitch
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .microphone,
                action: .request
            ),
            .nativePrompt
        )
        XCTAssertEqual(PermissionAssistantCopy.title, "SuperMac")
        XCTAssertEqual(
            PermissionAssistantCopy.dragInstruction,
            "Drag this card into the app list above"
        )
        XCTAssertEqual(
            PermissionAssistantCopy.switchInstruction(for: .microphone),
            "Turn on the Microphone switch in the list above."
        )
        XCTAssertFalse(PermissionAssistantCopy.switchInstruction(for: .microphone).contains("Add"))
    }

    func testPermissionSettingsLinksTargetTheCorrectPrivacyPanes() {
        XCTAssertTrue(MacPermission.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        XCTAssertTrue(MacPermission.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        XCTAssertTrue(MacPermission.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"))
        XCTAssertTrue(MacPermission.speechRecognition.settingsURL.absoluteString.hasSuffix("Privacy_SpeechRecognition"))
    }

    func testApplicationBundleDragPayloadRoundTripsAsAFileURL() throws {
        let applicationURL = Bundle.main.bundleURL
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacDragPayload-\(UUID().uuidString)"))

        XCTAssertTrue(ApplicationBundleDragPayload.write(applicationURL, to: pasteboard))
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]

        XCTAssertEqual(objects?.first?.filePathURL, applicationURL)
    }

    func testPermissionHelperDismissesOnlyAfterAnAcceptedDrop() {
        XCTAssertTrue(ApplicationBundleDragPayload.shouldDismiss(after: .copy))
        XCTAssertTrue(ApplicationBundleDragPayload.shouldDismiss(after: .move))
        XCTAssertFalse(ApplicationBundleDragPayload.shouldDismiss(after: []))
    }

    func testOnlyListBasedPermissionsUseTheApplicationDragAssistant() {
        XCTAssertTrue(MacPermission.accessibility.usesApplicationDragAssistant)
        XCTAssertTrue(MacPermission.inputMonitoring.usesApplicationDragAssistant)
        XCTAssertFalse(MacPermission.microphone.usesApplicationDragAssistant)
        XCTAssertFalse(MacPermission.speechRecognition.usesApplicationDragAssistant)
    }

    func testPermissionSetupPlanAdvancesInOrderAndSkipsUnneededOrGrantedPermissions() {
        let allCapabilities = Set(Capability.allCases)
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: allCapabilities),
            [.accessibility, .inputMonitoring, .microphone, .speechRecognition]
        )

        var granted: Set<MacPermission> = []
        var progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(progress.currentPermission, .accessibility)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.totalCount, 4)

        granted.formUnion([.accessibility, .inputMonitoring])
        progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(progress.currentPermission, .microphone)
        XCTAssertEqual(progress.completedCount, 2)

        let windowsOnly = PermissionSetupPlan.progress(for: [.windowManagement]) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(windowsOnly.requiredPermissions, [.accessibility])
        XCTAssertTrue(windowsOnly.isComplete)
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: [.dictation]),
            [.microphone, .speechRecognition]
        )
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: [.shortcutCoaching]),
            [.accessibility, .inputMonitoring]
        )

        granted = Set(MacPermission.allCases)
        progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertTrue(progress.isComplete)
        XCTAssertNil(progress.currentPermission)
        XCTAssertEqual(progress.completedCount, 4)
    }

    func testSettingsNavigationBackReturnsThroughVisitedScreensWithoutLooping() {
        var navigation = SettingsNavigationHistory()
        XCTAssertEqual(navigation.selection, .home)
        XCTAssertFalse(navigation.canGoBack)

        navigation.navigate(to: .dictation)
        navigation.navigate(to: .permissions)
        navigation.navigate(to: .permissions)
        XCTAssertEqual(navigation.backStack, [.home, .dictation])

        navigation.goBack()
        XCTAssertEqual(navigation.selection, .dictation)
        navigation.goBack()
        XCTAssertEqual(navigation.selection, .home)
        XCTAssertFalse(navigation.canGoBack)

        navigation.goBack()
        XCTAssertEqual(navigation.selection, .home)
    }

    func testHomeGrantPermissionStartsTheRelevantFlowWithoutNavigating() {
        XCTAssertEqual(
            HomeCapabilityAction.resolve(
                capability: .dictation,
                isEnabled: true,
                missingPermissions: [.microphone, .speechRecognition]
            ),
            .beginPermissionWalkthrough(.dictation)
        )
        XCTAssertEqual(
            HomeCapabilityAction.resolve(
                capability: .windowManagement,
                isEnabled: true,
                missingPermissions: [.accessibility]
            ),
            .beginPermissionWalkthrough(.windowManagement)
        )
        XCTAssertEqual(
            HomeCapabilityAction.resolve(
                capability: .dictation,
                isEnabled: false,
                missingPermissions: [.microphone]
            ),
            .navigate(.dictation)
        )
        XCTAssertEqual(
            HomeCapabilityAction.resolve(
                capability: .quickSearch,
                isEnabled: true,
                missingPermissions: []
            ),
            .showQuickSearch
        )
    }

    func testCapabilitiesDefaultEnabledAndPersist() {
        let suite = "SuperMacCapabilities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppPreferences(defaults: defaults)
        XCTAssertEqual(first.enabledCapabilities, Set(Capability.allCases))
        first.setCapability(.dictation, enabled: false)
        XCTAssertFalse(AppPreferences(defaults: defaults).enabledCapabilities.contains(.dictation))
    }

    func testDictationDurationDefaultsToFiveMinutesAndPersistsLongerChoices() {
        let suite = "SuperMacDictationDuration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppPreferences(defaults: defaults)
        XCTAssertEqual(first.dictationDurationLimit, .fiveMinutes)
        XCTAssertEqual(first.dictationDurationLimit.seconds, 300)
        XCTAssertEqual(
            DictationDurationLimit.allCases,
            [.fiveMinutes, .tenMinutes, .fifteenMinutes, .thirtyMinutes, .sixtyMinutes, .unlimited]
        )

        first.dictationDurationLimit = .thirtyMinutes
        XCTAssertEqual(AppPreferences(defaults: defaults).dictationDurationLimit, .thirtyMinutes)
        first.dictationDurationLimit = .unlimited
        XCTAssertNil(AppPreferences(defaults: defaults).dictationDurationLimit.seconds)
    }

    func testDictationTranscribesTheCompletedAudioArchiveRatherThanAnEarlyLiveResult() {
        XCTAssertEqual(DictationTranscriptionPlan.source, .completedAudioFile)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 10), 120)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 300), 600)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 3_600), 7_200)
    }

    func testClipboardKeepsTenAndCollapsesDuplicates() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ClipboardHistoryService(storageURL: url)
        for number in 0..<12 { service.ingestForTesting("item \(number)") }
        XCTAssertEqual(service.entries.count, 10)
        XCTAssertEqual(service.entries.first?.text, "item 11")
        XCTAssertFalse(service.entries.contains { $0.text == "item 0" })
        service.ingestForTesting("item 11")
        XCTAssertEqual(service.entries.count, 10)
        XCTAssertEqual(ClipboardHistoryService(storageURL: url).entries.count, 10)
    }

    func testDictationHistoryStoresOneMetadataAndAudioPairPerRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recordings-\(UUID().uuidString)")
        let sourceAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-source-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceAudio)
        }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: sourceAudio)
        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let capturedAt = Date(timeIntervalSince1970: 1_763_015_623)

        let entry = try service.record(
            "A saved dictation",
            language: "en-US",
            capturedAt: capturedAt,
            duration: 1.5,
            audioSourceURL: sourceAudio
        )

        XCTAssertEqual(entry.id, "1763015623")
        XCTAssertEqual(entry.text, "A saved dictation")
        XCTAssertEqual(entry.language, "en-US")
        XCTAssertEqual(entry.duration, 1.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(entry.audioURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dictation-history.json").path))

        let secondEntry = try service.record(
            "Another dictation from the same second",
            language: "ja-JP",
            capturedAt: capturedAt,
            duration: 2,
            audioSourceURL: sourceAudio
        )
        XCTAssertEqual(secondEntry.id, "1763015623-2")

        let reloaded = DictationHistoryService(recordingsDirectoryURL: root)
        XCTAssertEqual(reloaded.entries.map(\.id), ["1763015623-2", "1763015623"])

        reloaded.delete(try XCTUnwrap(reloaded.entries.first { $0.id == entry.id }))
        XCTAssertEqual(reloaded.entries.map(\.id), ["1763015623-2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directoryURL.path))
        reloaded.clear()
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondEntry.directoryURL.path))
    }

    func testDictationHistoryKeepsAllRecordingDirectoriesNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recordings-\(UUID().uuidString)")
        let sourceAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-source-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceAudio)
        }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: sourceAudio)
        let service = DictationHistoryService(recordingsDirectoryURL: root)

        for number in 0..<27 {
            try service.record(
                "dictation \(number)",
                language: number.isMultiple(of: 2) ? "en-US" : "ja-JP",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)),
                duration: Double(number),
                audioSourceURL: sourceAudio
            )
        }

        XCTAssertEqual(service.entries.count, 27)
        XCTAssertEqual(service.entries.first?.text, "dictation 26")
        XCTAssertEqual(service.entries.last?.text, "dictation 0")
    }

    func testDictationHistoryCopiesTranscriptWithoutUsingARealClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacDictationCopy-\(UUID().uuidString)"))

        XCTAssertTrue(DictationHistoryClipboard.copy("Copied dictation", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied dictation")
    }

    func testDictationHistoryPreservesAudioWhenTranscriptionFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failed-dictation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let pending = try service.prepareRecording(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: pending.audioURL)

        let entry = try service.completeRecording(
            pending,
            text: "",
            language: "en-US",
            duration: 300,
            transcriptionError: "Recognition unavailable"
        )

        XCTAssertEqual(entry.displayText, "Transcription unavailable")
        XCTAssertEqual(entry.metadata.transcriptionError, "Recognition unavailable")
        XCTAssertNotNil(entry.audioURL)
        let reloaded = try XCTUnwrap(DictationHistoryService(recordingsDirectoryURL: root).entries.first)
        XCTAssertEqual(reloaded.metadata, entry.metadata)
        XCTAssertEqual(reloaded.directoryURL.standardizedFileURL, entry.directoryURL.standardizedFileURL)
        XCTAssertEqual(reloaded.audioURL?.standardizedFileURL, entry.audioURL?.standardizedFileURL)
    }

    func testDictationHistoryAccordionKeepsOnlyOneExpandedRecording() {
        var expansion = DictationHistoryExpansion()

        expansion.toggle("first")
        XCTAssertEqual(expansion.expandedEntryID, "first")
        expansion.toggle("second")
        XCTAssertEqual(expansion.expandedEntryID, "second")
        expansion.toggle("second")
        XCTAssertNil(expansion.expandedEntryID)
    }

    func testDictationTranslationRequiresRealTranscriptText() {
        XCTAssertTrue(DictationTranslationPolicy.canTranslate("Translate this"))
        XCTAssertFalse(DictationTranslationPolicy.canTranslate("  \n "))
        XCTAssertEqual(
            DictationTranslationPolicy.preferredTargetIdentifier(
                sourceIdentifier: "en-US",
                supportedIdentifiers: ["fr", "ja", "es"]
            ),
            "ja"
        )
        XCTAssertEqual(
            DictationTranslationPolicy.preferredTargetIdentifier(
                sourceIdentifier: "ja-JP",
                supportedIdentifiers: ["fr", "en-US", "es"]
            ),
            "en-US"
        )
    }

    func testTranslatedSpeechSelectsAnInstalledVoiceForTheTargetLanguage() {
        let voices = [
            TranslationSpeechVoiceDescriptor(identifier: "english-us", language: "en-US"),
            TranslationSpeechVoiceDescriptor(identifier: "japanese", language: "ja-JP"),
            TranslationSpeechVoiceDescriptor(identifier: "english-uk", language: "en-GB")
        ]

        XCTAssertEqual(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "ja",
                supportedVoices: voices
            ),
            "japanese"
        )
        XCTAssertEqual(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "en-GB",
                supportedVoices: voices
            ),
            "english-uk"
        )
        XCTAssertNil(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "fr",
                supportedVoices: voices
            )
        )
    }

    func testCommandPaletteHasTheThreeRequestedTabsWithSearchAsDefault() {
        let state = CommandPaletteState()
        XCTAssertEqual(state.tab, .search)
        XCTAssertEqual(CommandPaletteTab.allCases, [.search, .clipboard, .dictation])

        state.historyQuery = "private filter"
        state.selection = 3
        state.select(.dictation)

        XCTAssertEqual(state.tab, .dictation)
        XCTAssertEqual(state.historyQuery, "")
        XCTAssertEqual(state.selection, 0)
    }

    func testSelectedRectangleShortcutProfileIsExactAndUnique() {
        let assigned = SuperMacWindowAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        XCTAssertEqual(assigned.count, 29)
        XCTAssertEqual(SuperMacWindowAction.left.defaultShortcut?.displayName, "⌃⌥⌘←")
        XCTAssertEqual(SuperMacWindowAction.lastFourth.defaultShortcut?.keyCode, 119)
        XCTAssertNil(SuperMacWindowAction.upperRight.defaultShortcut)
        XCTAssertEqual(Set(assigned.map { "\($0.1.keyCode)-\($0.1.modifiers)" }).count, assigned.count)
    }

    func testWindowGeometryCoversOwnerSlices() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let current = CGRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertEqual(WindowGeometry.frame(for: .left, in: screen, current: current), CGRect(x: 0, y: 0, width: 600, height: 900))
        XCTAssertEqual(WindowGeometry.frame(for: .centerThird, in: screen, current: current), CGRect(x: 400, y: 0, width: 400, height: 900))
        XCTAssertEqual(WindowGeometry.frame(for: .bottomRightSixth, in: screen, current: current), CGRect(x: 800, y: 0, width: 400, height: 450))
        XCTAssertEqual(WindowGeometry.frame(for: .lastThreeFourths, in: screen, current: current), CGRect(x: 300, y: 0, width: 900, height: 900))
    }
}
