import Foundation

/// What the control bar shows of a recording and asks of it. `ScreencastController` is the one in
/// the app, so the bar acts through the capture flow, never the recorder directly, and the phase,
/// the area's highlight, and the finished capture stay right. Tests drive the bar with a fake.
@MainActor
protocol ScreencastBarRecording: AnyObject {
    /// Where the capture is: the bar acts only while it's recording or paused.
    var phase: ScreencastPhase { get }
    /// Recorded seconds, paused time excluded.
    var elapsed: TimeInterval { get }
    var microphone: ScreencastAudioSourceState { get }
    var systemAudio: ScreencastAudioSourceState { get }
    /// How loud the microphone is, 0…1: 0 while it's off, paused, or not recorded.
    var microphoneLevel: Float { get }

    func pause()
    func resume()
    /// Switches a sound the recording has off or back on; does nothing for one it doesn't have.
    func setAudio(_ source: ScreencastAudioSource, on: Bool)
    /// Throws away what's recorded and starts again at once.
    func restart() async
    /// Keeps the recording, for the review panel.
    func stop() async
    /// Deletes everything recorded.
    func discard() async
}

extension ScreencastBarRecording {
    func state(of source: ScreencastAudioSource) -> ScreencastAudioSourceState {
        switch source {
        case .microphone: microphone
        case .systemAudio: systemAudio
        }
    }
}

/// The controller acts; its recorder says how long, which sounds, and how loud. While the
/// recording starts, before the recorder has its sounds, they're as the picker chose them.
@available(macOS 15, *)
extension ScreencastController: ScreencastBarRecording {
    var elapsed: TimeInterval { recorder.elapsed }
    var microphone: ScreencastAudioSourceState { sound(.microphone) }
    var systemAudio: ScreencastAudioSourceState { sound(.systemAudio) }
    var microphoneLevel: Float { recorder.microphoneLevel }

    private func sound(_ source: ScreencastAudioSource) -> ScreencastAudioSourceState {
        guard phase == .starting else {
            return source == .microphone ? recorder.microphone : recorder.systemAudio
        }
        return choice?.audio.contains(source) == true ? .on : .notRecorded
    }
}
