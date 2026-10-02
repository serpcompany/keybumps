import AppKit
import AVFoundation
import Foundation
import Speech
import Testing
@testable import Keybumps

/// Dictation pastes by posting ⌘V, which macOS allows only with Accessibility (#192). These tests
/// lock that Dictation declares it, that setup asks for it once through System Settings and keeps
/// going on its own, that nothing outside the explicit request paths prompts, and that an
/// untrusted paste never posts.
@MainActor
@Suite("Dictation paste permission")
struct DictationPastePermissionTests {
    @Test("Dictation requires Accessibility, Microphone, and Speech Recognition, in setup order")
    func dictationDeclaresAccessibility() {
        #expect(CapabilityDescriptor.dictation.requiredPermissions == [.accessibility, .microphone, .speechRecognition])
        #expect(PermissionSetupPlan.requiredPermissions(for: [.dictation]) == [.accessibility, .microphone, .speechRecognition])
    }

    @Test("The setup plan lists Accessibility once, however many capabilities need it")
    func setupPlanListsAccessibilityOnce() {
        let sharers: Set<Capability> = [.dictation, .windowManagement, .keyboardShortcutter]
        for enabled in [sharers, Set(Capability.allCases)] {
            let plan = PermissionSetupPlan.requiredPermissions(for: enabled)
            #expect(plan.filter { $0 == .accessibility }.count == 1)
            #expect(plan.first == .accessibility)
        }

        var granted: Set<MacPermission> = [.microphone, .speechRecognition]
        var progress = PermissionSetupPlan.progress(for: [.dictation]) { granted.contains($0) ? .granted : .required }
        #expect(progress.currentPermission == .accessibility)
        #expect(progress.completedCount == 2)
        #expect(progress.totalCount == 3)
        granted.insert(.accessibility)
        progress = PermissionSetupPlan.progress(for: [.dictation]) { granted.contains($0) ? .granted : .required }
        #expect(progress.isComplete)
    }

