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

/// What holds the notch while Dictation records, so the alarm's sound and announcement wait for
/// it. `PaletteHUD` in the app; tests replace it.
@MainActor
protocol NotchWaiting: AnyObject {
    var isSuppressed: Bool { get }
    /// Runs whenever Dictation claims the notch.
    var onClaim: (() -> Void)? { get set }
    func whenNotchFree(from source: String, _ action: @escaping (_ waited: TimeInterval) -> Void)
    func cancelWaiting(from source: String)
}

extension PaletteHUD: NotchWaiting {}

/// The production alarm: a floating card at the top of the screen, and the system Glass sound
/// every few seconds, so there's no audio file to ship. Neither the ringing nor the VoiceOver
/// announcement plays while Dictation holds the notch, so neither reaches its microphone.
@MainActor
final class SystemTimerAlerts: TimerAlerting {
    static let notchSource = "timer"
    /// Time between rings.
    static let ringInterval: TimeInterval = 2.5
    /// What VoiceOver adds, since the card never takes keyboard focus.
    static let howToStop = "Click Stop, or open Timers, to stop it."

    private let notch: any NotchWaiting
    private let playSound: () -> Void
    private let stopSound: () -> Void
    private let presentsCard: Bool
    private var panel: NSPanel?
    private var ringing: DispatchSourceTimer?
    /// Whether an alarm is up, from `raise` until `stop()`.
    private(set) var isRaised = false
    private(set) var isRinging = false

    /// `presentsCard` false keeps tests from making a window.
    init(
        notch: (any NotchWaiting)? = nil,
        playSound: (() -> Void)? = nil,
        stopSound: (() -> Void)? = nil,
        presentsCard: Bool = true
    ) {
        self.notch = notch ?? PaletteHUD.shared
        let sound = NSSound(named: NSSound.Name("Glass"))
        self.playSound = playSound ?? {
            sound?.stop()
            sound?.play()
        }
        self.stopSound = stopSound ?? { sound?.stop() }
        self.presentsCard = presentsCard
        // A ring still sounding when Dictation starts stops at once, so its microphone never hears it.
        self.notch.onClaim = { [weak self] in self?.stopSound() }
    }

    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {
        isRaised = true
        if presentsCard { show(alarm, onStop: onStop, onRepeat: onRepeat) }
        let rings = alarm.rings
        notch.whenNotchFree(from: Self.notchSource) { [weak self] _ in
            guard let self, self.isRaised else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "\(alarm.title). \(alarm.detail). \(Self.howToStop)",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
            if rings { self.startRinging() }
        }
    }

    func stop() {
        isRaised = false
        isRinging = false
        notch.cancelWaiting(from: Self.notchSource)
        ringing?.cancel()
        ringing = nil
        stopSound()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func startRinging() {
        guard isRaised, !isRinging else { return }
        isRinging = true
        ringTick()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.ringInterval, repeating: Self.ringInterval)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.ringTick() } }
        timer.resume()
        ringing = timer
    }

    /// One ring, skipped while Dictation holds the notch: a recording started during the alarm
    /// never hears it.
    func ringTick() {
        guard isRinging, !notch.isSuppressed else { return }
        playSound()
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
        // ⌘H, Hide Others, and the Dock's Hide hide Keybumps' windows; the alarm stays.
        panel.canHide = false
        panel.identifier = NSUserInterfaceItemIdentifier("timerAlarm")
        return panel
    }
}

final class InertTimerAlerts: TimerAlerting {
    func raise(_ alarm: TimerAlarm, onStop: @escaping () -> Void, onRepeat: @escaping () -> Void) {}
    func stop() {}
}

/// The bell's motion while the alarm rings: a repeating bounce, which macOS 15 brings, or a pulse
/// on macOS 14, where a repeating bounce isn't available.
private struct RingingEffect: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.bounce, options: .repeating, isActive: isActive)
        } else {
            content.symbolEffect(.pulse, options: .repeating, isActive: isActive)
        }
    }
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
                .modifier(RingingEffect(isActive: alarm.rings))
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
        .accessibilityLabel("Timer alarm. \(SystemTimerAlerts.howToStop)")
    }
}
