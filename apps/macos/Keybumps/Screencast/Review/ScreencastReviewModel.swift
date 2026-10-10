import AppKit
import Observation
import os

/// Opens Screenshot Tools' editor on a capture's screenshot. `ScreenshotEditorPresenter` is the one
/// in the app; tests pass a fake.
@MainActor
protocol ScreencastScreenshotEditing: AnyObject {
    /// Opens the Screenshot Editor on `image`, unless another image is being edited. `onFinish` gets
    /// the marked-up copy's location after Save, or nil after Cancel.
    func editScreenshot(at image: URL, onFinish: @escaping (URL?) -> Void) -> Bool
    /// Cancels the edit in progress, if any.
    func close()
}

/// Shows the player's own trim controls (`AVPlayerView.beginTrimming`). Tests pass a fake.
@MainActor
protocol ScreencastTrimPresenting: AnyObject {
    /// `completion` gets the part kept, in seconds, after Trim, or nil after Cancel. False when the
    /// player can't trim now.
    func beginTrimming(_ completion: @escaping (ClosedRange<TimeInterval>?) -> Void) -> Bool
}

/// The review panel's state and actions, for `ScreencastReviewView` and for tests: the note, type,
/// and repository the person gives a capture, a recording's trim, and Save, Copy, and Discard.
///
/// Every way out keeps the capture except Discard. Save, Return, and Copy write the review into
/// `meta.json` (and apply a trim) and stay open if that fails, saying why. Escape and closing the
/// panel save too, as far as they can, so nothing is lost: a repository that isn't `owner/name`
/// is left out, and a recording whose trim fails is kept untrimmed. Saving a screenshot also adds
/// it to the Screenshots tab (⌘3) while "Also add to Screenshots" is on; Copy never does, since it
/// keeps the capture out of Clipboard History.
@MainActor
@Observable
final class ScreencastReviewModel {
    /// The capture, updated once a trim replaces its files.
    private(set) var input: ScreencastReviewInput
    let context: ScreencastCaptureContext
    /// One line, as the person types it; Save keeps it on one line.
    var note = ""
    var type: ScreencastReviewType = .bug
    /// What the repository field shows: the guess at first.
    var repositoryText: String
    let guess: ScreencastRepositoryGuess?
    /// The display shown, for a capture of every display.
    var selectedDisplay = 0 {
        didSet { refreshImage() }
    }
    /// What Save keeps of a recording; nil keeps all of it.
    private(set) var trimRange: ScreencastTrimRange?
    /// The player's trim controls are up: Return and Escape are theirs, and the actions wait.
    private(set) var isTrimming = false
    /// A screenshot's marked-up copies, by display, which Copy and Send use in place of the originals.
    private(set) var editedImages: [Int: URL] = [:]
    /// The Screenshot Editor is open on the screenshot.
    private(set) var isEditing = false
    /// The screenshot shown, as it is now, marked up or not.
    private(set) var image: NSImage?
    /// "Also add to Screenshots (⌘3)": saving a screenshot adds it there. Remembered for the next
    /// capture.
    var addsToScreenshots: Bool {
        didSet { settings.addsToScreenshots = addsToScreenshots }
    }
    /// Discard asked "Discard this capture?" and waits for Discard or Keep.
    private(set) var isConfirmingDiscard = false
    /// Save or Copy is writing files.
    private(set) var isWorking = false
    private(set) var failure: ScreencastReviewFailure?
    private(set) var isFinished = false

    /// Called once, when the panel is done with the capture.
    @ObservationIgnored var onFinish: ((ScreencastReviewOutcome) -> Void)?