    @Test("Without Accessibility, the Dictation shortcut shows setup, which recovers through System Settings")
    func missingAccessibilityRoutesToSystemSettingsSetup() {
        var states = Dictionary(uniqueKeysWithValues: MacPermission.allCases.map { ($0, PermissionAuthorizationState.granted) })
        states[.accessibility] = .required
        let readiness = PermissionReadinessSnapshot.resolve(
            enabledCapabilities: [.dictation],
            states: states,
            permissionsRequiringRelaunch: []
        )

        #expect(readiness.missingPermissions == [.accessibility])
        #expect(readiness.missingCount == 1, "drives the Permissions page and Dock attention badges")
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: readiness.missingPermissions) == .showPermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .recording, missingPermissions: readiness.missingPermissions) == .toggleDictation,
                "a Dictation already recording can still be stopped")
        let action = PermissionCoordinator.recoveryAction(for: .accessibility, state: .required)
        #expect(action == .openSystemSettings)
        #expect(PermissionRecoveryPresentation.resolve(permission: .accessibility, action: action) == .applicationDrag,
                "System Settings and the drag card, never a native prompt")
        #expect(PermissionSettingsRowAction.resolve(permission: .accessibility, state: .required, requiresRelaunch: false) == .recoverInSystemSettings)
    }

    @Test("While setup runs, the Dictation shortcut continues it instead of showing another setup card")
    func runningSetupRoutesToContinue() {
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: [.accessibility], isPermissionSetupRunning: true)
                == .continuePermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .failed("x"), missingPermissions: [.microphone], isPermissionSetupRunning: true)
                == .continuePermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: [], isPermissionSetupRunning: true) == .toggleDictation)
        #expect(DictationShortcutRouting.action(phase: .recording, missingPermissions: [.accessibility], isPermissionSetupRunning: true)
                == .toggleDictation)
    }

    @Test("Setup names every missing permission")
    func setupCopyNamesMissingPermissions() {
        #expect(MacPermission.names([]) == "")
        #expect(MacPermission.names([.accessibility]) == "Accessibility")
        #expect(MacPermission.names([.microphone, .speechRecognition]) == "Microphone and Speech Recognition")
        #expect(MacPermission.names([.accessibility, .microphone, .speechRecognition]) == "Accessibility, Microphone, and Speech Recognition")
        #expect(DictationSetupCopy.settingsNote(missing: [.accessibility])
                == "Dictation needs Accessibility access before its shortcut can record and paste.")
        #expect(PermissionAssistantCopy.systemSettingsFollowUp(for: .accessibility)
                == "Turned on Accessibility for Keybumps? Restart to finish.")
    }

    @Test("An insertion without Accessibility never runs the paste step")
    func untrustedInsertionNeverPastes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let paster = RecordingTextPaster()
        var accessibilityChecks = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            paster: paster,
            allowsSystemAccess: true,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return false
            }
        )

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 1)
        #expect(paster.pastes == 0)
        #expect(DictationInsertionError.accessibilityRequired.localizedDescription
                == "Dictation needs Accessibility access to paste. Your transcript was preserved.")
    }

    @Test("The shared ⌘V poster itself refuses to post without Accessibility")
    func pasteShortcutChecksAccessibilityItself() throws {
        var sent = 0
        #expect(throws: TextPasteError.accessibilityRequired) {
            try SystemTextPaster.postSystemCommandV(accessibilityTrusted: { false }, send: { _ in sent += 1 })
        }
        #expect(sent == 0)

        var flags: [CGEventFlags] = []
        try SystemTextPaster.postSystemCommandV(accessibilityTrusted: { true }, send: { flags.append($0.flags) })
        #expect(flags.count == 2, "⌘V down and up, sent to the fake, never to macOS")
        #expect(flags.allSatisfy { $0.contains(.maskCommand) })
    }

    @Test("In the unit-test host, Dictation has no system access and an inert paste step unless a test opts in")
    func unitTestHostDictationHasNoSystemAccess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var accessibilityChecks = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return true
            }
        )

        #expect(service.paster is InertTextPaster)
        service.start()
        #expect(service.phase == .failed("Audio capture is unavailable in this session."))
        await #expect(throws: DictationInsertionError.unavailableInSession) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 0)

        let harness = try PromptHarness()
        defer { harness.tearDown() }
        #expect(harness.model.dictation.paster is InertTextPaster, "AppModel's default paste step is inert too")
    }

    @Test("Dictation reads Accessibility through the permission coordinator")
    func appModelWiresAccessibilityIntoInsertion() async throws {
        let paster = RecordingTextPaster()
        let harness = try PromptHarness(allowsDictationSystemAccess: true, textPaster: paster)
        defer { harness.tearDown() }

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await harness.model.dictation.insert("transcript")
        }
        harness.grants.grant(.accessibility)
        // Trusted, the gate passes; with no recorded destination it stops before activating anything.
        await #expect(throws: DictationInsertionError.destinationUnavailable) {
            try await harness.model.dictation.insert("transcript")
        }
        #expect(paster.pastes == 0)
        #expect(harness.prompts.calls.isEmpty)
    }

    @Test("Refreshes, activation, and the Dictation shortcut never prompt or open System Settings")
    func nothingOutsideTheRequestPathPrompts() throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        for _ in 0..<5 {
            harness.model.refreshPermissions()
            harness.model.applicationDidBecomeActive()
        }
        #expect(harness.model.missingPermissions(for: .dictation) == [.accessibility, .microphone, .speechRecognition])
        #expect(harness.model.missingPermissionCount == 3)
        harness.pressDictationShortcut()
        harness.pressDictationShortcut()

        #expect(harness.prompts.calls.isEmpty)
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.accessibility, .microphone, .speechRecognition]))
        #expect(harness.model.dictation.phase == .idle, "the shortcut shows setup instead of recording")
    }

    @Test("Setup keeps going by itself: Accessibility through System Settings, then each native prompt once")
    func walkthroughAdvancesWithoutActivation() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.openSettings(.accessibility)] }
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        for _ in 0..<5 { harness.model.refreshPermissions() }
        #expect(harness.prompts.calls == [.openSettings(.accessibility)], "re-reading state never asks again")

        // Only the fake macOS changes from here: nothing calls refreshPermissions or activates Keybumps.
        harness.grants.grant(.accessibility)
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone])
        #expect(harness.model.permissionAssistantPresentation == nil, "the drag card goes once Accessibility is on")

        harness.grants.grant(.microphone)
        try await harness.waitUntil { harness.prompts.calls.count == 3 }
        harness.grants.grant(.speechRecognition)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }

        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone, .requestSpeechRecognition])
        #expect(harness.model.missingPermissions(for: .dictation).isEmpty)
    }

    @Test("Leaving System Settings without turning Keybumps on never claims a relaunch; the shortcut offers System Settings again")
    func leavingWithoutGrantingKeepsSystemSettingsReachable() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        // The user goes back to another app without turning Keybumps on; re-checks keep running.
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.model.relaunchPromptPermission == nil)
        #expect(!harness.model.requiresPermissionRelaunch(.accessibility), "the Permissions row keeps Open System Settings…")

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .systemSettingsFollowUp(.accessibility),
                "one card with Open System Settings… and Restart Keybumps, not a second setup card")
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty, "offering Restart records nothing")
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])

        // Open System Settings… on that card restarts the step, and its drag card comes back.
        harness.model.beginPermissionWalkthrough(for: .dictation)
        #expect(harness.model.permissionAssistantPresentation == nil)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .openSettings(.accessibility)])
    }

    @Test("Keybumps becoming active after the setup card opened System Settings never claims a relaunch")
    func activationAfterSetupCardClaimsNoRelaunch() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        harness.model.applicationDidBecomeActive()
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty, "not while setup runs")
        // The user never turns Keybumps on, setup stops, and Keybumps becomes active later, for
        // example to open Settings, with Accessibility still missing.
        harness.model.endPermissionWalkthrough()
        harness.model.applicationDidBecomeActive()

        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.model.relaunchPromptPermission == nil, "no Restart alert in the Settings window")
        #expect(PermissionSettingsRowAction.resolve(
            permission: .accessibility,
            state: harness.model.permissionReadiness.state(for: .accessibility),
            requiresRelaunch: harness.model.requiresPermissionRelaunch(.accessibility)
        ) == .recoverInSystemSettings, "the Permissions row still offers Open System Settings…")

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .systemSettingsFollowUp(.accessibility),
                "the shortcut still shows one card with Open System Settings… and Restart Keybumps")
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
    }

    @Test("A setup card's System Settings opening is never read as a relaunch, and a grant clears it")
    func setupCardOpeningStaysOutOfTheRelaunchCheck() {
        var advisor = PermissionRelaunchAdvisor()
        advisor.didOpenSystemSettingsFromCard(for: .accessibility)
        advisor.didBecomeActive { _ in .required }
        #expect(advisor.permissionsRequiringRelaunch.isEmpty)
        #expect(advisor.hasOpenedSystemSettings(for: .accessibility), "the shortcut's two-button card still reads it")

        advisor.permissionDidBecomeUsable(.accessibility)
        #expect(!advisor.hasOpenedSystemSettings(for: .accessibility))
        advisor.didOpenSystemSettingsFromCard(for: .microphone)
        #expect(!advisor.hasOpenedSystemSettings(for: .microphone), "as before, only drag-card permissions are recorded")
    }

    @Test("A card's recovery outside setup still shows the drag card, and records no relaunch")
    func cardRecoveryOutsideSetupShowsTheDragCard() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        await harness.model.recoverPermission(.accessibility, fromSetupCard: true)
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))
        harness.model.applicationDidBecomeActive()
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.model.relaunchPromptPermission == nil)
    }

    @Test("Snippets' Set Up Paste… opens System Settings as a setup card: Keybumps becoming active without the grant claims no relaunch")
    func snippetPasteSetupClaimsNoRelaunch() async throws {
        let harness = try PromptHarness(enabled: [.snippets])
        defer { harness.tearDown() }

        // ⌘Return in the Snippets tab had to copy for lack of Accessibility.
        harness.model.commandPalette.offerPasteSetup()
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
        // Set Up Paste…: System Settings and the drag card.
        await harness.model.setUpSnippetPaste()
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))

        // The user comes back to Keybumps without turning it on.
        harness.model.applicationDidBecomeActive()
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.model.relaunchPromptPermission == nil, "no Restart alert in the Settings window")
        #expect(PermissionSettingsRowAction.resolve(
            permission: .accessibility,
            state: harness.model.permissionReadiness.state(for: .accessibility),
            requiresRelaunch: harness.model.requiresPermissionRelaunch(.accessibility)
        ) == .recoverInSystemSettings, "the Permissions row still offers Open System Settings…")
    }

    @Test("Snippets' setup card stays while Accessibility is missing and goes once it's granted")
    func snippetPasteSetupCardGoesOnGrant() throws {
        let harness = try PromptHarness(enabled: [.snippets])
        defer { harness.tearDown() }

        harness.model.commandPalette.offerPasteSetup()
        harness.model.refreshPermissions()
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
        harness.grants.grant(.accessibility)
        harness.model.refreshPermissions()
        #expect(harness.model.permissionAssistantPresentation == nil)
        #expect(harness.prompts.calls.isEmpty, "showing the card asks macOS for nothing")
    }

    @Test("Opened from Keybumps' Settings window, a return without the grant still shows the Restart alert, and the shortcut's card offers System Settings beside Restart")
    func settingsWindowReturnKeepsItsRelaunchCheck() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        // The Permissions page's Open System Settings…: this flow is unchanged.
        await harness.model.recoverPermission(.accessibility)
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
        // Keybumps comes back, and macOS still reports no grant.
        harness.model.applicationDidBecomeActive()
        #expect(harness.model.permissionsRequiringRelaunch == [.accessibility])
        #expect(harness.model.relaunchPromptPermission == .accessibility, "the Settings window's Restart alert, as before")

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .systemSettingsFollowUp(.accessibility),
                "Open System Settings… beside Restart Keybumps")
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])

        // Once macOS reports the grant, the relaunch state, the alert, and the card go.
        harness.grants.grant(.accessibility)
        harness.model.refreshPermissions()
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty)
        #expect(harness.model.relaunchPromptPermission == nil)
        #expect(harness.model.permissionAssistantPresentation == nil)
    }

    @Test("The shortcut during setup leaves a prompt on screen alone, and asks again only if it never appeared")
    func shortcutDuringSetupRespectsPrompts() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }
        harness.grants.grant(.accessibility)
        let gate = Gate()
        harness.prompts.microphoneRequest = { await gate.wait() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.requestMicrophone] }
        // Microphone's prompt is on screen (its request is outstanding).
        harness.pressDictationShortcut()
        harness.pressDictationShortcut()
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.prompts.calls == [.requestMicrophone])
        #expect(harness.model.permissionAssistantPresentation == nil, "no second setup card")

        // The user closes the prompt without deciding (it never showed); the next press asks again.
        harness.prompts.microphoneRequest = nil
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        harness.pressDictationShortcut()
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        #expect(harness.prompts.calls == [.requestMicrophone, .requestMicrophone])
    }

    @Test("A re-check while a prompt is outstanding doesn't skip the next prompt")
    func recheckDuringPromptKeepsTheNextStep() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }
        harness.grants.grant(.accessibility)
        let gate = Gate()
        let grants = harness.grants
        // macOS reports the grant before the request returns, and re-checks run in between.
        harness.prompts.microphoneRequest = {
            grants.grant(.microphone)
            await gate.wait()
        }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.requestMicrophone] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.prompts.calls == [.requestMicrophone], "no step starts while Microphone's request is outstanding")

        gate.release()
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        #expect(harness.prompts.calls == [.requestMicrophone, .requestSpeechRecognition])
    }

    @Test("Answering Don't Allow to a native prompt ends setup instead of opening System Settings unasked")
    func declinedPromptEndsSetup() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }
        harness.grants.grant(.accessibility)

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.requestMicrophone] }
        harness.grants.deny(.microphone)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }
        #expect(harness.prompts.calls == [.requestMicrophone])

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.microphone, .speechRecognition]),
                "the next press offers setup again, which recovers a denial through System Settings")
    }

    @Test("Turning Dictation off ends its setup and takes down its drag card, so nothing follows for a capability that's off")
    func disablingDictationEndsSetup() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        harness.model.setCapability(.dictation, enabled: false)
        #expect(!harness.model.isPermissionWalkthroughActive)
        #expect(harness.model.permissionAssistantPresentation == nil)

        harness.grants.grant(.accessibility) // for example, for Window Manager
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
    }

    @Test("Turning Dictation off takes down its setup card and its two-button card, and leaves other cards alone")
    func disablingDictationDismissesItsCards() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.accessibility, .microphone, .speechRecognition]))
        harness.model.setCapability(.dictation, enabled: false)
        #expect(harness.model.permissionAssistantPresentation == nil, "Set Up Dictation… would set up nothing")

        // Setup opened System Settings and ended without the grant; the next press shows the two-button card.
        harness.model.setCapability(.dictation, enabled: true)
        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        harness.model.endPermissionWalkthrough()
        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .systemSettingsFollowUp(.accessibility))
        harness.model.setCapability(.dictation, enabled: false)
        #expect(harness.model.permissionAssistantPresentation == nil, "Open System Settings… would set up nothing")

        // The Permissions page's drag card, for example for Window Manager, isn't Dictation's.
        harness.model.setCapability(.dictation, enabled: true)
        await harness.model.recoverPermission(.accessibility)
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))
        harness.model.setCapability(.dictation, enabled: false)
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))

        // Nor is Snippets' Set Up Paste… card.
        harness.model.setCapability(.dictation, enabled: true)
        harness.model.commandPalette.offerPasteSetup()
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
        harness.model.setCapability(.dictation, enabled: false)
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
    }

    @Test("Locking ends setup, and the step's delayed drag card doesn't appear afterwards")
    func lockingEndsSetup() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.openSettings(.accessibility)] }
        // Before the drag card's 450 ms delay is up.
        await harness.model.deactivateLicense()
        #expect(!harness.model.isLicensed)
        #expect(!harness.model.isPermissionWalkthroughActive)
        try await Task.sleep(for: .milliseconds(600))
        #expect(harness.model.permissionAssistantPresentation == nil)

        harness.grants.grant(.accessibility)
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
    }

    @Test("Locking takes down Dictation's setup card and its two-button card, and leaves other cards alone")
    func lockingDismissesDictationCards() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.accessibility, .microphone, .speechRecognition]))
        await harness.model.deactivateLicense()
        #expect(harness.model.permissionAssistantPresentation == nil, "Set Up Dictation… would set up nothing")

        // During setup, after System Settings opened, the press shows the two-button card.
        await harness.model.activateLicense(key: FixedLicenseController.sampleCheck.key)
        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .systemSettingsFollowUp(.accessibility))
        await harness.model.deactivateLicense()
        #expect(!harness.model.isPermissionWalkthroughActive)
        #expect(harness.model.permissionAssistantPresentation == nil, "Open System Settings… would set up nothing")

        // The Permissions page's drag card, for example for Window Manager, isn't Dictation's.
        await harness.model.activateLicense(key: FixedLicenseController.sampleCheck.key)
        await harness.model.recoverPermission(.accessibility)
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))
        await harness.model.deactivateLicense()
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))

        // Nor is Snippets' Set Up Paste… card.
        await harness.model.activateLicense(key: FixedLicenseController.sampleCheck.key)
        harness.model.commandPalette.offerPasteSetup()
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
        await harness.model.deactivateLicense()
        #expect(harness.model.permissionAssistantPresentation == .snippetPasteSetup)
    }

    @Test("A step scheduled as setup ends never starts, as when the grant lands on the last re-check")
    func stepScheduledAsSetupEndsNeverStarts() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        // In one turn, like the monitor's last check: the re-check sees the grant and schedules
        // Microphone's step, then setup ends.
        harness.grants.grant(.accessibility)
        harness.model.refreshPermissions()
        harness.model.endPermissionWalkthrough()
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.prompts.calls == [.openSettings(.accessibility)], "no Microphone prompt after setup ended")
        #expect(harness.model.permissionAssistantPresentation == nil)
    }

    @Test("Setup stops re-checking after 600 checks, and leaves no drag card behind")
    func walkthroughMonitorIsBounded() async throws {
        let harness = try PromptHarness(pollInterval: .zero)
        defer { harness.tearDown() }

        let before = harness.grants.accessibilityReads
        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }
        try await Task.sleep(for: .milliseconds(600)) // past the step's delayed drag card
        #expect(harness.model.permissionAssistantPresentation == nil, "nothing would re-check the grant to take it down")
        let reads = harness.grants.accessibilityReads - before

        // One read per re-check, plus the few the first step makes itself.
        #expect((AppModel.permissionWalkthroughMaximumChecks...(AppModel.permissionWalkthroughMaximumChecks + 8)).contains(reads),
                "\(reads) reads")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.grants.accessibilityReads - before == reads, "no re-checks after the limit")
        #expect(AppModel.permissionWalkthroughMaximumChecks == 600, "10 minutes at one check a second")
    }

    @Test("Other System Settings pages open through the coordinator")
    func systemSettingsPagesOpenThroughTheCoordinator() throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.openKeyboardShortcutSettings()
        harness.model.permissions.openSystemSettings(.filesAndFolders)

        #expect(harness.prompts.calls == [.openSystemSettings(.keyboardShortcuts), .openSystemSettings(.filesAndFolders)])
        #expect(MacPermission.microphone.settingsURL == SystemSettingsPage.privacy(.microphone).url)
        #expect(SystemSettingsPage.filesAndFolders.url.absoluteString.hasSuffix("Privacy_FilesAndFolders"))
        #expect(SystemSettingsPage.keyboardShortcuts.url.absoluteString.hasSuffix("Keyboard-Settings.extension?Shortcuts"))
    }
}

