import AppKit
import Foundation
import Testing
@testable import Keybumps

// MARK: - Reading what you type

@Suite("Timer: reading a duration")
struct TimerDurationParserTests {
    @Test(
        "Durations, with an optional name before or after",
        arguments: [
            ("25", 1500.0, nil),
            ("2.5", 150, nil),
            ("90s", 90, nil),
            ("5m", 300, nil),
            ("10 MIN", 600, nil),
            ("1h30m", 5400, nil),
            ("1h30", 5400, nil),
            ("1h 30", 5400, nil),
            ("1.5h", 5400, nil),
            ("1 hr 15 min", 4500, nil),
            ("5:00", 300, nil),
            ("1:30:00", 5400, nil),
            ("in 10 minutes", 600, nil),
            ("tea 5m", 300, "tea"),
            ("5m tea", 300, "tea"),
            ("Tea for 10 minutes", 600, "Tea"),
            ("laundry 45", 2700, "laundry"),
            ("  standup prep   15m ", 900, "standup prep"),
            ("5m for tea", 300, "tea"),
            ("1,5h", 5400, nil),
            ("2,5", 150, nil),
            ("1h0m", 3600, nil),
            ("2m 0s", 120, nil),
            ("1h, 30m", 5400, nil),
            ("5m, tea", 300, "tea"),
            ("5 min, tea", 300, "tea"),
            ("tea, 5m", 300, "tea"),
            ("1,000s", 1000, nil),
        ] as [(String, TimeInterval, String?)]
    )
    func readsDurations(input: String, seconds: TimeInterval, name: String?) {
        #expect(TimerDurationParser.parse(input) == .init(duration: seconds, name: name))
    }

    @Test(
        "Text that isn't a duration of at least a second starts nothing",
        arguments: ["", "   ", "tea", "for", "0", "0m", "-5m", "5x", "5:60", "1:60:00", "5:00pm", ":30", "0.2s", "m5", "0x10", "1e1", "1.", "+5"]
    )
    func rejects(input: String) {
        #expect(TimerDurationParser.parse(input) == nil)
    }

    @Test("A duration over 24 hours still reads, so the tab can say it's too long")
    func tooLong() throws {
        let parsed = try #require(TimerDurationParser.parse("25h"))
        #expect(parsed.duration > TimerDurationParser.maximumDuration)
        #expect(TimerDurationParser.parse("24h")?.duration == TimerDurationParser.maximumDuration)
    }

    @Test(
        "Huge numbers are too long, never a crash",
        arguments: ["9999999999999999:0:0", "153722867280912931:00", "99999999999999999:00", "99999999999999999999999h", "1\(String(repeating: "0", count: 150))"]
    )
    func hugeNumbers(input: String) throws {
        let parsed = try #require(TimerDurationParser.parse(input))
        #expect(parsed.duration > TimerDurationParser.maximumDuration)
    }

    @Test("Long text is never read as a timer, and reading it stays fast")
    func longText() {
        let document = Array(repeating: "lorem 5m ipsum", count: 2_000).joined(separator: " ")
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TimerDurationParser.parse(document) }
        #expect(TimerDurationParser.parse(document) == nil)
        #expect(elapsed < .milliseconds(50))

        // Under the limit, only a few words at each end are tried.
        let sentence = Array(repeating: "word", count: 20).joined(separator: " ") + " 5m"
        #expect(TimerDurationParser.parse(sentence)?.duration == 300)
    }

    @Test("Lengths and clocks read the way the tab shows them")
    func text() {
        #expect(TimerText.length(300) == "5 min")
        #expect(TimerText.length(5400) == "1 hr 30 min")
        #expect(TimerText.length(45) == "45 sec")
        #expect(TimerText.clock(245) == "4:05")
        #expect(TimerText.clock(4634) == "1:17:14")
        #expect(TimerText.clock(0.2) == "0:01", "Never 0:00 while still running")
        #expect(TimerItem(id: UUID(), name: nil, duration: 300, state: .paused(remaining: 1)).title == "5 min timer")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(TimerText.when(now.addingTimeInterval(-60), now: now, calendar: calendar).hasPrefix("at "))
        #expect(TimerText.when(now.addingTimeInterval(-86_400), now: now, calendar: calendar).hasPrefix("yesterday at "))
        #expect(TimerText.when(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar).hasPrefix("on "))
        #expect(TimerText.spokenLength(245).contains("4 minutes"))
    }
}

// MARK: - The store