    @ObservationIgnored private let repositories: ScreencastRepositoryMemory
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let keepOutOfClipboardHistory: () -> Void
    @ObservationIgnored private let editor: (any ScreencastScreenshotEditing)?
    @ObservationIgnored private let trimmer: any ScreencastTrimming
    @ObservationIgnored private let screenshots: (any ScreencastScreenshotsLibrary)?
    @ObservationIgnored private let settings: ScreencastReviewSettings
    @ObservationIgnored private let now: () -> Date
    /// A trim already applied whose durations `meta.json` doesn't have yet.
    @ObservationIgnored private var unrecordedTrim: ScreencastCapture?
    /// `close()` calls waiting for a Save or Copy to finish.
    @ObservationIgnored private var waitingForWork: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    /// - Parameters:
    ///   - pasteboard: Where Copy writes; tests pass a named pasteboard.
    ///   - keepOutOfClipboardHistory: Called right after Copy writes, to mark that write so Clipboard
    ///     History skips it (`ClipboardHistoryService.suppressCurrentChange`).
    ///   - editor: The Screenshot Editor, or nil to offer no Edit.
    ///   - screenshots: Clipboard History's screenshot items, or nil while Clipboard History is off,
    ///     which hides "Also add to Screenshots".
    ///   - settings: Where that switch is remembered.
    init(
        input: ScreencastReviewInput,
        context: ScreencastCaptureContext,
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .keybumps,
        keepOutOfClipboardHistory: @escaping () -> Void,
        editor: (any ScreencastScreenshotEditing)? = nil,
        trimmer: any ScreencastTrimming = ScreencastPassthroughTrimmer(),
        screenshots: (any ScreencastScreenshotsLibrary)? = nil,
        settings: ScreencastReviewSettings,
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.context = context
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.editor = editor
        self.trimmer = trimmer
        self.screenshots = screenshots
        self.settings = settings
        addsToScreenshots = settings.addsToScreenshots
        self.now = now
        guess = repositories.guess(for: context)
        repositoryText = guess?.repository.description ?? ""
        refreshImage()
    }

    // MARK: What the panel shows

    /// The actions act one at a time, and wait for the editor and the trim controls.
    var acceptsActions: Bool { !isWorking && !isFinished && !isEditing && !isTrimming }

    var videos: [ScreencastVideo] {
        if case .video(let capture) = input { capture.videos } else { [] }
    }

    /// The recording shown: the selected display's.
    var currentVideo: ScreencastVideo? {
        let videos = videos
        return videos.indices.contains(selectedDisplay) ? videos[selectedDisplay] : videos.first
    }

    /// A screenshot's files as they are now, by display: each marked-up copy in its original's place.
    var screenshotFiles: [URL] {
        guard case .screenshot(let screenshot) = input else { return [] }
        return screenshot.images.enumerated().map { editedImages[$0.offset] ?? $0.element.file }
    }

    /// How many displays the capture has a video or an image of.
    var displayCount: Int { input.isVideo ? videos.count : screenshotFiles.count }

    /// The recording's length, after the trim, as `mm:ss`.
    var durationText: String? {
        guard case .video(let capture) = input else { return nil }
        return Self.minutesAndSeconds(trimRange?.duration ?? capture.duration)
    }

