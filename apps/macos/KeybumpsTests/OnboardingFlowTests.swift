import Testing
@testable import Keybumps

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    private static let ready = QuickSearchShortcutOnboardingPresentation.resolve(.noConflict)

    @Test("With nothing in the way, onboarding is one screen")
    func oneScreenWhenNothingConflicts() {
        #expect(!OnboardingFlow.needsConflictScreen(shortcut: Self.ready, runningReferenceApps: []))
    }

    @Test("An unresolved Quick Search shortcut shows the conflict screen", arguments: [
        SpotlightShortcutConflictStatus.conflict,
        .unavailable(manualRecovery: "Remove the conflicting shortcut.")
    ])
    func unresolvedShortcutShowsConflicts(_ status: SpotlightShortcutConflictStatus) {
        let shortcut = QuickSearchShortcutOnboardingPresentation.resolve(status)
        #expect(OnboardingFlow.needsConflictScreen(shortcut: shortcut, runningReferenceApps: []))
    }

    @Test("A running reference app shows the conflict screen without blocking Start", arguments: ReferenceApp.allCases)
    func runningReferenceAppShowsConflicts(_ app: ReferenceApp) {
        #expect(OnboardingFlow.needsConflictScreen(shortcut: Self.ready, runningReferenceApps: [app]))
        #expect(Self.ready.canContinue)
    }
}
