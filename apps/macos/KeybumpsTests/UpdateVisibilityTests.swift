import AppKit
import Foundation
import Testing
@testable import Keybumps

// Making updates hard to miss (#225): hourly checks, a restart prompt that comes back every hour
// until the restart, a red dot on the menu bar icon, and What's New after an update. Nothing here
// shows a real window, restarts the app, or contacts the update feed.

// MARK: - The restart prompt

@MainActor
@Suite("Updates: the restart prompt")
struct UpdateReminderTests {
    static let ready = UpdateSnapshot(status: .readyToRestart(version: "0.0.3-beta.14"), automaticallyChecks: true, canCheck: false, canRestart: true)
    static let idle = UpdateSnapshot(status: .current, automaticallyChecks: true, canCheck: true, canRestart: false)

    @Test("It asks as soon as an update is ready and restarting is safe, and waits while it isn't")
    func asksWhenReadyAndSafe() {
        let fixture = ReminderFixture(snapshot: Self.idle)
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.isEmpty, "Nothing is ready")

        fixture.snapshot = Self.ready
        fixture.isSafe = false
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.isEmpty, "Not while restarting isn't safe, such as during Dictation")

        fixture.isSafe = true
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown == ["0.0.3-beta.14"])
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.count == 1, "Not twice while it's showing")
    }

    @Test("Later brings it back an hour later, every hour until the restart")
    func laterComesBack() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.presenter.chooseLater()
        #expect(!fixture.presenter.isShowing)

        fixture.now += 59 * 60
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.count == 1, "Not within the hour")

        fixture.now += 60
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.count == 2, "Back after an hour")
        fixture.presenter.chooseLater()
        fixture.now += 60 * 60
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.count == 3, "And every hour after that")
    }

    @Test("A newer update asks right away, even within the hour")
    func newerUpdateAsksAgain() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.presenter.chooseLater()
        fixture.snapshot = UpdateSnapshot(status: .readyToRestart(version: "0.0.3-beta.15"), automaticallyChecks: true, canCheck: false, canRestart: true)
        fixture.now += 60
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown == ["0.0.3-beta.14", "0.0.3-beta.15"])
    }

    @Test("Restart Now restarts through the safe path; the prompt closes once nothing is waiting")
    func restartNow() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.presenter.chooseRestart()
        #expect(fixture.restarts == 1)
        #expect(!fixture.presenter.isShowing)

        fixture.reminder.evaluate()
        fixture.snapshot = Self.idle
        fixture.reminder.evaluate()
        #expect(!fixture.presenter.isShowing, "Nothing left to restart for")
    }

    @Test("The prompt says which version is waiting, or just that an update is")
    func promptText() {
        #expect(UpdatePromptText.title(version: "0.0.3-beta.14") == "Keybumps 0.0.3-beta.14 is ready")
        #expect(UpdatePromptText.title(version: nil) == "A Keybumps update is ready")
    }
}

// MARK: - The menu bar

@MainActor
@Suite("Updates: the menu bar")
struct UpdateMenuBarTests {
    @Test("While an update waits, the icon shows a red dot and Restart to Update is the first item")
    func waitingUpdate() throws {
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureUpdater(snapshot: { UpdateReminderTests.ready }, checkNow: {}, restartWhenSafe: {})
        let menu = controller.makeMenu()
        #expect(menu.items.first?.title == "Restart to Update")
        #expect(menu.items.filter { $0.title == "Restart to Update" }.count == 1)
        #expect(NativeStatusItemController.showsUpdateBadge(UpdateReminderTests.ready))

        controller.configureUpdater(snapshot: { UpdateReminderTests.idle }, checkNow: {}, restartWhenSafe: {})
        #expect(controller.makeMenu().items.first?.title == "Open Keybumps")
        #expect(!NativeStatusItemController.showsUpdateBadge(UpdateReminderTests.idle))
    }

    @Test("Keybumps checks for updates every hour, Sparkle's shortest interval")
    func hourlyChecks() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int == 3600)
    }
}