@MainActor
@Suite("Timer: the store")
struct TimerStoreTests {
    @Test("A running timer finishes at its end, reported once, and the next end is scheduled")
    func finishesAtEnd() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        let tea = store.start(duration: 300, name: "tea")
        let laundry = store.start(duration: 2700, name: "laundry")
        #expect(fixture.scheduler.pendingDates == [fixture.clock.now.addingTimeInterval(300)])

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        #expect(fixture.finishes.map(\.item.id) == [tea.id])
        #expect(fixture.finishes.first?.lateness == 0)
        #expect(store.items.first { $0.id == tea.id }?.isFinished == true)
        #expect(fixture.scheduler.pendingDates == [fixture.clock.now.addingTimeInterval(2400)])

        store.checkDue()
        #expect(fixture.finishes.count == 1, "Reported once")
        #expect(store.items.first { $0.id == laundry.id }?.isRunning == true)
    }

    @Test("Waking the Mac finishes timers that ended while it slept")
    func wake() {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        store.start(duration: 60, name: nil)

        fixture.clock.advance(600)
        fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(fixture.finishes.map(\.lateness) == [540])
    }

    @Test("Pause keeps the time left, and resume counts down from it")
    func pauseAndResume() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        let item = store.start(duration: 300, name: nil)

        fixture.clock.advance(100)
        store.togglePause(item.id)
        #expect(store.items[0].state == .paused(remaining: 200))
        #expect(fixture.scheduler.pendingDates.isEmpty, "Nothing to wake for")

        fixture.clock.advance(1000)
        store.togglePause(item.id)
        #expect(store.items[0].state == .running(endsAt: fixture.clock.now.addingTimeInterval(200)))
        #expect(store.items[0].remaining(at: fixture.clock.now) == 200)
    }

    @Test("Restart runs a finished timer again for its full length, and remove deletes it")
    func restartAndRemove() {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        let item = store.start(duration: 60, name: "eggs")
        fixture.clock.advance(60)
        store.checkDue()

        store.restart(item.id)
        #expect(store.items[0].state == .running(endsAt: fixture.clock.now.addingTimeInterval(60)))
        store.remove(item.id)
        #expect(store.items.isEmpty)
        #expect(fixture.scheduler.pendingDates.isEmpty)
    }

    @Test("The tab lists finished timers, then running ones by end, then paused ones")
    func displayOrder() {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        let paused = store.start(duration: 900, name: "paused")
        store.togglePause(paused.id)
        store.start(duration: 2700, name: "later")
        store.start(duration: 600, name: "sooner")
        store.start(duration: 60, name: "done")
        fixture.clock.advance(60)
        store.checkDue()

        #expect(store.displayed.map(\.name) == ["done", "sooner", "later", "paused"])
    }

    @Test("Timers survive a relaunch, and one that ended meanwhile is reported late")
    func relaunch() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let first = fixture.makeStore()
        first.activate()
        first.start(duration: 300, name: "tea")
        first.start(duration: 3600, name: "laundry")

        fixture.clock.advance(900)
        let relaunched = fixture.makeStore()
        #expect(relaunched.items.count == 2)
        #expect(fixture.finishes.isEmpty, "Nothing is reported until Timer runs")

        relaunched.activate()
        #expect(fixture.finishes.map(\.item.name) == ["tea"])
        #expect(fixture.finishes.map(\.lateness) == [600])
        #expect(fixture.scheduler.pendingDates.last == fixture.clock.now.addingTimeInterval(2700), "The relaunched store wakes for laundry")
    }

    @Test("Seeing the finished timers marks them seen, once")
    func seen() {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        store.start(duration: 60, name: nil)
        fixture.clock.advance(60)
        store.checkDue()

        #expect(store.hasUnseenFinish)
        #expect(store.markFinishesSeen())
        #expect(!store.hasUnseenFinish)
        #expect(!store.markFinishesSeen())
    }

    @Test("Turning Timer off cancels every timer and stops checking")
    func deactivate() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.activate()
        store.start(duration: 60, name: "tea")
        store.deactivate()

        #expect(store.items.isEmpty)
        #expect(fixture.scheduler.pendingDates.isEmpty)
        #expect(fixture.makeStore().items.isEmpty, "Nothing is left to come back after a relaunch")
        fixture.clock.advance(120)
        fixture.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(fixture.finishes.isEmpty)
    }

    @Test("A damaged timers file can't crash the app: impossible timers are dropped")
    func damagedFile() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let good = fixture.makeStore()
        good.start(duration: 300, name: "tea")
        var json = try String(contentsOf: fixture.storageURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"duration\":300", with: "\"duration\":1e300")
        try json.write(to: fixture.storageURL, atomically: true, encoding: .utf8)
        #expect(fixture.makeStore().items.isEmpty)
    }

    @Test("The timers file is readable only by you, and an unreadable one starts empty")
    func storage() throws {
        let fixture = StoreFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.start(duration: 60, name: "tea")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storageURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        try Data("not json".utf8).write(to: fixture.storageURL)
        #expect(fixture.makeStore().items.isEmpty)
    }
}

