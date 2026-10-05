import AppKit
import SwiftUI

/// What the alarm card says when timers end.
struct TimerAlarm: Equatable {
    /// "Tea finished", or "2 timers finished".
    let title: String
    /// "5 min · ended at 3:47 PM", or the timers' names.
    let detail: String
    /// Rings until stopped: a timer just ended and sound is on. A timer that ended while the Mac
    /// slept or Keybumps wasn't running shows its card quietly.
    let rings: Bool
    /// Repeat restarts the timer; offered only for one.
    let canRepeat: Bool
}

/// How a timer's end reaches you: a card that stays on screen, ringing, until it's stopped. Unit
/// tests and the UI-test composition record instead.
@MainActor
protocol TimerAlerting: AnyObject {
    /// Shows `alarm`'s card until `stop()`, replacing one already showing, and starts ringing when
    /// `alarm.rings`. Ringing waits while Dictation holds the notch, so it never reaches the
    /// microphone, and once started it goes on until `stop()`. `onStop` and `onRepeat` run when
    /// their buttons are clicked.
    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void)
    /// Closes the card and stops the ringing.
    func stop()
}

/// The production alarm: a floating card at the top of the screen, and the system Glass sound
/// every few seconds, so there's no audio file to ship.
@MainActor
final class SystemTimerAlerts: TimerAlerting {
    static let notchSource = "timer"
    /// Time between rings.
    static let ringInterval: TimeInterval = 2.5

    private var panel: NSPanel?
    private var ringing: DispatchSourceTimer?
    private let sound = NSSound(named: NSSound.Name("Glass"))

    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {
        show(alarm, onStop: onStop, onRepeat: onRepeat)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "\(alarm.title). \(alarm.detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        guard alarm.rings, ringing == nil else { return }
        PaletteHUD.shared.whenNotchFree(from: Self.notchSource) { [weak self] _ in self?.startRinging() }
    }

    func stop() {
        PaletteHUD.shared.cancelWaiting(from: Self.notchSource)
        ringing?.cancel()
        ringing = nil
        sound?.stop()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func startRinging() {
        // The card may have been stopped while Dictation held the notch.
        guard ringing == nil, panel?.isVisible == true else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.ringInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sound?.stop()
                self?.sound?.play()
            }
        }
        timer.resume()
        ringing = timer
    }

    private func show(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: TimerAlarmCard(alarm: alarm, stop: onStop, repeatTimer: onRepeat))
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            // Centered just below the menu bar, where the notch notices are.
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
    }

    /// A card that floats above other apps, also full-screen ones and on every Space, and takes
    /// clicks without taking the keyboard from the app you're typing in.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.identifier = NSUserInterfaceItemIdentifier("timerAlarm")
        return panel
    }
}

final class InertTimerAlerts: TimerAlerting {
    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {}
    func stop() {}
}

/// The alarm card: the timer icon, what ended and when, and Repeat and Stop.
private struct TimerAlarmCard: View {
    let alarm: TimerAlarm
    let stop: () -> Void
    let repeatTimer: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: alarm.rings ? "bell.and.waves.left.and.right.fill" : "timer")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating, isActive: alarm.rings)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(alarm.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
            if alarm.canRepeat {
                Button("Repeat", action: repeatTimer)
                    .buttonStyle(PalettePillButtonStyle())
                    .accessibilityIdentifier("timerAlarm.repeat")
            }
            Button(action: stop) {
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timerAlarm.stop")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(PaletteTheme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(16)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer alarm")
    }
}
