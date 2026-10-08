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

    @Test("Restart Now restarts through the safe path and doesn't ask again while Keybumps quits")
    func restartNow() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.presenter.chooseRestart()
        #expect(fixture.restarts == 1)
        #expect(!fixture.presenter.isShowing)
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.count == 1, "No second prompt while the restart happens")
    }

    @Test("An open prompt stays put while restarting is briefly unsafe; only a new one waits")
    func staysPut() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.paletteIsOpen = true
        fixture.reminder.evaluate()
        #expect(fixture.presenter.shown.isEmpty, "Not over the Command Palette")

        fixture.paletteIsOpen = false
        fixture.reminder.evaluate()
        #expect(fixture.presenter.isShowing)
        fixture.isSafe = false
        fixture.paletteIsOpen = true
        fixture.reminder.evaluate()
        #expect(fixture.presenter.isShowing, "A window drag or the palette doesn't close or move it")
        #expect(fixture.presenter.shown.count == 1)

        fixture.snapshot = Self.idle
        fixture.reminder.evaluate()
        #expect(!fixture.presenter.isShowing, "Nothing left to restart for")
    }

    @Test("A Restart Now that waited too long asks again instead, and one for a gone update is dropped")
    func restartRequestExpires() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.isSafe = false
        fixture.presenter.chooseRestart()
        fixture.now += 121
        fixture.isSafe = true
        fixture.reminder.evaluate()
        #expect(fixture.restarts == 0, "Not long after the click, such as when a long Dictation ends")
        #expect(fixture.presenter.shown.count == 2, "It asks again")

        fixture.presenter.chooseLater()
        fixture.isSafe = false
        fixture.now += 60 * 60
        fixture.reminder.evaluate()
        fixture.isSafe = true
        fixture.reminder.evaluate()
        fixture.isSafe = false
        fixture.presenter.chooseRestart()
        fixture.snapshot = Self.idle
        fixture.reminder.evaluate()
        fixture.snapshot = Self.ready
        fixture.isSafe = true
        fixture.reminder.evaluate()
        #expect(fixture.restarts == 0, "The update went away, so the click is forgotten")
    }

    @Test("Restart Now while restarting isn't safe restarts as soon as it is")
    func restartWhenSafe() {
        let fixture = ReminderFixture(snapshot: Self.ready)
        fixture.reminder.evaluate()
        fixture.isSafe = false
        fixture.presenter.chooseRestart()
        #expect(fixture.restarts == 0)
        #expect(!fixture.presenter.isShowing)
        fixture.reminder.evaluate()
        #expect(fixture.restarts == 0, "Still recording")
        fixture.isSafe = true
        fixture.reminder.evaluate()
        #expect(fixture.restarts == 1)
        fixture.reminder.evaluate()
        #expect(fixture.restarts == 1, "Once")
    }

    @Test("A waiting update reaches the prompt and the red dot through the app model")
    func appModelWiring() {
        let fake = FakeUpdateController()
        let presenter = RecordingPromptPresenter()
        let model = AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: ManualActionDetector(monitor: UpdaterTestPointerMonitor(), permissions: UpdaterTestPermissions()),
            updater: fake,
            updatePrompt: presenter
        )
        var dotRefreshes = 0
        model.menuBarAttention.onChange = { dotRefreshes += 1 }
        #expect(!model.menuBarAttention.showsDot)

        fake.emit(.readyToRestart(version: "0.0.3-beta.14"), canRestart: true)
        #expect(dotRefreshes == 1)
        #expect(model.menuBarAttention.showsDot)
        #expect(model.menuBarAttention.accessibilityLabel(productName: "Keybumps") == "Keybumps, update ready")

        fake.emit(.idle, canRestart: false)
        #expect(!model.menuBarAttention.showsDot, "The dot goes once nothing waits")
        #expect(model.menuBarAttention.accessibilityLabel(productName: "Keybumps") == "Keybumps")
        #expect(presenter.shown == ["0.0.3-beta.14"])
        presenter.chooseRestart()
        #expect(fake.restartCount == 1)
    }

    @Test("An update already waiting at launch shows the dot")
    func dotAtLaunch() {
        let fake = FakeUpdateController()
        fake.emit(.readyToRestart(version: "0.0.3-beta.14"), canRestart: true)
        let model = AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: ManualActionDetector(monitor: UpdaterTestPointerMonitor(), permissions: UpdaterTestPermissions()),
            updater: fake,
            updatePrompt: RecordingPromptPresenter()
        )
        #expect(model.menuBarAttention.showsDot)
    }

    @Test("Update previews work only in QA and Debug builds")
    func previewsOnlyOutsidePublicBuilds() {
        #expect(UpdatePreview.isAllowed(version: "0.0.3-dev.issue225", isDebugBuild: false))
        #expect(!UpdatePreview.isAllowed(version: "0.0.3-beta.14", isDebugBuild: false))
        #expect(UpdatePreview.isAllowed(version: "0.0.3-beta.14", isDebugBuild: true))
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
        #expect(MenuBarAttention.updateIsWaiting(UpdateReminderTests.ready))

        controller.configureUpdater(snapshot: { UpdateReminderTests.idle }, checkNow: {}, restartWhenSafe: {})
        #expect(controller.makeMenu().items.first?.title == "Open Keybumps")
        #expect(!MenuBarAttention.updateIsWaiting(UpdateReminderTests.idle))
    }

    @Test("A status that names a newer version puts the red dot on the icon and on Check for Updates…; a check or failure doesn't")
    func availableUpdateDot() throws {
        let known: [UpdateStatus] = [
            .available(version: "0.0.3-beta.24"), .downloading(version: "0.0.3-beta.24"),
            .downloaded(version: "0.0.3-beta.24"), .readyToRestart(version: "0.0.3-beta.24"),
            .deferred(version: "0.0.3-beta.24"),
        ]
        for status in known {
            let snapshot = UpdateSnapshot(status: status, automaticallyChecks: true, canCheck: true, canRestart: false)
            #expect(MenuBarAttention.updateIsWaiting(snapshot), "\(status)")
            #expect(MenuBarAttention.updatePhrase(snapshot) == "update available")
            let item = try #require(Self.checkItem(snapshot))
            #expect(item.image?.accessibilityDescription == "Update available")
            #expect(item.toolTip == status.summary)
        }
        for status in [UpdateStatus.idle, .checking, .current, .failed("offline"), .unavailable("Not configured")] {
            let snapshot = UpdateSnapshot(status: status, automaticallyChecks: true, canCheck: true, canRestart: false)
            #expect(!MenuBarAttention.updateIsWaiting(snapshot), "\(status)")
            let item = try #require(Self.checkItem(snapshot))
            #expect(item.image == nil)
            #expect(item.toolTip == nil)
        }
        #expect(MenuBarAttention.updatePhrase(UpdateReminderTests.ready) == "update ready")
        #expect(try #require(Self.checkItem(UpdateReminderTests.ready)).image?.accessibilityDescription == "Update ready")
    }

    @Test("The menu's dot is drawn red, not tinted like a template image")
    func menuDotIsRed() throws {
        let dot = try #require(NativeStatusItemController.updateDot(saying: "update available"))
        #expect(!dot.isTemplate)
    }

    private static func checkItem(_ snapshot: UpdateSnapshot) -> NSMenuItem? {
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureUpdater(snapshot: { snapshot }, checkNow: {}, restartWhenSafe: {})
        return controller.makeMenu().item(withTitle: "Check for Updates…")
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

        ### Features

        - First made-up change
        - Second made-up change
        """)
        #expect(notes.blocks == [
            .title("Keybumps 0.0.3-beta.14"),
            .paragraph("This beta adds made-up things. It spans two lines."),
            .callout(["**Heads up:** a made-up callout", "- with a made-up point"]),
            .heading("Snippets (new)"),
            .heading("Features"),
            .bullet("First made-up change"),
            .bullet("Second made-up change"),
        ])
    }

    @Test("Every release's notes parse with no Markdown left showing")
    func realNotes() throws {
        let releases = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/releases")
        let files = try FileManager.default.contentsOfDirectory(atPath: releases.path).filter { $0.hasPrefix("v") && $0.hasSuffix(".md") }
        #expect(!files.isEmpty)
        for file in files {
            let notes = ReleaseNotesDocument(markdown: try String(contentsOf: releases.appendingPathComponent(file), encoding: .utf8))
            guard case .title = notes.blocks.first else { Issue.record("\(file) has no title"); continue }
            for block in notes.blocks {
                switch block {
                case .title(let text), .heading(let text), .paragraph(let text), .bullet(let text):
                    #expect(!text.hasPrefix("#") && !text.hasPrefix(">"), "\(file): \(text.prefix(20))")
                case .callout(let lines):
                    #expect(!lines.contains { $0.hasPrefix(">") }, "\(file)")
                }
            }
        }
    }

    @Test("Release builds carry that version's notes into the app")
    func releaseBuildsCarryNotes() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: app.appendingPathComponent("scripts/build-update-release.sh"), encoding: .utf8)
        #expect(script.contains(#"KEYBUMPS_RELEASE_NOTES="$release_notes""#))
        #expect(script.contains(#"cmp -s "$app_path/Contents/Resources/WhatsNew.md" "$release_notes""#),
                "Compared with the source notes, before generate_appcast changes its copy")
        let project = try String(contentsOf: app.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("WhatsNew.md"))
        #expect(WhatsNew.notesResourceName == "WhatsNew")
        let validate = try String(contentsOf: app.appendingPathComponent("scripts/validate-update-release.sh"), encoding: .utf8)
        #expect(validate.contains("Contents/Resources/WhatsNew.md"), "A release without its notes fails validation")
    }
}

// MARK: - Fixture

@MainActor
private final class ReminderFixture {
    var snapshot: UpdateSnapshot
    var isSafe = true
    var paletteIsOpen = false
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
        reminder.isSuppressed = { [unowned self] in self.paletteIsOpen }
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