// MARK: - The module and its tab

@MainActor
@Suite("Timer: ends, the tab, and the menu bar dot")
struct TimerModuleTests {
    @Test("A timer that ends on time raises an alarm that rings, and marks the menu bar")
    func onTimeFinish() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")
        let end = fixture.clock.now.addingTimeInterval(300)

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        let alarm = try #require(fixture.alerts.raised.last)
        #expect(alarm == TimerAlarm(
            title: "Tea finished",
            detail: "5 min · ended \(TimerText.when(end, now: fixture.clock.now))",
            rings: true,
            canRepeat: true
        ))
        #expect(fixture.attention.accessibilityLabel(productName: "Keybumps") == "Keybumps, timer finished")
    }

    @Test("Without a name, the alarm names the length; with sound off, it doesn't ring")
    func unnamedAndSilent() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.timerPlaysSound = false
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: nil)

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        #expect(fixture.alerts.raised.map(\.title) == ["5 min timer finished"])
        #expect(fixture.alerts.raised.last?.rings == false)
    }

    @Test("A timer that ended over a minute ago, while the Mac slept, raises its alarm quietly")
    func lateFinish() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")

        fixture.clock.advance(300 + TimerModule.onTimeGrace + 1)
        fixture.store.checkDue()
        #expect(fixture.alerts.raised.map(\.title) == ["Tea finished"])
        #expect(fixture.alerts.raised.last?.rings == false)
        #expect(fixture.attention.showsDot)
    }

    @Test("Within a minute late, as after an update's relaunch, it rings as usual")
    func withinGrace() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")

        fixture.clock.advance(300 + TimerModule.onTimeGrace)
        fixture.store.checkDue()
        #expect(fixture.alerts.raised.last?.rings == true)
    }

    @Test("Timers ending together, or while the alarm is up, share one alarm, which keeps ringing")
    func together() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: "a")
        fixture.store.start(duration: 60, name: "b")
        fixture.store.start(duration: 600, name: "c")

        fixture.clock.advance(60)
        fixture.scheduler.fire()
        #expect(fixture.alerts.raised.last == TimerAlarm(title: "2 timers finished", detail: "a, b", rings: true, canRepeat: false))

        // C ends much later, unstopped: one alarm, still ringing.
        fixture.preferences.timerPlaysSound = false
        fixture.clock.advance(540)
        fixture.scheduler.fire()
        #expect(fixture.alerts.raised.last == TimerAlarm(title: "3 timers finished", detail: "a, b, c", rings: true, canRepeat: false))
    }

    @Test("Stop closes the alarm, counts its timers as seen, and clears the dot")
    func stop() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: "Tea")
        fixture.clock.advance(60)
        fixture.scheduler.fire()

        let onStopButton = try #require(fixture.alerts.onStop)
        onStopButton()
        #expect(fixture.alerts.stops == 1)
        #expect(!fixture.attention.showsDot)
        #expect(!fixture.store.hasUnseenFinish)

        // A later finish raises a new alarm of its own.
        fixture.store.start(duration: 30, name: "Eggs")
        fixture.clock.advance(30)
        fixture.scheduler.fire()
        #expect(fixture.alerts.raised.last?.title == "Eggs finished")
    }

    @Test("A timer restarted or deleted from the open Timers tab leaves the alarm, which stops once none are left")
    func alarmFollowsTheTab() throws {
        let fixture = ModuleFixture(timersTabIsShowing: true)
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let content = try #require(fixture.module.paletteContent)
        fixture.store.start(duration: 60, name: "Tea")
        fixture.store.start(duration: 60, name: "Eggs")
        fixture.clock.advance(60)
        fixture.scheduler.fire()
        #expect(fixture.alerts.raised.last?.title == "2 timers finished")

        // Return on Tea restarts it: the alarm is Eggs's alone.
        let tea = try #require(fixture.store.displayed.firstIndex { $0.name == "Tea" })
        content.activate(row: tea, query: "", withCommand: false, palette: fixture.actions)
        #expect(fixture.alerts.raised.last?.title == "Eggs finished")
        #expect(fixture.alerts.stops == 0)

        // Delete on Eggs: nothing left, so it stops.
        let eggs = try #require(fixture.store.displayed.firstIndex { $0.name == "Eggs" })
        #expect(content.delete(row: eggs, query: ""))
        #expect(fixture.alerts.stops == 1)
    }

    @Test("Repeat runs the timer again and stops the alarm")
    func repeatTimer() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let tea = fixture.store.start(duration: 300, name: "Tea")
        fixture.clock.advance(300)
        fixture.scheduler.fire()

        let onRepeatButton = try #require(fixture.alerts.onRepeat)
        onRepeatButton()
        #expect(fixture.alerts.stops == 1)
        #expect(fixture.store.items.first { $0.id == tea.id }?.state == .running(endsAt: fixture.clock.now.addingTimeInterval(300)))
        #expect(!fixture.attention.showsDot)
    }

    @Test("Showing the Timers tab marks finished timers seen and clears the dot")
    func showingTheTabClearsTheDot() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: nil)
        fixture.clock.advance(60)
        fixture.scheduler.fire()
        #expect(fixture.attention.showsDot)

        let content = try #require(fixture.module.paletteContent)
        content.didShow(palette: fixture.actions)
        #expect(!fixture.attention.showsDot)
        #expect(!fixture.store.hasUnseenFinish)
        #expect(fixture.alerts.stops == 1, "Opening the Timers tab stops the alarm")
    }

    @Test("Turning Timer off cancels the timers and clears the dot")
    func turningOff() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        let context = fixture.context(enabled: [.timer])
        fixture.module.apply(context)
        fixture.store.start(duration: 60, name: nil)
        fixture.clock.advance(60)
        fixture.scheduler.fire()
        fixture.store.start(duration: 600, name: "still running")

        fixture.module.deactivate(context)
        fixture.module.apply(fixture.context(enabled: []))
        #expect(fixture.store.items.isEmpty)
        #expect(!fixture.attention.showsDot)
        #expect(!fixture.store.isActive)
    }

    @Test("Typing a duration offers to start it; Return starts it, closes the palette, and confirms")
    func startFromTheTab() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let content = try #require(fixture.module.paletteContent)

        #expect(content.rowCount(query: "") == 0)
        #expect(content.rowCount(query: "tea 5m") == 1)
        #expect(content.footerActions(row: 0, query: "tea 5m").primary == "Start")
        #expect(content.footerActions(row: 0, query: "tea").primary == nil, "Not a duration")
        #expect(content.footerActions(row: 0, query: "30h").primary == nil, "Too long")

        content.activate(row: 0, query: "tea 5m", withCommand: false, palette: fixture.actions)
        #expect(fixture.dismissals == 1)
        #expect(fixture.notices.shown == ["tea started"])
        #expect(fixture.store.items.map(\.name) == ["tea"])
        #expect(fixture.store.items.first?.duration == 300)

        content.activate(row: 0, query: "tea", withCommand: false, palette: fixture.actions)
        #expect(fixture.store.items.count == 1, "Unreadable text starts nothing")
    }

    @Test("Return pauses, resumes, and restarts; Delete removes; the footer says which")
    func timerRows() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let content = try #require(fixture.module.paletteContent)
        fixture.store.start(duration: 300, name: "tea")

        #expect(content.footerActions(row: 0, query: "").primary == "Pause")
        content.activate(row: 0, query: "", withCommand: false, palette: fixture.actions)
        #expect(content.footerActions(row: 0, query: "").primary == "Resume")
        content.activate(row: 0, query: "", withCommand: false, palette: fixture.actions)
        #expect(content.footerActions(row: 0, query: "").primary == "Pause")

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        #expect(content.footerActions(row: 0, query: "").primary == "Restart")
        content.activate(row: 0, query: "", withCommand: false, palette: fixture.actions)
        #expect(fixture.store.items.first?.isRunning == true)

        #expect(content.footerActions(row: 1, query: "5m").primary == "Pause", "Timers follow the new-timer row")
        #expect(content.delete(row: 0, query: "5m") == false, "The new-timer row isn't deletable")
        #expect(content.delete(row: 1, query: "5m"))
        #expect(fixture.store.items.isEmpty)
    }

    @Test("While Timer is off, its tab has no rows")
    func offTab() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: false)
        let content = try #require(fixture.module.paletteContent)
        #expect(content.rowCount(query: "5m") == 0)
    }

    @Test("Return moves the highlight with the timer it acted on, even into another section")
    func selectionFollowsTheTimer() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let content = try #require(fixture.module.paletteContent)
        fixture.store.start(duration: 300, name: "tea")
        fixture.store.start(duration: 600, name: "pasta")

        // Tea is first while running; paused, it moves below Pasta.
        content.activate(row: 0, query: "", withCommand: false, palette: fixture.actions)
        #expect(fixture.selectedRows.last == 1)
        #expect(fixture.store.displayed.map(\.name) == ["pasta", "tea"])

        // Return again resumes Tea, not Pasta.
        content.activate(row: 1, query: "", withCommand: false, palette: fixture.actions)
        let allRunning = fixture.store.items.allSatisfy(\.isRunning)
        #expect(allRunning)
        #expect(fixture.selectedRows.last == 0)
    }

    @Test("A timer finishing while the tab is open keeps the highlight on the timer it was on")
    func selectionSurvivesAFinish() throws {
        let fixture = ModuleFixture(timersTabIsShowing: true)
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let content = try #require(fixture.module.paletteContent)
        let old = fixture.store.start(duration: 30, name: "old")
        fixture.clock.advance(30)
        fixture.scheduler.fire()
        fixture.store.start(duration: 60, name: "eggs")
        fixture.store.start(duration: 600, name: "pasta")
        #expect(fixture.store.displayed.map(\.name) == ["old", "eggs", "pasta"])
        // The highlight is on the old finished timer when Eggs finishes above it.
        _ = content.makeView(PaletteContentContext(query: "", selection: 0, actions: fixture.actions, confirmationPresentationChanged: { _ in }))

        fixture.clock.advance(60)
        fixture.scheduler.fire()
        #expect(fixture.store.displayed.map(\.name) == ["eggs", "old", "pasta"])
        #expect(fixture.selectedRows.last == 1, "Still on the old timer")
        #expect(!fixture.attention.showsDot, "Seen in the open tab")
        _ = old
    }

    @Test("After a relaunch with several unseen finishes, VoiceOver says timers, plural")
    func pluralRelaunchDot() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: "a")
        fixture.store.start(duration: 90, name: "b")
        fixture.clock.advance(90)
        fixture.store.checkDue()

        let relaunched = ModuleFixture(sharing: fixture)
        defer { relaunched.tearDown() }
        relaunched.module.apply(relaunched.context(enabled: [.timer]))
        #expect(relaunched.attention.accessibilityLabel(productName: "Keybumps") == "Keybumps, timers finished")
    }

    @Test("A finish not yet seen before a relaunch keeps its dot and its alarm, quietly")
    func dotAfterRelaunch() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: nil)
        fixture.clock.advance(60)
        fixture.scheduler.fire()

        let relaunched = ModuleFixture(sharing: fixture)
        defer { relaunched.tearDown() }
        relaunched.module.apply(relaunched.context(enabled: [.timer]))
        #expect(relaunched.attention.showsDot)
        #expect(relaunched.alerts.raised.map(\.title) == ["1 min timer finished"])
        #expect(relaunched.alerts.raised.last?.rings == false, "It already rang before the relaunch")
    }

    @Test("Turning Timer off stops the alarm")
    func turningOffStopsTheAlarm() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        let context = fixture.context(enabled: [.timer])
        fixture.module.apply(context)
        fixture.store.start(duration: 60, name: nil)
        fixture.clock.advance(60)
        fixture.scheduler.fire()
        fixture.module.deactivate(context)
        #expect(fixture.alerts.stops == 1)
    }

    @Test("Before Timer runs (onboarding, Locked), the tab offers nothing to start")
    func inactiveTab() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.setCapability(.timer, enabled: true)
        let content = try #require(fixture.module.paletteContent)
        #expect(content.rowCount(query: "5m") == 0)
        fixture.module.apply(fixture.context(enabled: [.timer]))
        #expect(content.rowCount(query: "5m") == 1)
    }

    @Test("Timer registers its tab, Settings page, and Quick Search keywords")
    func descriptor() {
        let descriptor = CapabilityDescriptor.timer
        #expect(descriptor.paletteTab?.tab == .timers)
        #expect(descriptor.paletteTab?.commandKey == 6)
        #expect(descriptor.settingsPage?.section == .timer)
        #expect(descriptor.requiredPermissions.isEmpty)
        #expect(descriptor.searchKeywords == ["timers", "countdown"])
        #expect(CapabilityShortcut.timer.capability == .timer)
        #expect(CapabilityShortcut.timer.defaultBinding == nil, "Open Timers starts unassigned")
        #expect(!Capability.originalCapabilities.contains(.timer), "Turned on once for existing installs")
    }
}