    /// `mm:ss`, minutes going on past 59, as the control bar's timer shows a recording.
    static func minutesAndSeconds(_ duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? Int(min(max(duration, 0), 1_000_000_000).rounded()) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var canEdit: Bool { editor != nil && !input.isVideo }

    /// The switch is for screenshots, and only while Clipboard History, which keeps ⌘3's items, is on.
    var showsAddToScreenshots: Bool { screenshots != nil && !input.isVideo }

    /// Sending comes with destinations (#451); until then there's none to show.
    var destinationTitle: String { "None yet" }
    var canSend: Bool { false }

    /// Under the repository field: what the guess was remembered for, or how to type one.
    var repositoryHint: String? {
        let text = repositoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let repository = ScreencastRepository(text) else { return "Type it as owner/name." }
        guard let guess, guess.repository == repository else { return nil }
        switch guess.source {
        case .website(let domain): return "Remembered for \(domain)"
        case .app: return "Remembered for \(context.appName ?? "this app")"
        }
    }

    // MARK: Trim and Edit

    /// Shows the player's trim controls; what they keep, Save cuts the files to.
    func trim(with presenter: any ScreencastTrimPresenting) {
        guard acceptsActions, let video = currentVideo else { return }
        failure = nil
        isTrimming = true
        let started = presenter.beginTrimming { [weak self] kept in
            guard let self else { return }
            isTrimming = false
            if let kept { setTrim(ScreencastTrimRange(start: kept.lowerBound, end: kept.upperBound, within: video.duration)) }
        }
        if !started { isTrimming = false }
    }

    func setTrim(_ range: ScreencastTrimRange?) {
        trimRange = range
    }

    /// Opens the Screenshot Editor on the image shown, or its marked-up copy after an earlier edit.
    func edit() {
        let files = screenshotFiles
        guard acceptsActions, files.indices.contains(selectedDisplay), let editor else { return }
        let display = selectedDisplay
        failure = nil
        isEditing = true
        let opened = editor.editScreenshot(at: files[display]) { [weak self] edited in
            guard let self else { return }
            isEditing = false
            guard let edited else { return }
            editedImages[display] = edited
            refreshImage()
        }
        if !opened {
            isEditing = false
            fail(.editorUnavailable)
        }
    }

    // MARK: Save, Copy, Discard

    /// Save, and Return: keeps the capture with its review.
    func save() async {
        await conclude(copying: false, strictly: true)
    }

    /// Saves, then puts the capture on the clipboard, kept out of Clipboard History.
    func copy() async {
        await conclude(copying: true, strictly: true)
    }

    /// Escape, or the panel closing without a choice: saves what it can, and always finishes.
    func close() async {
        // A Save or Copy under way finishes first; if it stopped at a failure, this saves anyway.
        if isWorking { await withCheckedContinuation { waitingForWork.append($0) } }
        guard !isFinished else { return }
        if isEditing { editor?.close() }
        await conclude(copying: false, strictly: false)
    }

    /// Discard asks first, in the panel: "Discard this capture?" with Discard and Keep.
    func askToDiscard() {
        guard acceptsActions else { return }
        failure = nil
        isConfirmingDiscard = true
    }

    /// Keep: back to the actions, nothing deleted.
    func keep() {
        isConfirmingDiscard = false
    }

    /// Discard, answering "Discard this capture?": deletes the capture's folder.
    func confirmDiscard() {
        guard isConfirmingDiscard else { return }
        isConfirmingDiscard = false
        guard acceptsActions else { return }
        do {
            try ScreencastReviewFiles.delete(input, fileManager: fileManager)
        } catch {
            fail(.deleteFailed)
            return
        }
        finish(.discarded)
    }

    /// Writes the review (and a trim), copies if asked, and finishes. `strictly` stops at the first
    /// thing that fails, so the person can fix it; otherwise it keeps going, saving what it can.
    private func conclude(copying: Bool, strictly: Bool) async {
        guard !isFinished, !isWorking, !strictly || acceptsActions else { return }
        isConfirmingDiscard = false
        failure = nil
        isWorking = true
        defer {
            isWorking = false
            let waiting = waitingForWork
            waitingForWork = []
            waiting.forEach { $0.resume() }
        }

        let text = repositoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = text.isEmpty ? nil : ScreencastRepository(text)
        if !text.isEmpty, repository == nil, strictly { return fail(.invalidRepository) }

        if case .video(let capture) = input, let range = trimRange {
            do {
                let trimmed = try await ScreencastReviewFiles.trim(capture, to: range, trimmer: trimmer, fileManager: fileManager)
                input = .video(trimmed)
                trimRange = nil
                unrecordedTrim = trimmed
            } catch {
                if strictly { return fail(.trimFailed) }
                log(.trimFailed)
            }
        }

        if let repository, repository != guess?.repository {
            repositories.remember(repository, for: context)
        }
        let review = ScreencastReview(
            note: Self.oneLine(note),
            type: type,
            repository: repository?.description,
            context: context,
            editedImages: editedImageNames,
            reviewedAt: now()
        )
        do {
            try ScreencastReview.write(review, trimmed: unrecordedTrim, to: input.metadataURL, fileManager: fileManager)
            unrecordedTrim = nil
        } catch {
            if strictly { return fail(.metadataFailed) }
            log(.metadataFailed)
        }

        if copying {
            guard ScreencastReviewFiles.copy(input, images: screenshotFiles, to: pasteboard) else { return fail(.copyFailed) }
            keepOutOfClipboardHistory()
        } else if showsAddToScreenshots, addsToScreenshots {
            for file in screenshotFiles { screenshots?.addScreencastScreenshot(at: file) }
        }
        finish(copying ? .copied(input) : .saved(input))
    }

    /// The marked-up copies' file names, by the original each replaces.
    private var editedImageNames: [String: String]? {
        guard case .screenshot(let screenshot) = input, !editedImages.isEmpty else { return nil }
        var names: [String: String] = [:]
        for (display, edited) in editedImages where screenshot.images.indices.contains(display) {
            names[screenshot.images[display].file.lastPathComponent] = edited.lastPathComponent
        }
        return names
    }

    private func refreshImage() {
        let files = screenshotFiles
        guard !files.isEmpty else { return }
        image = NSImage(contentsOf: files[files.indices.contains(selectedDisplay) ? selectedDisplay : 0])
    }

    /// The note on one line: line breaks and tabs become spaces, and the ends are trimmed.
    static func oneLine(_ note: String) -> String {
        note.components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func fail(_ failure: ScreencastReviewFailure) {
        self.failure = failure
        log(failure)
    }

    /// The category only: never the note, repository, context, or a file.
    private func log(_ failure: ScreencastReviewFailure) {
        logger.error("screencast review failed category=\(failure.rawValue, privacy: .public)")
    }

    private func finish(_ outcome: ScreencastReviewOutcome) {
        guard !isFinished else { return }
        isFinished = true
        onFinish?(outcome)
    }
}
