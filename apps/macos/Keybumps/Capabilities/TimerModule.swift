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

/// What a timer's end says, and whether it plays the sound. A quiet one is for timers that ended a
/// while ago.
struct TimerAnnouncement: Equatable {
    let message: String
    let quiet: Bool
    let withSound: Bool
}

/// How a timer's end reaches you. Unit tests and the UI-test composition record instead.
@MainActor
protocol TimerAlerting {
    /// A notch notice, with a sound when the announcement says so. While Dictation holds the notch
    /// both wait, however long it records, rather than the notice being dropped or the sound
    /// reaching its microphone; `announcement` gets how long they waited, so a late one says so.
    func announce(_ announcement: @escaping (_ waited: TimeInterval) -> TimerAnnouncement)
    /// Drops an announcement still waiting, as when Timer is turned off.
    func cancelWaitingAnnouncement()
}

/// The production alerts: `PaletteHUD`'s notch notice and a system sound, so there's no audio
/// file to ship.
struct SystemTimerAlerts: TimerAlerting {
    static let noticeSource = "timer"

    func announce(_ announcement: @escaping (_ waited: TimeInterval) -> TimerAnnouncement) {
        PaletteHUD.shared.showWhenNotchFree(from: Self.noticeSource) { waited in
            let announcement = announcement(waited)
            return WaitingNotice(
                message: announcement.message,
                systemImage: "timer",
                tint: announcement.quiet ? .gray : .orange,
                duration: 4,
                whenShown: announcement.withSound ? { NSSound(named: NSSound.Name("Glass"))?.play() } : nil
            )
        }
    }

    func cancelWaitingAnnouncement() {
        PaletteHUD.shared.cancelWaitingNotice(from: Self.noticeSource)
    }
}

struct InertTimerAlerts: TimerAlerting {
    func announce(_ announcement: @escaping (_ waited: TimeInterval) -> TimerAnnouncement) {}
    func cancelWaitingAnnouncement() {}
}

/// Owns the Timers tab, its optional Open Timers shortcut, and the timers' ends: a notch notice,
/// a sound unless it's off, and the menu bar dot until the Timers tab shows. It runs nothing while
/// no timer runs: `TimerStore` schedules one wake-up, for the soonest end.
@MainActor
final class TimerModule: CapabilityModule {
    /// A timer that ended at most this long ago finishes as usual, with its sound: about the gap an
    /// update's relaunch leaves. One that ended earlier gets a quiet notice saying when it ended.
    static let onTimeGrace: TimeInterval = 60

    let descriptor = CapabilityDescriptor.timer
    var paletteContent: (any CapabilityPaletteContent)? { timersTab }
    private let timersTab: TimerPaletteContent
    private let palette: CommandPaletteController
    private let store: TimerStore
    private let preferences: AppPreferences
    private let attention: CapabilityMenuBarAttention
    private let alerts: any TimerAlerting
    /// Whether the palette is showing the Timers tab; tests replace it.
    private let timersTabIsShowing: () -> Bool

    init(
        palette: CommandPaletteController,
        store: TimerStore,
        preferences: AppPreferences,
        attention: CapabilityMenuBarAttention,
        alerts: any TimerAlerting,
        notices: any PaletteNoticePresenting = PaletteHUD.shared,
        timersTabIsShowing: (() -> Bool)? = nil
    ) {
        self.timersTabIsShowing = timersTabIsShowing ?? { [weak palette] in palette?.isDisplaying(.timers) ?? false }
        self.palette = palette
        self.store = store
        self.preferences = preferences
        self.attention = attention
        self.alerts = alerts
        timersTab = TimerPaletteContent(store: store, preferences: preferences, notices: notices)
        timersTab.shown = { [weak self] in self?.timersShown() }
        store.onFinish = { [weak self] finishes in self?.timersFinished(finishes) }
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
            guard !store.isActive else { return }
            store.activate()
            // A finish not yet seen before a relaunch keeps its dot.
            if store.hasUnseenFinish, !timersTabIsShowing() { showDot() }
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
        store.deactivate()
        attention.clear()
        alerts.cancelWaitingAnnouncement()
    }

    private func timersShown() {
        store.markFinishesSeen()
        attention.clear()
    }

    private func showDot() {
        attention.show(saying: store.unseenFinishCount > 1 ? "timers finished" : "timer finished")
    }

    private func timersFinished(_ finishes: [TimerFinish]) {
        guard !finishes.isEmpty else { return }
        let now = store.now
        let playsSound = preferences.timerPlaysSound
        alerts.announce { waited in
            Self.announcement(for: finishes, waited: waited, playsSound: playsSound, now: now())
        }
        if timersTabIsShowing() {
            store.markFinishesSeen()
            // The finished timer moved to the top; keep the highlight on the timer it was on.
            timersTab.keepSelectionOnSameTimer()
        } else {
            showDot()
        }
    }

    /// What ending timers say once the notice shows, `waited` after they were noticed: a finish
    /// still within `onTimeGrace` then plays the sound; anything later is quiet and says when.
    static func announcement(for finishes: [TimerFinish], waited: TimeInterval, playsSound: Bool, now: Date) -> TimerAnnouncement {
        let onTime = finishes.contains { $0.lateness + waited <= onTimeGrace }
        let message: String
        if finishes.count > 1 {
            message = onTime ? "\(finishes.count) timers finished" : "\(finishes.count) timers ended"
        } else if onTime {
            message = "\(finishes[0].item.title) finished"
        } else {
            message = "\(finishes[0].item.title) ended \(TimerText.when(endDate(of: finishes[0].item), now: now))"
        }
        return TimerAnnouncement(message: message, quiet: !onTime, withSound: onTime && playsSound)
    }

    private static func endDate(of item: TimerItem) -> Date {
        if case .finished(let at, _) = item.state { return at }
        return .now
    }
}