// MARK: - The menu bar

@MainActor
@Suite("Timer: the menu bar")
struct TimerMenuBarTests {
    @Test("The soonest running timer shows beside the icon, with how many more run, and ticks each second")
    func countdown() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        #expect(fixture.menuBarStatus.title == nil, "Nothing runs")

        fixture.store.start(duration: 2700, name: "Laundry")
        fixture.store.start(duration: 300, name: "Tea")
        #expect(fixture.menuBarStatus.title == "5:00 +1")
        #expect(fixture.ticker.pendingDates == [fixture.clock.now.addingTimeInterval(1.01)], "Next second, just after it turns")
        #expect(fixture.menuBarStatus.spokenTitle == "Tea, \(TimerText.spokenLength(300)) left, and 1 more timer")

        fixture.clock.advance(1.01)
        fixture.ticker.fire()
        #expect(fixture.menuBarStatus.title == "4:59 +1")
    }

    @Test("Nothing ticks while no timer runs")
    func noTicksWhenIdle() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        let tea = fixture.store.start(duration: 300, name: "Tea")
        #expect(!fixture.ticker.pendingDates.isEmpty)

        fixture.store.togglePause(tea.id)
        #expect(fixture.ticker.pendingDates.isEmpty)
        #expect(fixture.menuBarStatus.title == nil, "Only running timers count down")
    }

    @Test("The Keybumps menu lists running, paused, and unseen finished timers, then Open Timers")
    func menuItems() throws {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        #expect(fixture.menuBarStatus.sections.isEmpty, "No timers, no section")

        let done = fixture.store.start(duration: 60, name: "Eggs")
        fixture.clock.advance(60)
        fixture.scheduler.fire()
        let paused = fixture.store.start(duration: 900, name: "Standup")
        fixture.store.togglePause(paused.id)
        fixture.store.start(duration: 300, name: "Tea")

        let titles = fixture.menuBarStatus.sections.first?.map(\.title)
        #expect(titles == ["Eggs — finished", "Tea — 5:00", "Standup — 15:00, paused", "Open Timers"])

        // Clicking a running timer pauses it; a finished one, or Open Timers, opens the tab.
        let items = try #require(fixture.menuBarStatus.sections.first)
        items[1].action()
        #expect(fixture.store.items.first { $0.name == "Tea" }?.isRunning == false)
        items[0].action()
        items[3].action()
        #expect(fixture.tabShows == 2)

        // Once seen, a finished timer leaves the menu.
        fixture.store.markFinishesSeen()
        #expect(fixture.menuBarStatus.sections.first?.map(\.id).contains(done.id.uuidString) == false)
    }

    @Test("Each can be turned off in Settings, and turning Timer off clears both")
    func switches() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        let context = fixture.context(enabled: [.timer])
        fixture.module.apply(context)
        fixture.store.start(duration: 300, name: "Tea")

        fixture.preferences.timerShowsMenuBarCountdown = false
        fixture.module.apply(context)
        #expect(fixture.menuBarStatus.title == nil)
        #expect(!fixture.menuBarStatus.sections.isEmpty)

        fixture.preferences.timerListsTimersInMenu = false
        fixture.module.apply(context)
        #expect(fixture.menuBarStatus.sections.isEmpty)
        #expect(fixture.ticker.pendingDates.isEmpty, "Nothing to update")

        fixture.preferences.timerShowsMenuBarCountdown = true
        fixture.preferences.timerListsTimersInMenu = true
        fixture.module.apply(context)
        #expect(fixture.menuBarStatus.title != nil)
        fixture.module.deactivate(context)
        #expect(fixture.menuBarStatus.title == nil)
        #expect(fixture.menuBarStatus.sections.isEmpty)
        #expect(fixture.ticker.pendingDates.isEmpty)
    }

    @Test("Both are on by default")
    func defaults() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        #expect(preferences.timerShowsMenuBarCountdown)
        #expect(preferences.timerListsTimersInMenu)
    }
}

