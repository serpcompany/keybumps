import AppKit
import Testing
@testable import Keybumps

@MainActor
@Suite("Quit confirmation")
struct QuitConfirmationTests {
    @Test("Momentary window actions and drags never block a quit")
    func windowOperationsDoNotBlockQuit() {
        let policy = UpdateInstallationSafetyPolicy()
        policy.updateCriticalOperation(.windowDrag, active: true)
        policy.updateCriticalOperation(.windowAction, active: true)

        #expect(!policy.isSafeToInstall, "They still defer automatic update relaunches")
        #expect(policy.quitConfirmationReasons.isEmpty)
        #expect(AppDelegate.terminateReply(reasons: policy.quitConfirmationReasons) { _ in
            Issue.record("Nothing to confirm")
            return false
        } == .terminateNow)
    }

    @Test("Unsaved editor work and live Dictation ask before quitting", arguments: [DictationPhase.recording, .transcribing, .inserting])
    func lostWorkAsksFirst(_ phase: DictationPhase) {
        let policy = UpdateInstallationSafetyPolicy()
        policy.updateCriticalOperation(.unsavedWork, active: true)
        policy.update(dictationPhase: phase)
        #expect(policy.quitConfirmationReasons == [
            "The Screenshot Editor has unsaved changes.",
            "Dictation is still in progress."
        ])

        var asked: [String] = []
        #expect(AppDelegate.terminateReply(reasons: policy.quitConfirmationReasons) { asked = $0; return false } == .terminateCancel)
        #expect(asked == policy.quitConfirmationReasons)
        #expect(AppDelegate.terminateReply(reasons: policy.quitConfirmationReasons) { _ in true } == .terminateNow)
    }

    @Test("Idle or failed Dictation does not block quitting", arguments: [DictationPhase.idle, .failed("Example")])
    func idleDictationDoesNotBlock(_ phase: DictationPhase) {
        let policy = UpdateInstallationSafetyPolicy()
        policy.update(dictationPhase: phase)
        #expect(policy.quitConfirmationReasons.isEmpty)
    }
}
