import AppKit

/// What Screencast's review panel (#450) takes from the rest of the app. Each is read for each
/// capture, so a plugin turned on or off since the last one counts.
struct ScreencastReviewServices {
    /// Clipboard History: Copy marks its write so Clipboard History skips it, and "Also add to
    /// Screenshots (⌘3)" adds a screenshot there while it's on.
    var clipboard: ClipboardHistoryService
    var isClipboardHistoryOn: @MainActor () -> Bool
    /// Screenshot Tools' editor, while Screenshot Tools is on.
    var editor: @MainActor () -> (any ScreencastScreenshotEditing)?
    /// Where the panel remembers its switch.
    var settings: ScreencastReviewSettings
    /// Where "Copied to Clipboard" shows; nil shows nothing, as under the unit-test host.
    var notices: (any PaletteNoticePresenting)?
    /// Where corrected repositories are remembered: Application Support, through `ProductPaths`.
    var repositories: @MainActor () -> ScreencastRepositoryMemory = { .makeDefault() }

    /// The app's: its Clipboard History, Screenshot Tools' editor, and preferences.
    @MainActor
    static func app(
        clipboard: ClipboardHistoryService,
        screenshotTools: ScreenshotToolsModule,
        preferences: AppPreferences
    ) -> ScreencastReviewServices {
        ScreencastReviewServices(
            clipboard: clipboard,
            isClipboardHistoryOn: { [preferences] in preferences.enabledCapabilities.contains(.clipboardHistory) },
            editor: { [weak screenshotTools, preferences] in
                preferences.enabledCapabilities.contains(.screenshotTools) ? screenshotTools?.editor : nil
            },
            settings: preferences.screencastReviewSettings,
            notices: UnitTestHost.isActive ? nil : PaletteHUD.shared
        )
    }
}

/// The review panel hung on the flow controller: the context is read as a capture starts, and
/// each saved capture opens the panel with it. A composition without services (a module test's)
/// leaves captures in their folder and shows nothing.
@MainActor
final class ScreencastReviewFlow {
    private let services: ScreencastReviewServices?
    private let contextReader: ScreencastCaptureContextReader
    private var contextRead: Task<ScreencastCaptureContext, Never>?
    /// Made for the first capture.
    private(set) var panel: ScreencastReviewPanel?
    /// Called when the panel is done with a capture, after its own notice.
    var onFinish: ((ScreencastReviewOutcome) -> Void)?

    init(services: ScreencastReviewServices?, contextReader: ScreencastCaptureContextReader) {
        self.services = services
        self.contextReader = contextReader
    }

    /// Start Screencast, from idle: reads the app in front, and a browser's site, before the picker
    /// covers the screen.
    func captureStarting() {
        let reader = contextReader
        contextRead = Task { await reader.read() }
    }

    /// The flow controller saved a capture: the panel opens on it with the context read at the start.
    func captureFinished(_ result: ScreencastCaptureResult) {
        let read = contextRead
        contextRead = nil
        Task { [weak self] in
            let context = await read?.value ?? .none
            await self?.show(ScreencastReviewInput(result), context: context)
        }
    }

    func show(_ input: ScreencastReviewInput, context: ScreencastCaptureContext) async {
        await panelForReview()?.show(input, context: context)
    }

    /// Screencast turned off: the capture under review is saved, and the panel closes.
    func close() {
        guard let panel, panel.isShown else { return }
        Task { await panel.close() }
    }

    private func panelForReview() -> ScreencastReviewPanel? {
        if let panel { return panel }
        guard let services else { return nil }
        let clipboard = services.clipboard
        let panel = ScreencastReviewPanel(
            repositories: services.repositories(),
            keepOutOfClipboardHistory: { [weak clipboard] in clipboard?.suppressCurrentChange() },
            editor: services.editor,
            screenshots: { [weak clipboard] in services.isClipboardHistoryOn() ? clipboard : nil },
            settings: services.settings
        )
        panel.onFinish = { [weak self] outcome in
            // As the palette confirms its copies.
            if case .copied = outcome { services.notices?.showNotice("Copied to Clipboard", isWarning: false) }
            self?.onFinish?(outcome)
        }
        self.panel = panel
        return panel
    }
}
