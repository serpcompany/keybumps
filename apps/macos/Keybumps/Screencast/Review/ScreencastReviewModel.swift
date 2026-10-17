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
///
/// With edits (#517), Save and Copy first write the edited recording (`ScreencastEditExport`), with
/// its progress in the bar, and keep the original until that's complete; a failure stays open to say
/// why, with Try Again and Save Original. Closing with edits asks first ("Save your edits?", Keep
/// Original or Save Edited). The ways out that can't ask (the next capture, quitting, turning
/// ScreenGrabs off) keep the original, since an export could fail after the window is gone.
@MainActor
@Observable
final class ScreencastReviewModel {
    /// The recording; once Save or Copy has written its edits, the edited one.
    private(set) var input: ScreencastReviewInput
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

    /// The tool picked in the bar, or none (#517).
    private(set) var tool: ScreencastEditTool?
    /// The edits, until Save or Copy writes them.
    private(set) var edits: ScreencastRecordingEdits
    /// Changes when an edit is made, undone, or redone, but not during a drag: the player then plays
    /// the edits.
    private(set) var editRevision = 0
    /// The part of the timeline selected to cut, in the recording's time.
    private(set) var trimSelection: ScreencastTimeRange?
    /// "Save your edits?", asked in the bar when the window is closed with edits.
    private(set) var isAskingToSaveEdits = false
    /// How far the edited recording is written, from 0 to 1, while Save or Copy writes it.
    private(set) var exportProgress: Double?
    /// Why the edited recording wasn't written, until the next action.
    private(set) var exportFailure: ScreencastExportFailure?
    /// The blur picked on the shown display, which Strength, Delete, and its handles change.
    private(set) var selectedBlurID: Int?
    /// The strength of the next blur drawn: the last picked in Strength, or the last blur picked's.
    private var nextBlurStrength: ScreencastBlurStrength = .high

    /// Called once, when the review is done with the capture.
    @ObservationIgnored var onFinish: ((ScreencastReviewOutcome) -> Void)?

