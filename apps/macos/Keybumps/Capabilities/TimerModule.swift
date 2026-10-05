import AppKit
import SwiftUI

extension CapabilityDescriptor {
    static let timer = CapabilityDescriptor(
        capability: .timer,
        title: "Timer",
        systemImage: "timer",
        iconTint: .orange,
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .timers,
            name: "Timers",
            commandKey: 6,
            systemImage: "timer",
            prompt: "Start a timer: 5m, 1h30m, tea 25",
            primaryActionTitle: "Start",
            secondaryActionTitle: nil,
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .timer,
            summary: "Count down from a duration and get told when it ends.",
            disableExplanation: "Turning this off cancels running timers and releases its global shortcut.",
            content: { AnyView(TimerSettingsView()) }
        ),
        criticalOperations: [],
        searchKeywords: ["timers", "countdown"]
    )
}

/// Wakes after a delay by the Mac's own uptime, not the wall clock, so setting the clock back
/// doesn't freeze the menu bar countdown. A timer's end itself stays on the wall clock
/// (`WallClockTimerScheduler`); after sleep, the store's wake check refreshes the menu bar.
struct MonotonicTickScheduler: TimerScheduling {
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .milliseconds(50))
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume()
        return Tick(source: source)
    }

    private struct Tick: TimerScheduledAction {
        let source: DispatchSourceTimer
        func cancel() { source.cancel() }
    }
}

/// Owns the Timers tab, its optional Open Timers shortcut, and the timers' ends: an alarm card that
/// stays on screen and rings (unless sound is off), and the menu bar dot, until Stop, Repeat, or
/// the Timers tab. While a timer runs it also shows the soonest beside the menu bar icon and lists
/// the timers in the Keybumps menu (each can be turned off), updating them once a second. It runs
/// nothing while no timer runs:
/// `TimerStore` schedules one wake-up, for the soonest end.
@MainActor
final class TimerModule: CapabilityModule {
    /// A timer that ended at most this long ago rings as usual: about the gap an update's relaunch
    /// leaves. One that ended earlier, while the Mac slept or Keybumps wasn't running, shows its
    /// alarm quietly.
    static let onTimeGrace: TimeInterval = 60

    let descriptor = CapabilityDescriptor.timer
    var paletteContent: (any CapabilityPaletteContent)? { timersTab }
    private let timersTab: TimerPaletteContent
    private let palette: CommandPaletteController
    private let store: TimerStore
    private let preferences: AppPreferences
    private let attention: CapabilityMenuBarAttention
    private let alerts: any TimerAlerting
    private let menuBar: CapabilityMenuBarStatus
    /// Whether the palette is showing the Timers tab; tests replace it.
    private let timersTabIsShowing: () -> Bool
    /// Opens the palette on the Timers tab; tests replace it.
    private let showTimersTab: () -> Void
    /// Wakes the module once a second while a timer runs, to update the menu bar.
    private let ticker: any TimerScheduling
    private var nextTick: (any TimerScheduledAction)?
    /// The finished timers the alarm is showing, oldest first, until it's acknowledged.
    private var alarmed: [UUID] = []
    /// Whether one of them just ended, so the alarm rings.
    private var alarmRings = false

