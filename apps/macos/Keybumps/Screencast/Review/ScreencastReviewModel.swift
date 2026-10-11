import AppKit
import Observation
import os

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
/// is left out, and a recording whose trim fails is kept untrimmed. Quitting saves at once
/// (`saveNow`), without a trim.
///
/// The context read when the capture started may still be on its way: the panel shows at once, and
/// the guess fills the repository field when it comes, unless the person has typed there.
@MainActor
@Observable
final class ScreencastReviewModel {
    /// The capture, updated once a trim replaces its files.
    private(set) var input: ScreencastReviewInput
    /// The app, and a browser's site, in front when the capture started; `.none` until it's read.
    private(set) var context: ScreencastCaptureContext
    /// One line, as the person types it; Save keeps it on one line.
    var note = ""
    var type: ScreencastReviewType = .bug
    /// What the repository field shows: the guess at first.
    var repositoryText: String {
        didSet { if !isFillingGuess { repositoryWasTyped = true } }
    }
    private(set) var guess: ScreencastRepositoryGuess?
    /// The display shown, for a recording of every display.
    var selectedDisplay = 0
    /// What Save keeps of a recording; nil keeps all of it.
    private(set) var trimRange: ScreencastTrimRange?
    /// The player's trim controls are up: Return and Escape are theirs, and the actions wait.
    private(set) var isTrimming = false
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
    @ObservationIgnored private let trimmer: any ScreencastTrimming
    @ObservationIgnored private let now: () -> Date
    /// A trim already applied whose durations `meta.json` doesn't have yet.
    @ObservationIgnored private var unrecordedTrim: ScreencastCapture?
    /// `close()` calls waiting for a Save or Copy to finish.
    @ObservationIgnored private var waitingForWork: [CheckedContinuation<Void, Never>] = []
    /// The context read when the capture started, until it comes.
    @ObservationIgnored private var contextRead: Task<ScreencastCaptureContext, Never>?
    @ObservationIgnored private var repositoryWasTyped = false
    @ObservationIgnored private var isFillingGuess = false
    /// The review written when the panel finished, for a trim still under way then (a quit), whose
    /// durations go in after it.
    @ObservationIgnored private var savedReview: ScreencastReview?
    @ObservationIgnored private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    /// - Parameters:
    ///   - pasteboard: Where Copy writes; tests pass a named pasteboard.
    ///   - keepOutOfClipboardHistory: Called right after Copy writes, to mark that write so Clipboard
    ///     History skips it (`ClipboardHistoryService.suppressCurrentChange`).
    ///   - contextRead: The context's read, when it's still on its way; `context` until it comes.
    init(
        input: ScreencastReviewInput,
        context: ScreencastCaptureContext = .none,
        contextRead: Task<ScreencastCaptureContext, Never>? = nil,
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .keybumps,
        keepOutOfClipboardHistory: @escaping () -> Void,
        trimmer: any ScreencastTrimming = ScreencastFileTrimmer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.context = context
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
        self.trimmer = trimmer
        self.now = now
        let guess = repositories.guess(for: context)
        self.guess = guess
        repositoryText = guess?.repository.description ?? ""
        if let contextRead {
            self.contextRead = contextRead
            Task { [weak self] in
                let context = await contextRead.value
                self?.receive(context)
            }
        }
    }

    /// The context's read came: the guess fills the repository field, unless the person typed there.
    private func receive(_ context: ScreencastCaptureContext) {
        guard contextRead != nil else { return }
        contextRead = nil
        self.context = context
        guess = repositories.guess(for: context)
        guard !repositoryWasTyped, !isFinished, let guess else { return }
        isFillingGuess = true
        repositoryText = guess.repository.description
        isFillingGuess = false
    }

    /// Waits for the context's read, if it's still on its way. It's bounded: the reader gives up
    /// within about a second.
    private func waitForContext() async {
        guard let contextRead else { return }
        receive(await contextRead.value)
    }

    // MARK: What the panel shows

    /// The actions act one at a time, and wait for the trim controls.
    var acceptsActions: Bool { !isWorking && !isFinished && !isTrimming }

    var videos: [ScreencastVideo] {
        if case .video(let capture) = input { capture.videos } else { [] }
    }

    /// The recording shown: the selected display's.
    var currentVideo: ScreencastVideo? {
        let videos = videos
        return videos.indices.contains(selectedDisplay) ? videos[selectedDisplay] : videos.first
    }

    /// How many displays the recording has a video of.
    var displayCount: Int { videos.count }

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

    // MARK: Trim

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
        await conclude(copying: false, strictly: false)
    }

    /// A capture that won't be shown (Screencast was turned off): saved once its context comes.
    func saveWhenContextComes() async {
        await waitForContext()
        saveNow()
    }

    /// Keybumps is quitting or relaunching, or the capture won't be shown: writes the review into
    /// `meta.json` at once. A trim not yet applied is skipped, which keeps the originals.
    func saveNow() {
        guard !isFinished else { return }
        isConfirmingDiscard = false
        let text = repositoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = text.isEmpty ? nil : ScreencastRepository(text)
        record(repository: repository, strictly: false)
        finish(.saved(input))
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

        await waitForContext()
        guard !isFinished else { return }
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
                if strictly, !isFinished { return fail(.trimFailed) }
                log(.trimFailed)
            }
            // Saved at once meanwhile (a quit): a cut now in place still gets its durations recorded.
            if isFinished {
                if unrecordedTrim != nil, let savedReview {
                    try? ScreencastReview.write(savedReview, trimmed: unrecordedTrim, to: input.metadataURL, fileManager: fileManager)
                    unrecordedTrim = nil
                }
                return
            }
        }

        guard record(repository: repository, strictly: strictly) else { return }
        if copying {
            guard ScreencastReviewFiles.copy(input, to: pasteboard) else { return fail(.copyFailed) }
            keepOutOfClipboardHistory()
        }
        finish(copying ? .copied(input) : .saved(input))
    }

    /// Remembers a corrected repository and writes the review into `meta.json`. False when that
    /// failed and `strictly` keeps the panel open to say so.
    @discardableResult
    private func record(repository: ScreencastRepository?, strictly: Bool) -> Bool {
        if let repository, repository != guess?.repository {
            repositories.remember(repository, for: context)
        }
        let review = ScreencastReview(
            note: Self.oneLine(note),
            type: type,
            repository: repository?.description,
            context: context,
            reviewedAt: now()
        )
        do {
            try ScreencastReview.write(review, trimmed: unrecordedTrim, to: input.metadataURL, fileManager: fileManager)
            unrecordedTrim = nil
        } catch {
            if strictly {
                fail(.metadataFailed)
                return false
            }
            log(.metadataFailed)
        }
        savedReview = review
        return true
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
