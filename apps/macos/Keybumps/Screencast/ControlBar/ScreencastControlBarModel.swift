import Foundation
import Observation

/// What the bar asks before it throws a take away, in place of its controls.
enum ScreencastBarQuestion: Equatable {
    case discard
    case restart

    /// "Discard?" or "Restart?"
    var prompt: String { self == .discard ? "Discard?" : "Restart?" }
    /// The button that answers yes.
    var confirmTitle: String { self == .discard ? "Discard" : "Restart" }
    var confirmHelp: String { self == .discard ? "Delete this recording" : "Start over: what’s recorded so far is thrown away" }
    /// What VoiceOver calls the question.
    var accessibilityLabel: String { self == .discard ? "Discard this recording?" : "Restart this recording?" }
}

/// One sound's button on the bar.
struct ScreencastBarAudioButton: Equatable {
    let systemImage: String
    /// What VoiceOver calls it.
    let label: String
    /// What VoiceOver says it's set to.
    let value: String
    /// Its tooltip.
    let help: String
    /// Only a sound the recording has, and that still works, can be switched.
    let isEnabled: Bool
    /// Shown in orange: the sound stopped working.
    let isWarning: Bool
}

/// The control bar's state and actions, for `ScreencastControlBarView`, the menu bar, the recording
/// shortcuts, and tests. It reads the recording live, so the bar follows it however it changed:
/// from the bar, the menu bar, a shortcut, or a sound that stopped working. The capture flow ends
/// the recording, so a Stop or Discard reaches the review panel or closes the bar through it.
@MainActor
@Observable
final class ScreencastControlBarModel {
    /// How long "Discard?" or "Restart?" waits for an answer before going back to the controls.
    nonisolated static let confirmationTimeout: Duration = .seconds(5)
    /// Where the microphone's level rests while recording, so the bar shows it's listening.
    static let meterFloor = 0.04

    let recording: any ScreencastBarRecording
    /// Drawing's switch (#449). The Draw button shows only while this is set.
    var onToggleDrawing: (() -> Void)?
    /// Whether drawing is on, kept up to date by whoever supplies `onToggleDrawing`.
    var isDrawing = false
    /// Discard or Restart asked first, and waits for its answer or Keep. The recording goes on
    /// meanwhile.
    private(set) var question: ScreencastBarQuestion?
    /// A Restart, Stop, or Discard is under way, so the buttons wait for it.
    private(set) var isWorking = false

    @ObservationIgnored private let confirmationTimeout: Duration
    @ObservationIgnored private var confirmationTimeoutTask: Task<Void, Never>?

    /// - Parameter confirmationTimeout: How long a question waits; tests shorten it.
    init(
        recording: any ScreencastBarRecording,
        confirmationTimeout: Duration = ScreencastControlBarModel.confirmationTimeout
    ) {
        self.recording = recording
        self.confirmationTimeout = confirmationTimeout
    }

    // MARK: What the bar shows

    var isPaused: Bool { recording.phase == .paused }

    /// The buttons act only while recording or paused, and one at a time.
    var acceptsActions: Bool { recording.phase.isRecording && !isWorking }

    var timerText: String { Self.timerText(recording.elapsed) }

