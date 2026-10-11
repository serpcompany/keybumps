#if DEBUG
import CoreGraphics
import Foundation

/// Screencast's recorder in UI test mode: the made-up screens of `UITestScreencastScreen`, and
/// streams that start and stop but never deliver a frame or a sound, so a recording reaches
/// `.recording` and the control bar shows, while nothing is captured or heard.
@MainActor
final class UITestScreencastCaptureSystem: ScreencastCaptureSystem {
    private let screen = UITestScreencastScreen()

    func content() async throws -> ScreencastContent {
        try await screen.content()
    }

    func makeVideoStream(
        plan: ScreencastFilterPlan,
        configuration: ScreencastStreamConfiguration,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream {
        UITestScreencastStream()
    }

    func makeAudioStream(audio: ScreencastAudio, content: ScreencastContent, handler: ScreencastSampleHandler) throws -> any ScreencastStream {
        UITestScreencastStream()
    }

    func windowFrame(_ id: CGWindowID) -> CGRect? { nil }

    func ownVisibleWindows() -> Set<CGWindowID> { [] }
}

@MainActor
private final class UITestScreencastStream: ScreencastStream {
    func start() async throws {}
    func stop() async {}
    func update(plan: ScreencastFilterPlan, content: ScreencastContent) async throws {}
    func update(sourceRect: CGRect) async throws {}
}

extension AppModel {
    /// `-KBUITestScreencastRecording`: records the first made-up screen, as Start Screencast and
    /// Record would.
    func startScreencastRecordingForUITesting() {
        guard isLicensed else { return }
        (capabilities.module(for: .screencast) as? ScreencastModule)?.recordForUITesting()
    }
}

extension ScreencastModule {
    /// Opens the picker, chooses the first screen, and records it: with the countdown set to none,
    /// the control bar shows at once.
    func recordForUITesting() {
        start()
        guard #available(macOS 15, *), let controller, let picker = controller.picker,
              let screen = picker.layout.screens.first else { return }
        picker.kind = .video
        picker.target = .screen
        picker.clickScreen(screen)
        controller.confirm()
    }
}
#endif
