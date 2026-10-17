import AppKit

/// What Screencast's review panel (#450) takes from the rest of the app. Each is read for each
/// capture, so a plugin turned on or off since the last one counts.
struct ScreencastReviewServices {
    /// Clipboard History: Copy marks its write so Clipboard History skips it.
    var clipboard: ClipboardHistoryService
    /// Where Copy writes: the app's `.keybumps`, or a test's named pasteboard. There's no default,
    /// so a test never reaches the real clipboard by leaving it out.
    var pasteboard: NSPasteboard
    /// The notch, where "Recording saved to captures" and "Recording copied" show; nil shows
    /// nothing, as under the unit-test host.
    var notices: (any PaletteNoticePresenting)?
    /// Where corrected repositories are remembered: Application Support, through `ProductPaths`.
    var repositories: @MainActor () -> ScreencastRepositoryMemory = { .makeDefault() }
    /// Who has the front, which the review window takes and gives back: macOS's, or a test's
    /// stand-in.
    var front: ScreencastReviewFront = .app

    /// The app's: its Clipboard History.
    @MainActor
    static func app(clipboard: ClipboardHistoryService) -> ScreencastReviewServices {
        ScreencastReviewServices(
            clipboard: clipboard,
            pasteboard: .keybumps,
            notices: UnitTestHost.isActive ? nil : PaletteHUD.shared
        )
    }
}

/// The review panel hung on the flow controller: the context is read as a capture starts, and
/// each saved capture opens the panel at once, the guess following when the read comes. Turning
/// Screencast off saves the capture under review, and any still waiting, without showing them.
/// Quitting or relaunching saves the one under review at once. A composition without services (a
/// module test's) leaves captures in their folder and shows nothing.
@MainActor
final class ScreencastReviewFlow {
    private let services: ScreencastReviewServices?
    private let contextReader: ScreencastCaptureContextReader
    private var contextRead: Task<ScreencastCaptureContext, Never>?
    /// Made for the first capture.
    private(set) var panel: ScreencastReviewPanel?
    /// Called when the panel is done with a capture, after its own notice.
    var onFinish: ((ScreencastReviewOutcome) -> Void)?
    private var isOn = true
    private var terminationObserver: NSObjectProtocol?

    init(services: ScreencastReviewServices?, contextReader: ScreencastCaptureContextReader) {
        self.services = services
        self.contextReader = contextReader
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Record Screen, from idle: the review window still up goes, and its capture is saved,
    /// before the picker covers the screen; then the app in front, and a browser's site, are read.
    func captureStarting() {
        isOn = true
        panel?.startAccepting()
        panel?.makeWayForNextCapture()
        let reader = contextReader
        contextRead = Task { await reader.read() }
    }

    /// The controller's phase: once the picker and the countdown are done, recording or cancelled,
    /// the app the review window took the front from gets it back.
    func capturePhaseChanged(_ phase: ScreencastPhase) {
        switch phase {
        case .recording, .idle: panel?.captureUnderWay()
        default: break
        }
    }

    /// The flow controller saved a capture: the panel opens on it at once, with the context read at
    /// the start to follow.
    func captureFinished(_ result: ScreencastCaptureResult) {
        let read = contextRead
        contextRead = nil
        guard let panel = panelForReview() else { return }
        Task { await panel.show(ScreencastReviewInput(result), contextRead: read) }
    }

    func show(_ input: ScreencastReviewInput, context: ScreencastCaptureContext) async {
        await panelForReview()?.show(input, context: context)
    }

    /// Screencast turned off: the capture under review is saved and the panel closes; captures still
    /// waiting, including one whose context is still being read, are saved without showing.
    func close() {
        isOn = false
        panel?.shutDown()
    }

    /// Keybumps is quitting or relaunching: the review under way is written at once.
    func saveNow() {
        panel?.saveNow()
    }

    private func panelForReview() -> ScreencastReviewPanel? {
        if let panel { return panel }
        guard let services else { return nil }
        let clipboard = services.clipboard
        let panel = ScreencastReviewPanel(
            repositories: services.repositories(),
            pasteboard: services.pasteboard,
            keepOutOfClipboardHistory: { [weak clipboard] in clipboard?.suppressCurrentChange() },
            front: services.front
        )
        panel.onFinish = { [weak self, weak panel] outcome in
            // The next capture closed it: only a failure needs saying.
            if let notice = Self.notice(for: outcome), notice.isWarning || panel?.isMakingWay != true {
                services.notices?.showNotice(notice.message, isWarning: notice.isWarning)
            }
            self?.onFinish?(outcome)
        }
        if !isOn { panel.shutDown() }
        self.panel = panel
        return panel
    }

    /// What the notch says as a review ends. The window closes on Save, Return, Escape, or Copy, so
    /// the notice is what says where the recording was kept, or, as a warning, why it couldn't be.
    /// Discard says nothing.
    ///
    /// Where is the folder the capture's own folder is in, the captures folder (owner QA of
    /// 4030.475.4): "Recording saved to captures", by the name Finder shows (`folderName`).
    static func notice(
        for outcome: ScreencastReviewOutcome,
        folderName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> (message: String, isWarning: Bool)? {
        switch outcome {
        case .saved(let input): ("Recording saved to \(folderName(input.folder.deletingLastPathComponent()))", false)
        case .copied: ("Recording copied", false)
        case .saveFailed(_, let failure): (failure.message, true)
        case .discarded: nil
        }
    }
}
