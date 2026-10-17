import AppKit
import Foundation
import Testing
@testable import Keybumps

/// The review around the person's choices (#464's review): a quit or relaunch, Screencast turned off
/// while a capture waits, captures that arrive one after another, and a context read that comes
/// late. Made-up captures in a temporary folder, a named pasteboard, and no window ordered in.
@MainActor
@Suite("Screencast: the review's lifecycle")
struct ScreencastReviewLifecycleTests {
    let fixture = ReviewFixture()
    static let safari = ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "keybumps.app")

    private func repository(_ text: String) throws -> ScreencastRepository {
        try #require(ScreencastRepository(text))
    }

    private func panel(outcomes: ReviewOutcomeLog) -> ScreencastReviewPanel {
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { nil }
        )
        panel.onFinish = { outcomes.outcomes.append($0) }
        return panel
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    // MARK: Quitting

    @Test("Quitting saves the review at once")
    func quitSavesAtOnce() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(mixdown: true)
        let model = fixture.model(input)
        model.note = "typed before quitting"
        model.repositoryText = "serpcompany/keybumps"

        model.saveNow()
        #expect(model.isFinished && fixture.outcomes == [.saved(input)])
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "typed before quitting")
        #expect(ScreencastReview.read(from: input.metadataURL)?.repository == "serpcompany/keybumps")
    }

    // MARK: Launching

    /// Applies `module` as a launch does, with `enabled` as the plugins turned on.
    private func apply(_ module: ScreencastModule, _ preferences: AppPreferences, enabled: Set<Capability>) {
        let permissions = PermissionCoordinator(screenRecordingAuthorized: { true })
        module.apply(CapabilityContext(
            enabledCapabilities: enabled,
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: DrawingHotKeyBackend()),
            permissions: permissions,
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
    }

    /// ScreenGrabs' recording on `preferences` and inert seams, with `review` as the review's services.
    private func module(_ preferences: AppPreferences, review: ScreencastReviewServices?) -> ScreencastModule {
        ScreencastModule(
            preferences: preferences,
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            openSettings: { _ in },
            seams: ScreencastSeams(presenter: FakeOverlays(), screens: { PickerScreens.both }, contextReader: .inert),
            review: review
        )
    }

    @Test("ScreenGrabs coming on cleans up, once a launch, after an export a quit cut short; never without the review's services or while it's off")
    func launchRecoversInterruptedExports() async throws {
        defer { fixture.tearDown() }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        // The unit-test host's own captures folder, never the person's.
        let captures = preferences.screencast.capturesFolder
        let recording = captures.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recording) }
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: recording.appendingPathComponent(ScreencastMetadata.fileName))
        let partial = recording.appendingPathComponent(".video-1.editing.mov")
        try Data("partial".utf8).write(to: partial)
        let services = ScreencastReviewServices(
            clipboard: fixture.clipboard,
            pasteboard: fixture.pasteboard,
            notices: nil,
            repositories: { [fixture] in fixture.repositories }
        )

        let bare = module(preferences, review: nil)
        apply(bare, preferences, enabled: [.screenshotTools])
        #expect(bare.review.recovery == nil, "a composition without services touches no folder")
        let launched = module(preferences, review: services)
        apply(launched, preferences, enabled: [])
        #expect(launched.review.recovery == nil, "nor while ScreenGrabs is off")

        apply(launched, preferences, enabled: [.screenshotTools])
        let recovery = try #require(launched.review.recovery)
        _ = await recovery.value
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        apply(launched, preferences, enabled: [.screenshotTools])
        #expect(launched.review.recovery == recovery, "once a launch")
    }

    // MARK: Turning Screencast off, and captures taking turns

    @Test("A capture finishing as Screencast turns off is saved, with its context once read, and never shown")
    func turnedOffBeforeThePanelOpens() async throws {
        defer { fixture.tearDown() }
        let gate = ContextGate()
        let flow = ScreencastReviewFlow(
            services: ScreencastReviewServices(
                clipboard: fixture.clipboard,
                pasteboard: fixture.pasteboard,
                notices: nil,
                repositories: { [fixture] in fixture.repositories }
            ),
            contextReader: ScreencastCaptureContextReader {
                await gate.wait()
                return Self.safari
            }
        )
        guard case .video(let capture) = try fixture.video() else { return }
        flow.captureStarting()
        flow.captureFinished(.video(capture))
        flow.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(flow.panel?.isShown != true)

        gate.open()
        try await eventually { ScreencastReview.read(from: capture.metadataURL) != nil }
        #expect(flow.panel?.isShown != true, "never shown")
        #expect(ScreencastReview.read(from: capture.metadataURL)?.context == Self.safari)
    }

    @Test("Captures take turns: one arriving during a slow Save waits, and none is skipped or left unsaved")
    func capturesTakeTurns() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let first = try fixture.video(name: "1791000000", mixdown: false)
        let second = try fixture.video(name: "1791000100")
        let third = try fixture.video(name: "1791000200")

        // The first's save waits for its context, which is slow to come.
        let gate = ContextGate()
        await panel.show(first, contextRead: Task { @MainActor in
            await gate.wait()
            return .none
        })
        panel.model?.note = "first"
        let showingSecond = Task { await panel.show(second) }
        try await eventually { panel.model?.isWorking == true }
        let showingThird = Task { await panel.show(third) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.model?.input == first, "the first is still saving")

        gate.open()
        await showingSecond.value
        await showingThird.value
        #expect(outcomes.outcomes.map(\.folder) == [first.folder, second.folder])
        #expect(panel.model?.input == third)
        #expect(ScreencastReview.read(from: first.metadataURL)?.note == "first")
        #expect(ScreencastReview.read(from: second.metadataURL) != nil, "the second was shown, then saved")
        await panel.close()
    }

    // MARK: A context that comes late

    @Test("The window shows at once; the guess fills the repository when the context comes, unless it was changed")
    func lateContextFillsTheGuess() async throws {
        defer { fixture.tearDown() }
        fixture.repositories.remember(try repository("serpcompany/keybumps"), for: Self.safari)

        let gate = ContextGate()
        let untouched = fixture.model(try fixture.video(name: "1791000000"), contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        #expect(untouched.repositoryText.isEmpty && untouched.context == .none)
        let typed = fixture.model(try fixture.video(name: "1791000100"), contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        typed.repositoryText = "serpcompany/other"

        gate.open()
        try await eventually { untouched.context == Self.safari && typed.context == Self.safari }
        #expect(untouched.repositoryText == "serpcompany/keybumps" && untouched.guess?.source == .website("keybumps.app"))
        #expect(typed.repositoryText == "serpcompany/other", "what the person typed stays")
    }

    @Test("Save waits for a context still on its way, and records it")
    func saveWaitsForTheContext() async throws {
        defer { fixture.tearDown() }
        let gate = ContextGate()
        let input = try fixture.video()
        let model = fixture.model(input, contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        let saving = Task { await model.save() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isFinished)
        gate.open()
        await saving.value
        #expect(model.isFinished)
        #expect(ScreencastReview.read(from: input.metadataURL)?.context == Self.safari)
    }
}

/// The outcomes a panel reports.
@MainActor
final class ReviewOutcomeLog {
    var outcomes: [ScreencastReviewOutcome] = []
}

/// Holds whoever waits until `open()`.
@MainActor
private final class ContextGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiting
        self.waiting = []
        waiting.forEach { $0.resume() }
    }
}

extension ScreencastReviewOutcome {
    var folder: URL? {
        switch self {
        case .saved(let input), .copied(let input), .saveFailed(let input, _): input.folder
        case .discarded: nil
        }
    }
}