    /// Minutes and seconds, `mm:ss`. Minutes go on past 59 rather than adding hours.
    static func timerText(_ elapsed: TimeInterval) -> String {
        let seconds = elapsed.isFinite ? Int(min(max(elapsed, 0), 1_000_000_000)) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The timer as VoiceOver reads it: "1 minute, 5 seconds", and "paused" while paused.
    var timerAccessibilityValue: String {
        let elapsed = recording.elapsed.isFinite ? max(0, recording.elapsed.rounded(.down)) : 0
        let time = Self.durationFormatter.string(from: elapsed) ?? timerText
        return isPaused ? "\(time), paused" : time
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    /// What VoiceOver says for the menu bar's time.
    var spokenTime: String { "Screencast recording, \(timerAccessibilityValue)" }

    var pauseTitle: String { isPaused ? "Resume" : "Pause" }
    var pauseSystemImage: String { isPaused ? "play.fill" : "pause.fill" }
    var pauseHelp: String { isPaused ? "Resume recording" : "Pause recording" }

    var showsDrawButton: Bool { onToggleDrawing != nil }
    var drawSystemImage: String { isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle" }
    var drawHelp: String { isDrawing ? "Stop drawing" : "Draw on the screen" }

    func audioButton(for source: ScreencastAudioSource) -> ScreencastBarAudioButton {
        Self.audioButton(for: source, state: recording.state(of: source))
    }

    /// A sound that was off when recording started is shown off and can't be switched on, since
    /// the recording has no track for it; one that stopped working can't be switched either.
    static func audioButton(for source: ScreencastAudioSource, state: ScreencastAudioSourceState) -> ScreencastBarAudioButton {
        let sound = AudioWords(source)
        switch state {
        case .on:
            return ScreencastBarAudioButton(
                systemImage: sound.onImage, label: sound.label, value: "On",
                help: "Mute \(sound.name)\(sound.inRecording)", isEnabled: true, isWarning: false
            )
        case .off:
            return ScreencastBarAudioButton(
                systemImage: sound.offImage, label: sound.label, value: "Off",
                help: "Unmute \(sound.name)\(sound.inRecording)", isEnabled: true, isWarning: false
            )
        case .notRecorded:
            return ScreencastBarAudioButton(
                systemImage: sound.absentImage, label: sound.label, value: "Not recorded",
                help: "\(sound.sentenceName) isn’t in this recording. Turn it on before you start recording.",
                isEnabled: false, isWarning: false
            )
        case .failed:
            return ScreencastBarAudioButton(
                systemImage: sound.absentImage, label: sound.label, value: "Stopped working",
                help: "\(sound.sentenceName) stopped working. The recording goes on without it.",
                isEnabled: false, isWarning: true
            )
        }
    }

    /// How the bar names and draws each sound.
    private struct AudioWords {
        let label: String
        let name: String
        let onImage: String
        let offImage: String
        let absentImage: String
        /// Muting the Mac's sound mutes it only in the recording, which its tooltip says.
        let inRecording: String

        /// The name starting a sentence.
        var sentenceName: String { name.prefix(1).uppercased() + name.dropFirst() }

        init(_ source: ScreencastAudioSource) {
            switch source {
            case .microphone:
                label = "Microphone"
                name = "the microphone"
                (onImage, offImage, absentImage) = ("mic.fill", "mic.slash.fill", "mic.slash")
                inRecording = ""
            case .systemAudio:
                label = "Mac’s sound"
                name = "the Mac’s sound"
                (onImage, offImage, absentImage) = ("speaker.wave.2.fill", "speaker.slash.fill", "speaker.slash")
                inRecording = " in the recording"
            }
        }
    }

    /// The microphone's level behind the bar, 0…1, or nil when there's none to show.
    var microphoneMeter: Double? {
        Self.meterLevel(microphone: recording.microphone, phase: recording.phase, level: recording.microphoneLevel)
    }

    /// Only a microphone that's on has a level behind the bar: the recorder's, kept within 0…1 and
    /// resting at `meterFloor` while recording, and flat while paused.
    static func meterLevel(microphone: ScreencastAudioSourceState, phase: ScreencastPhase, level: Float) -> Double? {
        guard microphone == .on else { return nil }
        guard phase == .recording else { return 0 }
        guard level.isFinite else { return meterFloor }
        return min(max(Double(level), meterFloor), 1)
    }

    // MARK: Actions

    func togglePause() {
        guard acceptsActions else { return }
        if isPaused { recording.resume() } else { recording.pause() }
    }

    func toggleDrawing() {
        guard acceptsActions else { return }
        onToggleDrawing?()
    }

    /// Mutes or unmutes a sound the recording has; does nothing for one it doesn't.
    func toggleAudio(_ source: ScreencastAudioSource) {
        guard acceptsActions else { return }
        switch recording.state(of: source) {
        case .on: recording.setAudio(source, on: false)
        case .off: recording.setAudio(source, on: true)
        case .notRecorded, .failed: break
        }
    }

    /// Stops and keeps the recording.
    func stop() async {
        guard acceptsActions else { return }
        keep()
        await work { await recording.stop() }
    }

    /// Restart asks first: "Restart?" with Restart and Keep. One click shouldn't throw a take away.
    func askToRestart() {
        ask(.restart)
    }

    /// Discard asks first, in the bar rather than in an alert, so the recorded app keeps its focus:
    /// "Discard?" with Discard and Keep in place of the controls. After Shotnix's
    /// `RecordingHUDWindow` (MIT, see LICENSE.shotnix).
    func askToDiscard() {
        ask(.discard)
    }

    /// The Discard shortcut: asks, and discards when pressed again while it asks.
    func discardFromShortcut() async {
        if question == .discard {
            await confirm()
        } else {
            askToDiscard()
        }
    }

    /// Keep: back to the controls, the recording untouched.
    func keep() {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        question = nil
    }

    /// Answers the question yes: Discard deletes everything recorded, and Restart starts over at
    /// once, with the sounds as they are now.
    func confirm() async {
        guard let question else { return }
        keep()
        guard acceptsActions else { return }
        switch question {
        case .discard: await work { await recording.discard() }
        case .restart: await work { await recording.restart() }
        }
    }

    /// Asks `question` in place of the controls, and goes back to them as Keep after a few seconds
    /// without an answer. A question already asked gives way to the new one.
    private func ask(_ question: ScreencastBarQuestion) {
        guard acceptsActions, self.question != question else { return }
        keep()
        self.question = question
        let timeout = confirmationTimeout
        confirmationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.keep()
        }
    }

    /// Runs one of the actions that take a moment, while the buttons wait.
    private func work(_ action: () async -> Void) async {
        isWorking = true
        defer { isWorking = false }
        await action()
    }
}
