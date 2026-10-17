import AppKit
import AVKit
import SwiftUI

/// The review window's accessibility identifiers, which the UI tests drive.
enum ScreencastReviewID {
    /// The window (#475), and the player's area in it.
    static let window = "screencast.review.window"
    static let playerArea = "screencast.review.playerArea"
    static let player = "screencast.review.player"
    static let display = "screencast.review.display"
    static let save = "screencast.review.save"
    static let copy = "screencast.review.copy"
    static let discard = "screencast.review.discard"
    /// Discard, answering "Discard this recording?".
    static let confirmDiscard = "screencast.review.confirmDiscard"
    static let keep = "screencast.review.keep"
    static let failure = "screencast.review.failure"
    /// The tools and Trim's options and timeline (#517).
    static func tool(_ tool: ScreencastEditTool) -> String { "screencast.review.tool.\(tool.rawValue)" }
    static let cutSection = "screencast.review.cutSection"
    static let length = "screencast.review.length"
    static let resetTrim = "screencast.review.resetTrim"
    static let timeline = "screencast.review.timeline"
    /// Crop's and Blur's options, and what they draw over the video (#517).
    static let cropAspect = "screencast.review.cropAspect"
    static let resetCrop = "screencast.review.resetCrop"
    static let cropOverlay = "screencast.review.cropOverlay"
    static let blurStrength = "screencast.review.blurStrength"
    static let deleteBlur = "screencast.review.deleteBlur"
    static let blurOverlay = "screencast.review.blurOverlay"
    static let blurLanes = "screencast.review.blurLanes"
    /// Saving the edits (#517): the export's progress and Cancel, "Save your edits?" with Keep
    /// Original and Save Edited, and a failure's Save Original and Try Again.
    static let exportProgress = "screencast.review.exportProgress"
    static let cancelExport = "screencast.review.cancelExport"
    static let keepOriginal = "screencast.review.keepOriginal"
    static let saveEdited = "screencast.review.saveEdited"
    static let exportFailure = "screencast.review.exportFailure"
    static let saveOriginal = "screencast.review.saveOriginal"
    static let tryAgain = "screencast.review.tryAgain"
}

/// A recording's review window's content (#475), after Snapzy's Video Editor (BSD-3-Clause, see
/// LICENSE.snapzy): the bar the Screenshot Editor has too (`ScreencastRecordingReviewBar`, #511),
/// then the player edge to edge, `AVPlayerView` with its own controls along its bottom for play,
/// pause, and scrubbing, the video fitted to it, playing the edits (#517). Picking Trim or Blur opens
/// the timeline under it, and Crop and Blur draw over the video (`ScreencastEditOverlay`). Save and
/// Copy close the window, and the notch says where it was saved, or that it was copied. No note,
/// type, or repository.
struct ScreencastRecordingReviewView: View {
    let model: ScreencastReviewModel
    /// The player, for a window on screen; nil under the unit-test host.
    let playback: ScreencastReviewPlayback?

