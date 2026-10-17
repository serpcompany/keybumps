import AppKit
import Observation
import os

/// The review's state and actions, for `ScreencastRecordingReviewView` and for tests: Save, Copy,
/// and Discard, and the review they write. The window has no fields (#475), so a review keeps the
/// type and the guessed repository as they start, for a later Send (#451).
///
/// Every way out keeps the capture except Discard. Save, Return, Copy, and ⌘C write the review into
/// `meta.json` and stay open if that fails, saying why. Escape and closing the window save too, as
/// far as they can, so nothing is lost: a repository that isn't `owner/name` is left out, and a
/// review that can't be written ends as `saveFailed`, never `saved`. Quitting saves at once
/// (`saveNow`).
///
/// The context read when the capture started may still be on its way: the window shows at once, and
/// the guess fills the repository when it comes.
@MainActor
@Observable
final class ScreencastReviewModel {
    let input: ScreencastReviewInput
    /// The app, and a browser's site, in front when the capture started; `.none` until it's read.
    private(set) var context: ScreencastCaptureContext
    /// One line, as the person types it; Save keeps it on one line.
    var note = ""
    var type: ScreencastReviewType = .bug
    /// The repository the review keeps: the guess at first.
    var repositoryText: String {
        didSet { if !isFillingGuess { repositoryWasTyped = true } }
    }
    private(set) var guess: ScreencastRepositoryGuess?
    /// The display shown, for a recording of every display.
    var selectedDisplay = 0
    /// Discard asked "Discard this recording?" and waits for Discard or Keep.
    private(set) var isConfirmingDiscard = false
    /// Save or Copy is writing files.
    private(set) var isWorking = false
    private(set) var failure: ScreencastReviewFailure?
    private(set) var isFinished = false

    /// Called once, when the review is done with the capture.
    @ObservationIgnored var onFinish: ((ScreencastReviewOutcome) -> Void)?

    @ObservationIgnored private let repositories: ScreencastRepositoryMemory
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let keepOutOfClipboardHistory: () -> Void
    @ObservationIgnored private let now: () -> Date
    /// `close()` calls waiting for a Save or Copy to finish.
    @ObservationIgnored private var waitingForWork: [CheckedContinuation<Void, Never>] = []
    /// The context read when the capture started, until it comes.
    @ObservationIgnored private var contextRead: Task<ScreencastCaptureContext, Never>?
    @ObservationIgnored private var repositoryWasTyped = false
    @ObservationIgnored private var isFillingGuess = false
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
        pasteboard: NSPasteboard,
        keepOutOfClipboardHistory: @escaping () -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.context = context
        self.repositories = repositories
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.keepOutOfClipboardHistory = keepOutOfClipboardHistory
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

    // MARK: What the window shows

    /// The actions act one at a time.
    var acceptsActions: Bool { !isWorking && !isFinished }

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

    // MARK: Save, Copy, Discard

    /// Save, and Return: keeps the capture with its review.
    func save() async {
        await conclude(copying: false, strictly: true)
    }

    /// Saves, then puts the capture on the clipboard, kept out of Clipboard History.
    func copy() async {
        await conclude(copying: true, strictly: true)
    }

    /// Escape, or the window closing without a choice: saves what it can, and always finishes.
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
    /// `meta.json` at once.
    func saveNow() {
        guard !isFinished else { return }
        isConfirmingDiscard = false
        let text = repositoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = text.isEmpty ? nil : ScreencastRepository(text)
        if let failure = record(repository: repository) {
            log(failure)
            return finish(.saveFailed(input, failure))
        }
        finish(.saved(input))
    }

    /// Discard asks first, in the window: "Discard this recording?" with Discard and Keep.
    func askToDiscard() {
        guard acceptsActions else { return }
        failure = nil
        isConfirmingDiscard = true
    }

    /// Keep: back to the actions, nothing deleted.
    func keep() {
        isConfirmingDiscard = false
    }

    /// Discard, answering "Discard this recording?": deletes the recording's folder.
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

    /// Writes the review, copies if asked, and finishes. `strictly` stops at the first
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

        if let failure = record(repository: repository) {
            // Stays open to say why; closing anyway ends without claiming it was saved.
            if strictly { return fail(failure) }
            log(failure)
            return finish(.saveFailed(input, failure))
        }
        if copying {
            guard ScreencastReviewFiles.copy(input, to: pasteboard) else { return fail(.copyFailed) }
            keepOutOfClipboardHistory()
        }
        finish(copying ? .copied(input) : .saved(input))
    }

    /// Remembers a corrected repository and writes the review into `meta.json`. Returns why that
    /// failed, or nil.
    private func record(repository: ScreencastRepository?) -> ScreencastReviewFailure? {
        if let repository, repository != guess?.repository {
            repositories.remember(repository, for: context)
        }
        // Writing would make the folder again, around nothing but the review.
        guard recordingExists else { return .recordingMissing }
        let review = ScreencastReview(
            note: Self.oneLine(note),
            type: type,
            repository: repository?.description,
            context: context,
            reviewedAt: now()
        )
        do {
            try ScreencastReview.write(review, to: input.metadataURL, fileManager: fileManager)
        } catch {
            return .saving(error, recordingExists: recordingExists)
        }
        return nil
    }

    /// The capture's folder and every video in it are still there.
    private var recordingExists: Bool {
        var isFolder: ObjCBool = false
        return fileManager.fileExists(atPath: input.folder.path, isDirectory: &isFolder) && isFolder.boolValue
            && input.mediaFiles.allSatisfy { fileManager.fileExists(atPath: $0.path) }
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