@MainActor
@Suite("Permission prompt sources")
struct PermissionPromptSourceTests {
    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Keybumps", isDirectory: true)

    /// macOS prompt APIs, matched by method name so the receiver's spelling doesn't matter.
    /// They may appear only in `PermissionPrompts.swift`.
    private static let promptPatterns = [
        #"\bCGRequestScreenCaptureAccess\b"#,
        #"\brequestAccess\s*\("#,            // capture devices, contacts, calendars
        #"\brequest\w*Authorization\b"#,     // speech, notifications, location, photos
        #"\brequestRecordPermission\b"#,     // the audio application and session
        #"\bAVAudioApplication\b"#,
        #"\brequest(Full|WriteOnly)Access"#  // calendars and reminders
    ]

    /// Prompts for Accessibility, Input Monitoring, or event posting. Nothing may call these.
    private static let forbiddenPatterns = [
        #"\bAXIsProcessTrustedWithOptions\b"#,
        #"\bkAXTrustedCheckOptionPrompt\b"#,
        #"\bCGRequest(?!ScreenCaptureAccess)\w*Access\b"#, // the listen- and post-event requests
        #"\bIOHIDRequestAccess\b"#
    ]

    /// Ways to post keyboard events or drive another app's keyboard.
    private static let postingPatterns = [
        #"\.post\s*\(\s*tap:"#, #"\bCGEventPost"#, #"\bpostToPid\b"#, #"\bpostToPSN\b"#,
        #"\btapPostEvent\b"#, #"\bCGEventTapPostEvent\b"#, #"\bAXUIElementPostKeyboardEvent\b"#,
        #"\bNSAppleScript\b"#, #"\bOSAScript\b"#, #"\bkeystroke\s+""#, #"\bkey\s+code\s+\d"#
    ]