    init(
        palette: CommandPaletteController,
        store: TimerStore,
        preferences: AppPreferences,
        attention: CapabilityMenuBarAttention,
        menuBar: CapabilityMenuBarStatus,
        alerts: any TimerAlerting,
        notices: any PaletteNoticePresenting = PaletteHUD.shared,
        timersTabIsShowing: (() -> Bool)? = nil,
        showTimersTab: (() -> Void)? = nil,
        ticker: (any TimerScheduling)? = nil
    ) {
        self.timersTabIsShowing = timersTabIsShowing ?? { [weak palette] in palette?.isDisplaying(.timers) ?? false }
        self.showTimersTab = showTimersTab ?? { [weak palette] in palette?.show(.timers) }
        self.ticker = ticker ?? MonotonicTickScheduler()
        self.menuBar = menuBar
        self.palette = palette
        self.store = store
        self.preferences = preferences
        self.attention = attention
        self.alerts = alerts
        timersTab = TimerPaletteContent(store: store, preferences: preferences, notices: notices)
        timersTab.shown = { [weak self] in self?.timersShown() }
        store.onFinish = { [weak self] finishes in self?.timersFinished(finishes) }
        store.onChange = { [weak self] in
            self?.pruneAlarm()
            self?.refreshMenuBar()
        }
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.timer.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .timer)
        ) { [weak palette] in
            palette?.toggle(.timers)
        }
        if context.isEnabled(capability) {
            defer { refreshMenuBar() }
            guard !store.isActive else { return }
            store.activate()
            // A finish not yet seen before a relaunch keeps its dot and its alarm, quietly.
            let unseen = store.displayed.filter { if case .finished(_, false) = $0.state { true } else { false } }
            if !unseen.isEmpty, !timersTabIsShowing() {
                showDot()
                raiseAlarm(adding: unseen.reversed().map(\.id), rings: false)
            }
        } else if store.isActive {
            // Locked: nothing runs, so the timers stop too.
            stop()
        }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .timers)
        stop()
    }

    private func stop() {
        alarmed = []
        alarmRings = false
        alerts.stop()
        store.deactivate()
        attention.clear()
        nextTick?.cancel()
        nextTick = nil
        menuBar.clear()
    }

    // MARK: Menu bar

    /// Shows the soonest running timer beside the menu bar icon and lists the timers in the
    /// Keybumps menu, each unless turned off, and wakes again when the soonest shows a new second.
    private func refreshMenuBar() {
        nextTick?.cancel()
        nextTick = nil
        guard store.isActive else {
            menuBar.clear()
            return
        }
        let now = store.now()
        let countdown = preferences.timerShowsMenuBarCountdown ? Self.countdown(of: store.displayed, now: now) : nil
        menuBar.set(
            title: countdown?.title,
            spoken: countdown?.spoken,
            items: preferences.timerListsTimersInMenu ? menuItems(now: now) : []
        )

        let showsTime = preferences.timerShowsMenuBarCountdown || preferences.timerListsTimersInMenu
        guard showsTime, let soonest = store.displayed.first(where: \.isRunning) else { return }
        // The clock rounds up, so the shown second changes as the time left crosses a whole second.
        let remaining = soonest.remaining(at: now)
        let untilNextSecond = remaining - remaining.rounded(.down)
        let wait = untilNextSecond > 0 ? untilNextSecond : 1
        nextTick = ticker.schedule(at: now.addingTimeInterval(wait + 0.01)) { [weak self] in self?.refreshMenuBar() }
    }

    /// What the menu bar shows beside the icon: the soonest running timer's time left, and how many
    /// more run (`3:12 +2`). Nil while none runs.
    static func countdown(of timers: [TimerItem], now: Date) -> (title: String, spoken: String)? {
        let running = timers.filter(\.isRunning)
        guard let soonest = running.first else { return nil }
        let others = running.count - 1
        let remaining = soonest.remaining(at: now)
        let title = TimerText.clock(remaining) + (others > 0 ? " +\(others)" : "")
        var spoken = "\(soonest.title), \(TimerText.spokenLength(remaining)) left"
        if others > 0 { spoken += ", and \(others) more \(others == 1 ? "timer" : "timers")" }
        return (title, spoken)
    }

    /// The Keybumps menu's Timers section: running and paused timers, finished ones not yet seen,
    /// and Open Timers. Clicking a timer pauses or resumes it; a finished one opens the Timers tab.
    private func menuItems(now: Date) -> [MenuBarItem] {
        let timers = store.displayed.filter { item in
            if case .finished(_, let seen) = item.state { return !seen }
            return true
        }
        guard !timers.isEmpty else { return [] }
        let store = store
        let showTimersTab = showTimersTab
        let rows = timers.map { item in
            switch item.state {
            case .running:
                MenuBarItem(id: item.id.uuidString, title: "\(item.title) — \(TimerText.clock(item.remaining(at: now)))",
                            systemImage: "timer", action: { store.togglePause(item.id) })
            case .paused(let remaining):
                MenuBarItem(id: item.id.uuidString, title: "\(item.title) — \(TimerText.clock(remaining)), paused",
                            systemImage: "pause.circle", action: { store.togglePause(item.id) })
            case .finished:
                MenuBarItem(id: item.id.uuidString, title: "\(item.title) — finished",
                            systemImage: "checkmark.circle", action: showTimersTab)
            }
        }
        return rows + [MenuBarItem(id: "openTimers", title: "Open Timers", systemImage: "list.bullet", action: showTimersTab)]
    }

    private func timersShown() {
        acknowledge()
    }

    private func showDot() {
        attention.show(saying: store.unseenFinishCount > 1 ? "timers finished" : "timer finished")
    }

    private func timersFinished(_ finishes: [TimerFinish]) {
        guard !finishes.isEmpty else { return }
        if timersTabIsShowing() {
            store.markFinishesSeen()
            // The finished timer moved to the top; keep the highlight on the timer it was on.
            timersTab.keepSelectionOnSameTimer()
        } else {
            showDot()
        }
        let onTime = finishes.contains { $0.lateness <= Self.onTimeGrace }
        raiseAlarm(adding: finishes.map(\.item.id), rings: onTime && preferences.timerPlaysSound)
    }

    /// Shows the alarm for every timer it holds, adding `ids`; it rings once any of them rang.
    private func raiseAlarm(adding ids: [UUID], rings: Bool) {
        alarmed += ids.filter { !alarmed.contains($0) }
        alarmRings = alarmRings || rings
        let timers = alarmed.compactMap { id in store.items.first { $0.id == id } }
        guard let alarm = Self.alarm(for: timers, rings: alarmRings, now: store.now()) else { return }
        alerts.raise(alarm, onStop: { [weak self] in self?.acknowledge() }, onRepeat: { [weak self] in self?.repeatAlarmed() })
    }

    /// Stop, the Timers tab, or the Keybumps menu's finished timer: the alarm stops ringing and
    /// closes, and its timers count as seen.
    private func acknowledge() {
        alarmed = []
        alarmRings = false
        alerts.stop()
        store.markFinishesSeen()
        attention.clear()
    }

    /// Keeps the alarm to timers that are still finished: one restarted or deleted from the Timers
    /// tab leaves it, and the alarm stops once none are left.
    private func pruneAlarm() {
        guard !alarmed.isEmpty else { return }
        let finished = alarmed.filter { id in store.items.first { $0.id == id }?.isFinished == true }
        guard finished != alarmed else { return }
        alarmed = finished
        if alarmed.isEmpty {
            alarmRings = false
            alerts.stop()
        } else {
            raiseAlarm(adding: [], rings: false)
        }
    }

    private func repeatAlarmed() {
        let ids = alarmed
        acknowledge()
        for id in ids { store.restart(id) }
    }

    /// The alarm card for finished timers: one names its length and when it ended; several list
    /// their names. Nil without any.
    static func alarm(for timers: [TimerItem], rings: Bool, now: Date) -> TimerAlarm? {
        guard let first = timers.first else { return nil }
        if timers.count > 1 {
            return TimerAlarm(
                title: "\(timers.count) timers finished",
                detail: timers.map(\.title).joined(separator: ", "),
                rings: rings,
                canRepeat: false
            )
        }
        return TimerAlarm(
            title: "\(first.title) finished",
            detail: "\(TimerText.length(first.duration)) · ended \(TimerText.when(endDate(of: first), now: now))",
            rings: rings,
            canRepeat: true
        )
    }

    private static func endDate(of item: TimerItem) -> Date {
        if case .finished(let at, _) = item.state { return at }
        return .now
    }
}