// MARK: - The production alarm's ringing

@MainActor
@Suite("Timer: the alarm's ringing")
struct TimerAlarmRingingTests {
    static let ringing = TimerAlarm(title: "Tea finished", detail: "5 min · ended at 3:47 PM", rings: true, canRepeat: true)

    @Test("With the notch free, it rings at once and keeps ringing until stopped")
    func ringsUntilStopped() {
        let notch = FakeNotch()
        var rings = 0
        let alerts = SystemTimerAlerts(notch: notch, playSound: { rings += 1 }, presentsCard: false)
        defer { alerts.stop() }
        alerts.raise(Self.ringing, onStop: {}, onRepeat: {})
        #expect(rings == 1)
        #expect(alerts.isRinging)
        alerts.ringTick()
        #expect(rings == 2)

        // Another timer ending while it rings doesn't start a second ringing.
        alerts.raise(Self.ringing, onStop: {}, onRepeat: {})
        #expect(rings == 2)

        alerts.stop()
        alerts.ringTick()
        #expect(rings == 2)
        #expect(!alerts.isRinging)
    }

    @Test("During Dictation it waits, rings once Dictation lets go, and never rings while it holds the notch")
    func waitsForDictation() {
        let notch = FakeNotch()
        notch.isSuppressed = true
        var rings = 0
        let alerts = SystemTimerAlerts(notch: notch, playSound: { rings += 1 }, presentsCard: false)
        defer { alerts.stop() }
        alerts.raise(Self.ringing, onStop: {}, onRepeat: {})
        #expect(rings == 0)

        notch.release()
        #expect(rings == 1)

        // A new recording started while it rings hears nothing.
        notch.isSuppressed = true
        alerts.ringTick()
        #expect(rings == 1)
        notch.isSuppressed = false
        alerts.ringTick()
        #expect(rings == 2)
    }