    /// The files allowed to post keyboard events. The poster must check Accessibility itself,
    /// because macOS drops an untrusted post and shows its own alert. Today that's the paste step
    /// Dictation and Snippets share.
    private static let keyboardEventPosters = ["Infrastructure/TextPaster.swift"]

    /// Test lines allowed to name the real prompts: this suite's own check that they're real.
    private static let allowedTestLines: Set<String> = ["#expect(PermissionPrompts" + ".system.kind == .system)"]

    @Test("The unit-test host's default prompts are inert")
    func unitTestHostPromptsAreInert() {
        #expect(UnitTestHost.isActive)
        #expect(PermissionPrompts.current.kind == .inert)
        #expect(PermissionPrompts.system.kind == .system)
    }

    @Test("The UI-test composition passes inert prompts and an inert paste step")
    func uiTestCompositionIsInert() throws {
        // `makeForUITesting` wipes the UI-test sandbox and creates a real preferences suite, so the
        // unit tests check its source instead of building it.
        let source = try String(contentsOf: Self.appDirectory.appendingPathComponent("App/UITestComposition.swift"), encoding: .utf8)
        for seam in ["requestMicrophone: PermissionPrompts.inert", "requestSpeechRecognition: PermissionPrompts.inert",
                     "requestScreenRecording: PermissionPrompts.inert", "openSystemSettings: PermissionPrompts.inert",
                     "allowsDictationSystemAccess: false", "textPaster: InertTextPaster()",
                     "keyTypingMonitor: InertKeyTypingMonitor()"] {
            #expect(source.contains(seam), "missing \(seam)")
        }
    }