    var body: some View {
        // One SwiftUI root, as the Screenshot Editor's, so the bar always draws.
        VStack(spacing: 0) {
            ScreencastRecordingReviewBar(model: model)
            ScreencastReviewPlayer(model: model, playback: playback)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay {
                    // The frame under a dragged trim handle (#517).
                    if let frame = playback?.previewFrame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Crop's and Blur's rectangles over the video (#517).
                    if model.tool == .crop || model.tool == .blur {
                        ScreencastEditOverlay(model: model, playback: playback)
                    }
                }
                .overlay(alignment: .top) {
                    // Over the player, so it takes no row of its own.
                    if let exportFailure = model.exportFailure {
                        ScreencastExportFailureBanner(
                            failure: exportFailure,
                            saveOriginal: { Task { await model.saveOriginal() } },
                            tryAgain: { Task { await model.tryAgain() } }
                        )
                        .padding(18)
                    } else if let failure = model.failure {
                        Text(failure.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                            .accessibilityIdentifier(ScreencastReviewID.failure)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recording")
                .accessibilityIdentifier(ScreencastReviewID.playerArea)
            if model.showsTimeline {
                ScreencastTrimTimeline(model: model, playback: playback)
            }
        }
        .uiTestAnimationsDisabled()
        .onChange(of: model.isWorking) { _, isWorking in
            if isWorking { playback?.pause() }
        }
        .onChange(of: model.tool) { _, tool in
            // Crop places the crop on a still frame (#517).
            if tool == .crop { playback?.pause() }
        }
    }
}

/// The recording window's bar, the Screenshot Editor's (`ScreengrabsEditorBar`, #511): the tools
/// and the picked one's options (#517), then the export's progress or a spinner while it saves, the
/// display picker for a recording of every display, undo and redo, and Discard, Copy, and Save, Save
/// the window's default button. While Discard is asked, "Discard this recording?" with Keep and
/// Discard takes their place; while closing with edits asks, "Save your edits?" with Keep Original and
/// Save Edited; and while the edited recording is written, Cancel.
struct ScreencastRecordingReviewBar: View {
    /// Copy's key.
    static let copyKey = "⌘C"
    static let discardQuestion = "Discard this recording?"
    static let saveEditsQuestion = "Save your edits?"
    static let cancelKey = "esc"

    let model: ScreencastReviewModel

    var body: some View {
        ScreengrabsEditorBar(
            history: history,
            question: Self.question(for: model),
            actions: Self.actions(for: model)
        ) {
            ScreencastEditToolsBar(model: model)
        } accessories: {
            if let progress = model.exportProgress {
                ScreencastExportProgress(progress: progress)
            } else if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
            ScreencastReviewDisplayPicker(model: model)
        }
    }

    /// Undo and redo, each only when there's an edit to take back or put back.
    var history: ScreengrabsEditorHistory? {
        ScreengrabsEditorHistory(canUndo: model.canUndo, canRedo: model.canRedo, undo: model.undo, redo: model.redo)
    }

    /// The question the actions answer, if one is asked.
    static func question(for model: ScreencastReviewModel) -> String? {
        if model.isConfirmingDiscard { return discardQuestion }
        if model.isAskingToSaveEdits { return saveEditsQuestion }
        return nil
    }

    /// Discard, Copy, and Save; while Discard is asked, Keep and Discard, which no key answers; while
    /// closing with edits asks, Keep Original and Save Edited, which Return answers; and while the
    /// edited recording is written, Cancel, which Escape also does. Return saves and ⌘C copies
    /// through the review's key monitor (`ScreencastReviewKey`).
    static func actions(for model: ScreencastReviewModel) -> [ScreengrabsEditorAction] {
        if model.isExporting {
            return [
                ScreengrabsEditorAction(
                    title: "Cancel", key: cancelKey, help: "Stop exporting; the original stays as it was (Esc)",
                    identifier: ScreencastReviewID.cancelExport, perform: model.cancelExport
                ),
            ]
        }
        if model.isConfirmingDiscard {
            return [
                ScreengrabsEditorAction(
                    title: "Keep", help: "Keep the recording", identifier: ScreencastReviewID.keep, perform: model.keep
                ),
                ScreengrabsEditorAction(
                    title: "Discard", style: .prominentDestructive, help: "Delete the recording and its folder",
                    identifier: ScreencastReviewID.confirmDiscard
                ) {
                    Task { model.confirmDiscard() }
                },
            ]
        }
        if model.isAskingToSaveEdits {
            return [
                ScreengrabsEditorAction(
                    title: "Keep Original", help: "Save the recording without the edits",
                    identifier: ScreencastReviewID.keepOriginal
                ) {
                    Task { await model.keepOriginal() }
                },
                ScreengrabsEditorAction(
                    title: "Save Edited", key: ScreengrabsEditorAction.returnSign, style: .prominent, isDefault: true,
                    help: "Save the recording with the edits (Return)", identifier: ScreencastReviewID.saveEdited
                ) {
                    Task { await model.saveEdited() }
                },
            ]
        }
        return [
            ScreengrabsEditorAction(
                title: "Discard", style: .destructive, help: "Delete this recording",
                identifier: ScreencastReviewID.discard, isEnabled: model.acceptsActions, perform: model.askToDiscard
            ),
            ScreengrabsEditorAction(
                title: "Copy", key: copyKey, help: "Save, and copy the recording’s file (⌘C)",
                identifier: ScreencastReviewID.copy, isEnabled: model.acceptsActions
            ) {
                Task { await model.copy() }
            },
            ScreengrabsEditorAction(
                title: "Save", key: ScreengrabsEditorAction.returnSign, style: .prominent, isDefault: true,
                help: "Keep the recording in the recordings folder (Return)",
                identifier: ScreencastReviewID.save, isEnabled: model.acceptsActions
            ) {
                Task { await model.save() }
            },
        ]
    }
}

/// Which display's video shows, for a recording of every display.
struct ScreencastReviewDisplayPicker: View {
    @Bindable var model: ScreencastReviewModel

    var body: some View {
        if model.displayCount > 1 {
            Picker("Display", selection: $model.selectedDisplay) {
                ForEach(0..<model.displayCount, id: \.self) { index in
                    Text("\(index + 1)").tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Which display’s recording shows")
            .accessibilityLabel("Display")
            .accessibilityIdentifier(ScreencastReviewID.display)
        }
    }
}

/// The recording's `AVPlayerView`, showing the selected display's video, or black under the
/// unit-test host.
private struct ScreencastReviewPlayer: View {
    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?

    var body: some View {
        if let playback {
            ScreencastReviewAVPlayerView(playback: playback)
                .onAppear { showCurrentVideo() }
                .onChange(of: model.selectedDisplay) { showCurrentVideo() }
                .onChange(of: model.editRevision) { showCurrentVideo() }
                .onChange(of: model.tool) { showCurrentVideo() }
        } else {
            Color.black
        }
    }

    /// The selected display's video, with the edits: the whole frame while Crop is picked, to place
    /// the crop over it.
    private func showCurrentVideo() {
        guard let playback, let video = model.currentVideo else { return }
        playback.show(video, display: model.selectedDisplay, edits: model.edits, crops: model.tool != .crop)
    }
}

/// Puts the review's `AVPlayerView` in the SwiftUI layout.
private struct ScreencastReviewAVPlayerView: NSViewRepresentable {
    let playback: ScreencastReviewPlayback

    func makeNSView(context: Context) -> AVPlayerView { playback.view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