    @Test("Stopped while it waits for Dictation, it never rings")
    func stopWhileWaiting() {
        let notch = FakeNotch()
        notch.isSuppressed = true
        var rings = 0
        let alerts = SystemTimerAlerts(notch: notch, playSound: { rings += 1 }, presentsCard: false)
        alerts.raise(Self.ringing, onStop: {}, onRepeat: {})
        alerts.stop()
        notch.release()
        #expect(rings == 0)
        #expect(notch.cancels == 1)
    }

    @Test("A quiet alarm doesn't ring")
    func quiet() {
        let notch = FakeNotch()
        var rings = 0
        let alerts = SystemTimerAlerts(notch: notch, playSound: { rings += 1 }, presentsCard: false)
        defer { alerts.stop() }
        alerts.raise(TimerAlarm(title: "Tea finished", detail: "", rings: false, canRepeat: true), onStop: {}, onRepeat: {})
        #expect(rings == 0)
        #expect(alerts.isRaised)
    }
}

@MainActor
private final class FakeNotch: NotchWaiting {
    var isSuppressed = false
    private(set) var cancels = 0
    private var waiting: ((TimeInterval) -> Void)?

    func whenNotchFree(from source: String, _ action: @escaping (TimeInterval) -> Void) {
        if isSuppressed { waiting = action } else { action(0) }
    }