    @Test("Undecided Microphone and Speech Recognition prompt only through the injected requests")
    func recoveryUsesTheInjectedPrompts() async {
        var calls: [String] = []
        let coordinator = PermissionCoordinator(
            accessibilityTrusted: { false },
            inputMonitoringAuthorized: { false },
            microphoneAuthorizationStatus: { .notDetermined },
            speechAuthorizationStatus: { .notDetermined },
            screenRecordingAuthorized: { false },
            requestMicrophone: { calls.append("microphone") },
            requestSpeechRecognition: { calls.append("speech") },
            requestScreenRecording: { calls.append("screenRecording") },
            openSettings: { calls.append("settings.\($0.rawValue)") },
            openSystemSettings: { _ in calls.append("settings.page") }
        )

        await coordinator.performRecovery(for: .microphone)
        await coordinator.performRecovery(for: .speechRecognition)
        await coordinator.performRecovery(for: .accessibility)
        await coordinator.performRecovery(for: .inputMonitoring)
        await coordinator.performRecovery(for: .screenRecording)

        #expect(calls == [
            "microphone", "speech", "settings.accessibility", "settings.inputMonitoring",
            "screenRecording", "settings.screenRecording"
        ])
    }

    @Test("Only PermissionPrompts calls a prompt API, and nothing prompts for Accessibility, Input Monitoring, or event posting")
    func promptAPIsLiveOnlyInPermissionPrompts() throws {
        let allowedFile = "Permissions/PermissionPrompts.swift"
        let sources = try Self.appSources()
        #expect(sources.keys.contains(allowedFile))
        #expect(Self.matches(Self.promptPatterns, in: sources[allowedFile] ?? "").count >= 3, "the patterns still find the real calls")

        for (path, text) in sources {
            #expect(Self.matches(Self.forbiddenPatterns, in: text).isEmpty, "\(path) asks macOS to prompt for Accessibility, Input Monitoring, or event posting")
            guard path != allowedFile else { continue }
            #expect(Self.matches(Self.promptPatterns, in: text).isEmpty, "\(path) prompts outside PermissionPrompts")
        }
    }

    @Test("Only the Accessibility-gated ⌘V poster posts keyboard events")
    func eventPostingLivesOnlyInThePasteStep() throws {
        let sources = try Self.appSources()
        let posters = sources.filter { _, text in !Self.matches(Self.postingPatterns, in: text).isEmpty }.keys.sorted()
        #expect(posters == Self.keyboardEventPosters)
    }

    @Test("Only SystemSettingsPage names a System Settings address")
    func systemSettingsAddressesLiveInOnePlace() throws {
        let sources = try Self.appSources()
        let openers = sources.filter { _, text in text.contains("x-apple.systempreferences") }.keys.sorted()
        #expect(openers == ["Infrastructure/SystemServices.swift"])
    }

    @Test("No test calls a prompt API, posts keyboard events, or uses the real system prompts")
    func testsNeverPrompt() throws {
        let token = "PermissionPrompts" + ".system"
        let sources = try FileManager.default.contentsOfDirectory(at: Self.testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(sources.contains { $0.lastPathComponent == "DictationPastePermissionTests.swift" }, "this file is scanned too")
        for source in sources {
            let text = try Self.scannableTestSource(String(contentsOf: source, encoding: .utf8))
            #expect(!text.contains(token), "\(source.lastPathComponent) uses the real permission prompts")
            #expect(Self.matches(Self.promptPatterns + Self.forbiddenPatterns + Self.postingPatterns, in: text).isEmpty,
                    "\(source.lastPathComponent) calls a macOS prompt or posting API")
        }
    }

    @Test("The test scan still sees code once pattern literals and allowed lines are removed")
    func testScanStripsOnlyLiteralsAndAllowedLines() {
        // Built by concatenation, so this file's own scan doesn't see these spellings.
        let audioApplication = "AVAudio" + "Application"
        let realPrompts = "PermissionPrompts" + ".system"
        let scanned = Self.scannableTestSource([
            "let pattern = #\"\\b\(audioApplication)\\b\"#",
            "    #expect(\(realPrompts).kind == .system)",
            "_ = AVCaptureDevice." + "request" + "Access(for: .audio)"
        ].joined(separator: "\n"))
        #expect(!scanned.contains(audioApplication))
        #expect(!scanned.contains(realPrompts))
        #expect(!Self.matches(Self.promptPatterns, in: scanned).isEmpty, "a real call is still caught")
    }

    /// A test source without raw-string literals (the pattern lists) and without allowed lines.
    private static func scannableTestSource(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !allowedTestLines.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
            .replacingOccurrences(of: ##"#"[^"\n]*"#"##, with: "", options: .regularExpression)
    }

    private static func matches(_ patterns: [String], in text: String) -> [String] {
        patterns.filter { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Every app Swift source, keyed by its path under `Keybumps/`.
    private static func appSources() throws -> [String: String] {
        let root = appDirectory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var sources: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
            sources[path] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }
}

// MARK: - Harness

/// A temporary folder for Dictation's history and recovery file, so no test reaches the owner's folders.
private struct Sandbox {
    let root: URL
    let fileManager: FileManager
    let history: DictationHistoryService

    @MainActor
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPastePermission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileManager = SandboxRootedFileManager(root: root)
        history = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Holds a fake request open until the test releases it, like a prompt waiting for the user.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Records every prompt and System Settings request a coordinator makes.
private final class PromptRecorder {
    enum Call: Equatable {
        case requestMicrophone
        case requestSpeechRecognition
        case requestScreenRecording
        case openSettings(MacPermission)
        case openSystemSettings(SystemSettingsPage)
    }

    private(set) var calls: [Call] = []
    /// Runs inside the fake Microphone request, before it returns.
    var microphoneRequest: (() async -> Void)?

    func record(_ call: Call) { calls.append(call) }
}

/// What the fake macOS reports. Everything starts undecided (Microphone, Speech Recognition) or missing.
private final class FakeGrants {
    private var granted: Set<MacPermission> = []
    private var denied: Set<MacPermission> = []
    /// How often the permission coordinator has read Accessibility.
    private(set) var accessibilityReads = 0

    func grant(_ permission: MacPermission) { granted.insert(permission) }
    func deny(_ permission: MacPermission) { denied.insert(permission) }
    func contains(_ permission: MacPermission) -> Bool { granted.contains(permission) }

    func readAccessibility() -> Bool {
        accessibilityReads += 1
        return granted.contains(.accessibility)
    }

    func microphoneStatus() -> AVAuthorizationStatus {
        granted.contains(.microphone) ? .authorized : denied.contains(.microphone) ? .denied : .notDetermined
    }

    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus {
        granted.contains(.speechRecognition) ? .authorized : denied.contains(.speechRecognition) ? .denied : .notDetermined
    }
}

/// Counts pastes instead of writing a pasteboard or posting ⌘V.
@MainActor
private final class RecordingTextPaster: TextPasting {
    private(set) var pastes = 0

    func paste(_ text: String, concealed: Bool) throws {
        pastes += 1
    }
}

/// An `AppModel` with only Dictation on (or only `enabled`), whose permissions, prompts, and paste
/// step are fakes.
@MainActor
private final class PromptHarness {
    let prompts: PromptRecorder
    let grants: FakeGrants
    let model: AppModel
    private let sandbox: Sandbox
    private let pasteboard: NSPasteboard
    private let clipboard: ClipboardHistoryService

    init(
        enabled: Set<Capability> = [.dictation],
        allowsDictationSystemAccess: Bool = false,
        textPaster: (any TextPasting)? = nil,
        pollInterval: Duration = .milliseconds(10)
    ) throws {
        let prompts = PromptRecorder()
        let grants = FakeGrants()
        self.prompts = prompts
        self.grants = grants
        sandbox = try Sandbox()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsPastePermission-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.didCompleteOnboarding = true
        for capability in Capability.allCases {
            preferences.setCapability(capability, enabled: enabled.contains(capability))
        }
        clipboard = ClipboardHistoryService(
            fileManager: sandbox.fileManager,
            storageURL: sandbox.root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: sandbox.root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )

        let permissions = PermissionCoordinator(
            accessibilityTrusted: { grants.readAccessibility() },
            inputMonitoringAuthorized: { grants.contains(.inputMonitoring) },
            microphoneAuthorizationStatus: { grants.microphoneStatus() },
            speechAuthorizationStatus: { grants.speechStatus() },
            screenRecordingAuthorized: { grants.contains(.screenRecording) },
            requestMicrophone: {
                prompts.record(.requestMicrophone)
                await prompts.microphoneRequest?()
            },
            requestSpeechRecognition: { prompts.record(.requestSpeechRecognition) },
            requestScreenRecording: { prompts.record(.requestScreenRecording) },
            openSettings: { prompts.record(.openSettings($0)) },
            openSystemSettings: { prompts.record(.openSystemSettings($0)) }
        )
        model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: DiscardingPersistence()),
            presenceController: InertPresence(),
            detector: ManualActionDetector(
                monitor: IdlePointerMonitor(),
                permissions: FakeDetectorPermissions(isGranted: { grants.contains($0) })
            ),
            shortcutCoordinator: GlobalShortcutCoordinator(backend: IdleHotKeyBackend()),
            permissionCoordinator: permissions,
            updater: DisabledUpdateController(reason: "Dictation paste permission tests"),
            dictationModelManager: DictationModelManager(
                modelsRoot: sandbox.root.appendingPathComponent("models", isDirectory: true),
                downloader: WhisperKitModelDownloader()
            ),
            spotlightShortcutResolver: InertSpotlightShortcutResolver(),
            clipboard: clipboard,
            textPaster: textPaster,
            dictationHistory: sandbox.history,
            dictationIndicator: SilentIndicator(),
            dictationFileManager: sandbox.fileManager,
            allowsDictationSystemAccess: allowsDictationSystemAccess,
            permissionPollInterval: pollInterval
        )
    }

    func pressDictationShortcut() {
        (model.capabilities.module(for: .dictation) as? DictationModule)?.onShortcut?()
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for the permission walkthrough")
    }

    func tearDown() {
        model.endPermissionWalkthrough()
        clipboard.stop()
        pasteboard.releaseGlobally()
        sandbox.remove()
    }
}

private final class SandboxRootedFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

private struct FakeDetectorPermissions: DetectorPermissionProviding {
    let isGranted: (MacPermission) -> Bool
    var isAccessibilityTrusted: Bool { isGranted(.accessibility) }
    var isInputMonitoringAuthorized: Bool { isGranted(.inputMonitoring) }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

private final class IdlePointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { true }
    func stop() {}
}

@MainActor
private final class IdleHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

private struct InertPresence: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

private struct DiscardingPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

private final class SilentIndicator: DictationIndicatorController {
    override func update(_ phase: DictationPhase) {}
}
