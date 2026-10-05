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

/// How a timer's end reaches you. Unit tests and the UI-test composition record instead.
@MainActor
protocol TimerAlerting {
    /// A notch notice that waits while Dictation holds the notch, rather than being dropped. A quiet
    /// one is for a timer that ended a while ago.
    func showNotice(_ message: String, quiet: Bool)
    func playSound()
}

/// The production alerts: `PaletteHUD`'s notch notice and a system sound, so there's no audio
/// file to ship.
struct SystemTimerAlerts: TimerAlerting {
    func showNotice(_ message: String, quiet: Bool) {
        PaletteHUD.shared.showWhenNotchFree(message, systemImage: "timer", tint: quiet ? .gray : .orange, duration: 4)
    }

    func playSound() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

struct InertTimerAlerts: TimerAlerting {
    func showNotice(_ message: String, quiet: Bool) {}
    func playSound() {}
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

    init(
        palette: CommandPaletteController,
        store: TimerStore,
        preferences: AppPreferences,
        attention: CapabilityMenuBarAttention,
        alerts: any TimerAlerting,
        notices: any PaletteNoticePresenting = PaletteHUD.shared
    ) {
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
            store.activate()
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
    }

    private func timersShown() {
        store.markFinishesSeen()
        attention.clear()
    }

    private func timersFinished(_ finishes: [TimerFinish]) {
        guard let first = finishes.first else { return }
        let onTime = finishes.contains { $0.lateness <= Self.onTimeGrace }
        let message: String
        if finishes.count > 1 {
            message = onTime ? "\(finishes.count) timers finished" : "\(finishes.count) timers ended"
        } else if onTime {
            message = "\(first.item.title) finished"
        } else {
            message = "\(first.item.title) ended at \(TimerText.time(Self.endDate(of: first.item)))"
        }
        alerts.showNotice(message, quiet: !onTime)
        if onTime, preferences.timerPlaysSound { alerts.playSound() }
        if palette.isDisplaying(.timers) {
            store.markFinishesSeen()
        } else {
            attention.show(saying: finishes.count > 1 ? "timers finished" : "timer finished")
        }
    }

    private static func endDate(of item: TimerItem) -> Date {
        if case .finished(let at, _) = item.state { return at }
        return .now
    }
}