    func cancelWaiting(from source: String) {
        cancels += 1
        waiting = nil
    }

    func release() {
        isSuppressed = false
        let action = waiting
        waiting = nil
        action?(10)
    }
}

// MARK: - Waiting for the notch

@MainActor
@Suite("Waiting for the notch")
struct NotchWaitTests {
    @Test("While another surface holds the notch, however long, the action waits, then runs once, knowing how long it waited")
    func waitsThenRuns() {
        let hud = PaletteHUD()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        hud.now = { now }
        let dictation = NSObject()
        var waited: [TimeInterval] = []
        hud.claimNotch(for: dictation)
        hud.whenNotchFree(from: "timer") { waited.append($0) }
        #expect(waited.isEmpty)

        now = now.addingTimeInterval(45 * 60)
        hud.releaseNotch(from: dictation)
        #expect(waited == [TimeInterval(45 * 60)])
        hud.claimNotch(for: dictation)
        hud.releaseNotch(from: dictation)
        #expect(waited.count == 1, "Run once")
    }

    @Test("What waits is dropped only by the source that left it")
    func cancelBySource() {
        let hud = PaletteHUD()
        let dictation = NSObject()
        var runs = 0

        hud.claimNotch(for: dictation)
        hud.whenNotchFree(from: "timer") { _ in runs += 1 }
        hud.cancelWaiting(from: "someone else")
        hud.cancelWaiting(from: "timer")
        hud.releaseNotch(from: dictation)
        #expect(runs == 0)

        hud.claimNotch(for: dictation)
        hud.whenNotchFree(from: "timer") { _ in runs += 1 }
        hud.cancelWaiting(from: "someone else")
        hud.releaseNotch(from: dictation)
        #expect(runs == 1)
    }

    @Test("With the notch free, it runs at once")
    func runsAtOnce() {
        let hud = PaletteHUD()
        var runs = 0
        hud.whenNotchFree(from: "timer") { _ in runs += 1 }
        #expect(runs == 1)
    }
}

// MARK: - Fixtures

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Holds the wake-ups a store asks for; `fire()` runs the soonest that isn't cancelled.
@MainActor
private final class ManualTimerScheduler: TimerScheduling {
    final class Entry: TimerScheduledAction {
        let date: Date
        let action: @MainActor () -> Void
        var isCancelled = false
        init(date: Date, action: @escaping @MainActor () -> Void) { self.date = date; self.action = action }
        func cancel() { isCancelled = true }
    }

    private var entries: [Entry] = []

    var pendingDates: [Date] { entries.filter { !$0.isCancelled }.map(\.date) }

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction {
        let entry = Entry(date: date, action: action)
        entries.append(entry)
        return entry
    }

