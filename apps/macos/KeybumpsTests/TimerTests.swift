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
        ] as [(String, TimeInterval, String?)]
    )
    func readsDurations(input: String, seconds: TimeInterval, name: String?) {
        #expect(TimerDurationParser.parse(input) == .init(duration: seconds, name: name))
    }

    @Test(
        "Text that isn't a duration of at least a second starts nothing",
        arguments: ["", "   ", "tea", "for", "0", "0m", "-5m", "5x", "5:60", "1:60:00", "5:00pm", ":30", "0.2s", "m5"]
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

    @Test("Lengths and clocks read the way the tab shows them")
    func text() {
        #expect(TimerText.length(300) == "5 min")
        #expect(TimerText.length(5400) == "1 hr 30 min")
        #expect(TimerText.length(45) == "45 sec")
        #expect(TimerText.clock(245) == "4:05")
        #expect(TimerText.clock(4634) == "1:17:14")
        #expect(TimerText.clock(0.2) == "0:01", "Never 0:00 while still running")
        #expect(TimerItem(id: UUID(), name: nil, duration: 300, state: .paused(remaining: 1)).title == "5 min timer")
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
    @Test("A timer that ends on time shows its notice, plays the sound, and marks the menu bar")
    func onTimeFinish() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        #expect(fixture.alerts.notices == [.init(message: "Tea finished", quiet: false)])
        #expect(fixture.alerts.sounds == 1)
        #expect(fixture.attention.accessibilityLabel(productName: "Keybumps") == "Keybumps, timer finished")
    }

    @Test("Without a name, the notice names the length; with sound off, it's silent")
    func unnamedAndSilent() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.preferences.timerPlaysSound = false
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: nil)

        fixture.clock.advance(300)
        fixture.scheduler.fire()
        #expect(fixture.alerts.notices.map(\.message) == ["5 min timer finished"])
        #expect(fixture.alerts.sounds == 0)
    }

    @Test("A timer that ended over a minute ago gets a quiet notice saying when, and no sound")
    func lateFinish() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")
        let end = fixture.clock.now.addingTimeInterval(300)

        fixture.clock.advance(300 + TimerModule.onTimeGrace + 1)
        fixture.store.checkDue()
        #expect(fixture.alerts.notices == [.init(message: "Tea ended at \(TimerText.time(end))", quiet: true)])
        #expect(fixture.alerts.sounds == 0)
        #expect(fixture.attention.showsDot)
    }

    @Test("Within a minute late, as after an update's relaunch, it finishes as usual")
    func withinGrace() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 300, name: "Tea")

        fixture.clock.advance(300 + TimerModule.onTimeGrace)
        fixture.store.checkDue()
        #expect(fixture.alerts.notices == [.init(message: "Tea finished", quiet: false)])
        #expect(fixture.alerts.sounds == 1)
    }

    @Test("Timers ending together share one notice")
    func together() {
        let fixture = ModuleFixture()
        defer { fixture.tearDown() }
        fixture.module.apply(fixture.context(enabled: [.timer]))
        fixture.store.start(duration: 60, name: "a")
        fixture.store.start(duration: 60, name: "b")

        fixture.clock.advance(60)
        fixture.scheduler.fire()
        #expect(fixture.alerts.notices.map(\.message) == ["2 timers finished"])
        #expect(fixture.alerts.sounds == 1)
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
    struct Notice: Equatable {
        let message: String
        let quiet: Bool
    }

    private(set) var notices: [Notice] = []
    private(set) var sounds = 0

    func showNotice(_ message: String, quiet: Bool) { notices.append(Notice(message: message, quiet: quiet)) }
    func playSound() { sounds += 1 }
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
    let clock = TestClock()
    let scheduler = ManualTimerScheduler()
    let preferences = AppPreferences(defaults: InMemoryDefaults())
    let alerts = RecordingTimerAlerts()
    let notices = RecordingTimerNotices()
    let attention = MenuBarAttention()
    let store: TimerStore
    let palette: CommandPaletteController
    let module: TimerModule
    private(set) var dismissals = 0
    var actions: PaletteContentActions {
        PaletteContentActions(dismiss: { [weak self] in self?.dismissals += 1 }, selectRow: { _ in }, clearQuery: {})
    }

    init() {
        let root = folder.url
        store = TimerStore(
            storageURL: root.appendingPathComponent(TimerStore.fileName),
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
            alerts: alerts,
            notices: notices
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