// MARK: - What's New

@MainActor
@Suite("Updates: What's New")
struct WhatsNewTests {
    @Test("It shows once after an update, never after a fresh install, and only with notes")
    func whenItShows() {
        #expect(WhatsNew.shouldShow(currentVersion: "0.0.3-beta.14", lastLaunchedVersion: "0.0.3-beta.13", completedOnboarding: true, hasNotes: true))
        #expect(WhatsNew.shouldShow(currentVersion: "0.0.3-beta.14", lastLaunchedVersion: nil, completedOnboarding: true, hasNotes: true),
                "Updated from a build that didn't record its version")
        #expect(!WhatsNew.shouldShow(currentVersion: "0.0.3-beta.14", lastLaunchedVersion: "0.0.3-beta.14", completedOnboarding: true, hasNotes: true),
                "Same version: already seen")
        #expect(!WhatsNew.shouldShow(currentVersion: "0.0.3-beta.14", lastLaunchedVersion: nil, completedOnboarding: false, hasNotes: true),
                "A fresh install shows onboarding instead")
        #expect(!WhatsNew.shouldShow(currentVersion: "0.0.3-beta.14", lastLaunchedVersion: "0.0.3-beta.13", completedOnboarding: true, hasNotes: false),
                "A build without notes (Debug, QA candidates)")
    }

    @Test("The last launched version is remembered")
    func remembersVersion() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.lastLaunchedVersion == nil)
        preferences.lastLaunchedVersion = "0.0.3-beta.14"
        #expect(AppPreferences(defaults: defaults).lastLaunchedVersion == "0.0.3-beta.14")
    }

    @Test("Release notes become a title, sections, callouts, bullets, and paragraphs")
    func parsesNotes() {
        let notes = ReleaseNotesDocument(markdown: """
        # Keybumps 0.0.3-beta.14

        This beta adds made-up things.
        It spans two lines.

        > **Heads up:** a made-up callout
        > - with a made-up point

        ## Snippets (new)

        - First made-up change
        - Second made-up change
        """)
        #expect(notes.blocks == [
            .title("Keybumps 0.0.3-beta.14"),
            .paragraph("This beta adds made-up things. It spans two lines."),
            .callout(["**Heads up:** a made-up callout", "- with a made-up point"]),
            .heading("Snippets (new)"),
            .bullet("First made-up change"),
            .bullet("Second made-up change"),
        ])
    }

    @Test("Release builds carry that version's notes into the app")
    func releaseBuildsCarryNotes() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: app.appendingPathComponent("scripts/build-update-release.sh"), encoding: .utf8)
        #expect(script.contains(#"KEYBUMPS_RELEASE_NOTES="$release_notes""#))
        let project = try String(contentsOf: app.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("WhatsNew.md"))
        #expect(WhatsNew.notesResourceName == "WhatsNew")
    }
}

// MARK: - Fixture

@MainActor
private final class ReminderFixture {
    var snapshot: UpdateSnapshot
    var isSafe = true
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private(set) var restarts = 0
    let presenter = RecordingPromptPresenter()
    private(set) var reminder: UpdateReminder!

    init(snapshot: UpdateSnapshot) {
        self.snapshot = snapshot
        reminder = UpdateReminder(
            snapshot: { [unowned self] in self.snapshot },
            isSafe: { [unowned self] in self.isSafe },
            restart: { [unowned self] in self.restarts += 1 },
            presenter: presenter,
            now: { [unowned self] in self.now }
        )
    }
}

@MainActor
private final class RecordingPromptPresenter: UpdatePromptPresenting {
    private(set) var shown: [String] = []
    private(set) var isShowing = false
    private var restart: (() -> Void)?
    private var later: (() -> Void)?

    func show(version: String?, restart: @escaping () -> Void, later: @escaping () -> Void) {
        shown.append(version ?? "")
        isShowing = true
        self.restart = restart
        self.later = later
    }

    func close() {
        isShowing = false
    }

    func chooseLater() { later?() }
    func chooseRestart() { restart?() }
}