    func fire() {
        guard let next = entries.filter({ !$0.isCancelled }).min(by: { $0.date < $1.date }) else { return }
        next.isCancelled = true
        next.action()
    }
}

@MainActor
private final class StoreFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsTimerTests-\(UUID().uuidString)", isDirectory: true)
    let clock = TestClock()
    let scheduler = ManualTimerScheduler()
    let notifications = NotificationCenter()
    private(set) var finishes: [TimerFinish] = []
    var storageURL: URL { folder.appendingPathComponent(TimerStore.fileName) }

    func makeStore() -> TimerStore {
        let store = TimerStore(storageURL: storageURL, now: { [clock] in clock.now }, scheduler: scheduler, notifications: notifications)
        store.onFinish = { [weak self] in self?.finishes += $0 }
        return store
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
private final class RecordingTimerAlerts: TimerAlerting {
    private(set) var raised: [TimerAlarm] = []
    private(set) var stops = 0
    /// The showing alarm's buttons.
    private(set) var onStop: (() -> Void)?
    private(set) var onRepeat: (() -> Void)?

    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {
        raised.append(alarm)
        self.onStop = onStop
        self.onRepeat = onRepeat
    }

    func stop() {
        stops += 1
        onStop = nil
        onRepeat = nil
    }
}

@MainActor
private final class RecordingTimerNotices: PaletteNoticePresenting {
    private(set) var shown: [String] = []
    func showNotice(_ message: String, isWarning: Bool) { shown.append(message) }
}

private final class NoTimerHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

/// Timer's module over a store with a manual clock, a palette in temporary folders, and recorded
/// alerts, notices, and menu bar dot.
@MainActor
private final class ModuleFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTimer-\(UUID().uuidString)"))
    let clock: TestClock
    let scheduler = ManualTimerScheduler()
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let alerts = RecordingTimerAlerts()
    let notices = RecordingTimerNotices()
    let attention = MenuBarAttention()
    let menuBarStatus = MenuBarStatus()
    /// The module's once-a-second menu bar wake-ups.
    let ticker = ManualTimerScheduler()
    private final class Counter { var count = 0 }
    private let tabShowCounter = Counter()
    var tabShows: Int { tabShowCounter.count }
    let store: TimerStore
    let palette: CommandPaletteController
    let module: TimerModule
    private(set) var dismissals = 0
    private(set) var selectedRows: [Int] = []
    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: { [weak self] in self?.dismissals += 1 },
            selectRow: { [weak self] in self?.selectedRows.append($0) },
            clearQuery: {}
        )
    }

    /// A second fixture over the same timers file and clock, as after a relaunch.
    convenience init(sharing other: ModuleFixture) {
        self.init(timersURL: other.timersURL, clock: other.clock)
    }

    let timersURL: URL

    init(timersURL: URL? = nil, clock: TestClock? = nil, timersTabIsShowing: Bool = false) {
        let root = folder.url
        let clock = clock ?? TestClock()
        self.clock = clock
        let timersURL = timersURL ?? root.appendingPathComponent(TimerStore.fileName)
        self.timersURL = timersURL
        store = TimerStore(
            storageURL: timersURL,
            now: { [clock] in clock.now },
            scheduler: scheduler,
            notifications: NotificationCenter()
        )
        let dictationHistory = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
        palette = CommandPaletteController(
            clipboard: ClipboardHistoryService(
                storageURL: root.appendingPathComponent("clipboard-history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
                sourceApps: .inert
            ),
            dictationHistory: dictationHistory,
            dictationService: DictationService(language: "en-US", history: dictationHistory, paster: InertTextPaster(), allowsSystemAccess: false),
            preferences: preferences,
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: notices,
            search: QuickSearchModel.forTests(in: root)
        )
        module = TimerModule(
            palette: palette,
            store: store,
            preferences: preferences,
            attention: CapabilityMenuBarAttention(attention: attention, capability: .timer),
            menuBar: CapabilityMenuBarStatus(status: menuBarStatus, capability: .timer),
            alerts: alerts,
            notices: notices,
            timersTabIsShowing: { timersTabIsShowing },
            showTimersTab: { [tabShowCounter] in tabShowCounter.count += 1 },
            ticker: ticker
        )
    }

    func context(enabled: Set<Capability>) -> CapabilityContext {
        CapabilityContext(
            enabledCapabilities: enabled,
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: NoTimerHotKeys()),
            permissions: PermissionCoordinator(
                accessibilityTrusted: { true },
                inputMonitoringAuthorized: { true },
                microphoneAuthorizationStatus: { .authorized },
                speechAuthorizationStatus: { .authorized },
                screenRecordingAuthorized: { true },
                requestScreenRecording: {},
                openSettings: { _ in }
            ),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        )
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}