    @ObservationIgnored private let repositories: ScreencastRepositoryMemory
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let keepOutOfClipboardHistory: () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let export: ScreencastEditExport
    /// The edits before each change, newest last, and those undone, newest last.
    @ObservationIgnored private var undoStack: [ScreencastRecordingEdits] = []
    @ObservationIgnored private var redoStack: [ScreencastRecordingEdits] = []
    /// The edits as a drag found them, until it ends.
    @ObservationIgnored private var editsBeforeDrag: ScreencastRecordingEdits?
    /// The export under way, which Cancel stops.
    @ObservationIgnored private var exportCancellation: ScreencastExportCancellation?
    /// Whether the export that failed was for Copy, which Try Again does again.
    @ObservationIgnored private var exportWasCopying = false
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
    ///   - export: How Save and Copy write the edits: the movies, or a test's stand-in.
    init(
        input: ScreencastReviewInput,
        context: ScreencastCaptureContext = .none,
        contextRead: Task<ScreencastCaptureContext, Never>? = nil,
        repositories: ScreencastRepositoryMemory,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard,
        keepOutOfClipboardHistory: @escaping () -> Void,
        now: @escaping () -> Date = Date.init,
        export: ScreencastEditExport = .movies
    ) {
        self.input = input
        self.export = export
        edits = Self.noEdits(for: input)
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
        // An export stops, so the original is kept; a Save or Copy under way finishes first, and if
        // it stopped at a failure, this saves anyway.
        exportCancellation?.cancel()
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
        if let cancellation = exportCancellation, case .video(let capture) = input {
            // Returns once a swap under way is done; the app may quit before the export's own
            // clean-up, so its edited copies go now.
            cancellation.cancel()
            ScreencastEditExporter.removePartialFiles(of: capture, fileManager: fileManager)
        }
        isConfirmingDiscard = false
        isAskingToSaveEdits = false
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
        exportFailure = nil
        isAskingToSaveEdits = false
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
    private func conclude(copying: Bool, strictly: Bool, withEdits: Bool = true) async {
        guard !isFinished, !isWorking, !strictly || acceptsActions else { return }
        endDrag()
        isConfirmingDiscard = false
        isAskingToSaveEdits = false
        failure = nil
        exportFailure = nil
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
        // Only a choice made in the window writes the edits; the ways out that can't ask keep the
        // original.
        if strictly, withEdits, !edits.isEmpty {
            guard await exportEdits(copying: copying) else { return }
        }

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

    // MARK: Editing (#517)

    /// No edits, for `input`'s recording.
    private static func noEdits(for input: ScreencastReviewInput) -> ScreencastRecordingEdits {
        switch input {
        case .video(let capture): ScreencastRecordingEdits(duration: capture.duration, displayCount: capture.videos.count)
        }
    }

    /// The tools and their options take edits only while nothing else is under way or asked.
    var acceptsEdits: Bool { acceptsActions && !isConfirmingDiscard && !isAskingToSaveEdits }

    /// The timeline shows under the player while Trim or Blur is picked (decision 1).
    var showsTimeline: Bool { tool == .trim || tool == .blur }

    /// Picks `tool`, or puts it down if it's picked.
    func pick(_ tool: ScreencastEditTool) {
        guard acceptsEdits else { return }
        endDrag()
        self.tool = self.tool == tool ? nil : tool
        trimSelection = nil
    }

    /// Escape with a tool picked: puts it down.
    func putToolDown() {
        endDrag()
        tool = nil
        trimSelection = nil
    }

    var canUndo: Bool { acceptsEdits && !undoStack.isEmpty }
    var canRedo: Bool { acceptsEdits && !redoStack.isEmpty }

    func undo() {
        endDrag()
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(edits)
        apply(previous)
    }

    func redo() {
        endDrag()
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(edits)
        apply(next)
    }

    /// Makes one edit that can be undone, if `change` says it changed something.
    func edit(_ change: (inout ScreencastRecordingEdits) -> Bool) {
        guard acceptsEdits else { return }
        endDrag()
        var changed = edits
        guard change(&changed), changed != edits else { return }
        undoStack.append(edits)
        redoStack = []
        apply(changed)
    }

    /// A drag starts: its changes are one edit, made when it ends, or when something else happens
    /// first (a tool picked or put down, undo, redo, another edit, a blur picked, Save), since the
    /// drag may then never say it ended. A drag that goes on after that changes nothing until it
    /// begins again. Crop's and Blur's begin only as the press starts, so the rest of a press cut
    /// short changes nothing.
    func beginDrag() {
        guard acceptsEdits, editsBeforeDrag == nil else { return }
        editsBeforeDrag = edits
    }

    /// A change during a drag, shown at once and played once the drag ends.
    func dragEdit(_ change: (inout ScreencastRecordingEdits) -> Void) {
        guard acceptsEdits, editsBeforeDrag != nil else { return }
        change(&edits)
    }

    /// The drag ends: what it changed is one edit. Nothing without a drag.
    func endDrag() {
        guard let before = editsBeforeDrag else { return }
        editsBeforeDrag = nil
        guard before != edits else { return }
        undoStack.append(before)
        redoStack = []
        editRevision += 1
    }

    private func apply(_ edits: ScreencastRecordingEdits) {
        self.edits = edits
        trimSelection = nil
        editRevision += 1
    }

    // MARK: Trim (#517)

    /// Selects part of the timeline to cut, or clears the selection.
    func selectForCut(_ range: ScreencastTimeRange?) {
        guard acceptsEdits else { return }
        trimSelection = range.flatMap { $0.duration > 0 ? $0 : nil }
    }

    /// I: the selection starts at `time`, ending where it did, or at the trim's end.
    func markSelectionStart(at time: Double) {
        let end = trimSelection?.end ?? edits.trim.end
        selectForCut(ScreencastTimeRange(start: time, end: max(end, time)))
    }

    /// O: the selection ends at `time`, starting where it did, or at the trim's start.
    func markSelectionEnd(at time: Double) {
        let start = trimSelection?.start ?? edits.trim.start
        selectForCut(ScreencastTimeRange(start: min(start, time), end: time))
    }

    /// Cut Section, or ⌫: cuts the selection out.
    func cutSelection() {
        guard let selection = trimSelection else { return }
        edit { $0.cut(selection) }
    }

    /// Restore, on a cut: brings it back.
    func restoreCut(at time: Double) {
        edit { $0.restoreCut(at: time) }
    }

    /// Reset Trim: the whole recording again.
    func resetTrim() {
        edit { edits in
            edits.resetTrim()
            return true
        }
    }

    // MARK: Crop (#517)

    /// The shown display's video's size in pixels.
    var pixelSize: CGSize {
        guard let video = currentVideo else { return .zero }
        return CGSize(width: video.pixelWidth, height: video.pixelHeight)
    }

    /// The shown display's edits.
    private var shownEdits: ScreencastDisplayEdits {
        edits.displays.indices.contains(selectedDisplay) ? edits.displays[selectedDisplay] : ScreencastDisplayEdits()
    }

    /// The shown display's crop, in fractions of its frame: the whole frame without one.
    var crop: CGRect { shownEdits.crop ?? ScreencastFrameRect.whole }

    /// The shown display is cropped.
    var hasCrop: Bool { shownEdits.crop != nil }

    /// Crop's shape on the shown display, kept while its handles are dragged; part of the edits, so
    /// undo, redo, and Reset Crop take it with the crop.
    var cropAspect: ScreencastCropAspect { shownEdits.cropAspect }

    /// The crop in the shown video's pixels, as Save writes it.
    var cropPixels: CGRect {
        shownEdits.cropPixels(width: Int(pixelSize.width), height: Int(pixelSize.height))
    }

    /// The part of the shown frame the player shows, in fractions: all of it while Crop is picked,
    /// to place the crop over it, and otherwise the crop as Save writes it.
    var shownFrame: CGRect {
        let size = pixelSize
        guard tool != .crop, shownEdits.crop != nil, size.width > 0, size.height > 0 else { return ScreencastFrameRect.whole }
        let pixels = cropPixels
        return CGRect(
            x: pixels.minX / size.width, y: pixels.minY / size.height,
            width: pixels.width / size.width, height: pixels.height / size.height
        )
    }

    /// A shape in Crop's segmented control: the largest crop of that shape, centered where the crop
    /// is. Free keeps the crop and lets its sides move on their own.
    func setCropAspect(_ aspect: ScreencastCropAspect) {
        guard acceptsEdits else { return }
        let display = selectedDisplay
        let reshaped = ScreencastFrameRect.crop(aspect, around: crop, pixelSize: pixelSize)
        edit { $0.setCrop(reshaped, aspect: aspect, display: display) }
    }

    /// Reset Crop: the whole frame again, Free.
    func resetCrop() {
        let display = selectedDisplay
        edit { $0.setCrop(nil, display: display) }
    }

    /// A crop handle, or the crop, dragged to `rect`, after `beginDrag`: one edit when the drag ends.
    func dragCrop(to rect: CGRect) {
        let display = selectedDisplay
        dragEdit { $0.setCrop(rect, display: display) }
    }

    // MARK: Blur (#517)

    /// The shown display's blurs, in the order drawn.
    var blurs: [ScreencastBlur] { shownEdits.blurs }

    /// The picked blur, if it's on the shown display.
    var selectedBlur: ScreencastBlur? { blurs.first { $0.id == selectedBlurID } }

    /// What Strength shows: the picked blur's, as the edits have it after undo, redo, or a display
    /// switch; with none picked, the next one drawn's.
    var blurStrength: ScreencastBlurStrength { selectedBlur?.strength ?? nextBlurStrength }

    /// Draws a blur over `rect` on the shown display, at the strength picked, showing for the whole
    /// recording, and picks it.
    func addBlur(_ rect: CGRect) {
        let display = selectedDisplay
        let strength = nextBlurStrength
        var added: Int?
        edit { edits in
            added = edits.addBlur(rect, strength: strength, display: display)
            return added != nil
        }
        if let added { selectedBlurID = added }
    }

    /// Picks the blur `id`, or none. A drag under way ends first: its handles are the picked blur's.
    func selectBlur(_ id: Int?) {
        guard acceptsEdits else { return }
        endDrag()
        selectedBlurID = id.flatMap { id in blurs.contains { $0.id == id } ? id : nil }
        if let selectedBlur { nextBlurStrength = selectedBlur.strength }
    }

    /// Tab: picks the next blur drawn, after the last the first.
    func selectNextBlur() {
        let blurs = blurs
        guard !blurs.isEmpty else { return }
        let index = blurs.firstIndex { $0.id == selectedBlurID }.map { ($0 + 1) % blurs.count } ?? 0
        selectBlur(blurs[index].id)
    }

    /// Strength: the picked blur's, and the next one drawn.
    func setBlurStrength(_ strength: ScreencastBlurStrength) {
        guard acceptsEdits else { return }
        nextBlurStrength = strength
        guard let id = selectedBlur?.id else { return }
        let display = selectedDisplay
        edit { $0.setBlurStrength(id, display: display, to: strength) }
    }

    /// Delete, or ⌫: takes the picked blur off.
    func deleteSelectedBlur() {
        guard let id = selectedBlur?.id else { return }
        let display = selectedDisplay
        edit { $0.removeBlur(id, display: display) }
        if selectedBlur == nil { selectedBlurID = nil }
    }

    /// The blur `id` moved or resized to `rect`, after `beginDrag`: one edit when the drag ends.
    func dragBlur(_ id: Int, to rect: CGRect) {
        let display = selectedDisplay
        dragEdit { $0.setBlurRect(id, display: display, to: rect) }
    }

    /// An end of the blur `id`'s bar on the timeline dragged to `time`, after `beginDrag`: one edit
    /// when the drag ends.
    func dragBlurTime(_ id: Int, edge: ScreencastTimeEdge, to time: Double) {
        let display = selectedDisplay
        dragEdit { $0.setBlurTime(id, display: display, edge: edge, to: time) }
    }

    // MARK: Saving the edits (#517)

    /// Save or Copy is writing the edited recording.
    var isExporting: Bool { exportProgress != nil }

    /// The displays (from 0) with nothing in the kept part, their streams having stopped before it:
    /// Save keeps their videos as they were recorded.
    var displaysWithNothingKept: [Int] {
        guard edits.isTrimmed else { return [] }
        return videos.indices.filter { !edits.keepsSomething(of: videos[$0]) }
    }

    /// What the window says about them, or nil.
    var nothingKeptNotice: String? {
        let names = displaysWithNothingKept.map { "\($0 + 1)" }
        guard let last = names.last else { return nil }
        guard names.count > 1 else { return "Display \(last) has nothing in the kept part. Save keeps it as it was recorded." }
        let list = names.dropLast().joined(separator: ", ") + " and " + last
        return "Displays \(list) have nothing in the kept part. Save keeps them as they were recorded."
    }

    /// Closing the window asks first: there are edits Save or Copy hasn't written.
    var asksBeforeClosing: Bool { acceptsActions && !edits.isEmpty }

    /// The window is closing with edits: "Save your edits?" in the bar.
    func askToSaveEdits() {
        guard asksBeforeClosing else { return }
        isConfirmingDiscard = false
        exportFailure = nil
        isAskingToSaveEdits = true
    }

    /// Escape while it's asked: back to editing.
    func dismissSaveQuestion() {
        isAskingToSaveEdits = false
    }

    /// Keep Original: saves the recording as it was recorded, without the edits.
    func keepOriginal() async {
        await conclude(copying: false, strictly: true, withEdits: false)
    }

    /// Save Edited: Save, with the edits.
    func saveEdited() async {
        await save()
    }

    /// Cancel, or Escape, while the edited recording is written: stops it, and nothing changes on disk.
    func cancelExport() {
        exportCancellation?.cancel()
    }

    /// Try Again, after an export failed: what failed, again.
    func tryAgain() async {
        await conclude(copying: exportWasCopying, strictly: true)
    }

    /// Save Original, after an export failed: saves the recording without the edits.
    func saveOriginal() async {
        await keepOriginal()
    }

    /// Writes the edits into the recording's files. Returns whether it did; if not, the original is
    /// as it was and the window says why, unless it was cancelled.
    private func exportEdits(copying: Bool) async -> Bool {
        guard case .video(let capture) = input else { return true }
        exportWasCopying = copying
        let cancellation = ScreencastExportCancellation()
        exportCancellation = cancellation
        exportProgress = 0
        defer {
            exportProgress = nil
            exportCancellation = nil
        }
        do {
            let edited = try await export.run(capture, edits, cancellation) { [weak self] fraction in
                Task { @MainActor in self?.exportMoved(to: fraction) }
            }
            input = .video(edited)
            tool = nil
            trimSelection = nil
            undoStack = []
            redoStack = []
            apply(Self.noEdits(for: input))
            return true
        } catch {
            // The export deletes what it wrote; a stand-in, or one cut short, may not have.
            ScreencastEditExporter.removePartialFiles(of: capture, fileManager: fileManager)
            let failure = ScreencastExportFailure.from(error)
            guard failure != .cancelled else { return false }
            exportFailure = failure
            logger.error("screencast export failed category=\(failure.rawValue, privacy: .public)")
            return false
        }
    }

    private func exportMoved(to fraction: Double) {
        guard let progress = exportProgress else { return }
        exportProgress = max(progress, min(fraction, 1))
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
