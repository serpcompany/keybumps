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
    /// Discard, answering "Discard this capture?".
    static let confirmDiscard = "screencast.review.confirmDiscard"
    static let keep = "screencast.review.keep"
    static let failure = "screencast.review.failure"
}

/// A recording's review window's content (#475), after Snapzy's Video Editor (BSD-3-Clause, see
/// LICENSE.snapzy): the player edge to edge, `AVPlayerView` with its own controls along its bottom
/// for play, pause, and scrubbing, the video fitted to it. Discard, Copy, and Save are in the
/// window's toolbar (`ScreencastRecordingReviewToolbar`). Save and Copy close the window, and the
/// notch says it's done. No editing, and no note, type, or repository.
struct ScreencastRecordingReviewView: View {
    let model: ScreencastReviewModel
    /// The player, for a window on screen; nil under the unit-test host.
    let playback: ScreencastReviewPlayback?

    var body: some View {
        ScreencastReviewPlayer(model: model, playback: playback)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay(alignment: .top) {
                // Over the player, so it takes no row of its own.
                if let failure = model.failure {
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
            .uiTestAnimationsDisabled()
            .onChange(of: model.isWorking) { _, isWorking in
                if isWorking { playback?.pause() }
            }
    }
}

/// A part of a recording's window's toolbar: Discard on the left, or "Discard this capture?" with
/// Keep and Discard in its place; the window's title in the middle, with the display picker for a
/// recording of every display; and Copy and Save on the right, Save the primary one. Nothing until a
/// review shows.
struct ScreencastRecordingReviewToolbar: View {
    enum Part {
        case leading
        case middle
        case trailing
    }

    let model: ScreencastReviewModel?
    let part: Part

    var body: some View {
        if let model {
            switch part {
            case .leading: discard(model)
            case .middle: title(model)
            case .trailing: actions(model)
            }
        }
    }

    @ViewBuilder private func discard(_ model: ScreencastReviewModel) -> some View {
        if model.isConfirmingDiscard {
            HStack(spacing: 8) {
                Text("Discard this capture?")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Button("Keep", action: model.keep)
                    .help("Keep the capture")
                    .accessibilityIdentifier(ScreencastReviewID.keep)
                Button("Discard", role: .destructive) {
                    Task { model.confirmDiscard() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Delete the capture and its folder")
                .accessibilityIdentifier(ScreencastReviewID.confirmDiscard)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Discard this capture?")
        } else {
            Button("Discard", role: .destructive, action: model.askToDiscard)
                .disabled(!model.acceptsActions)
                .help("Delete this capture")
                .accessibilityIdentifier(ScreencastReviewID.discard)
        }
    }

    /// The window hides its own title, which would push the actions together (macOS lets a shown
    /// title take the flexible spaces' room), so it's here.
    private func title(_ model: ScreencastReviewModel) -> some View {
        HStack(spacing: 10) {
            Text("Recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            ScreencastReviewDisplayPicker(model: model)
        }
    }

    /// Hidden while the discard question is up.
    @ViewBuilder private func actions(_ model: ScreencastReviewModel) -> some View {
        if !model.isConfirmingDiscard {
            HStack(spacing: 8) {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving")
                }
                Button("Copy") {
                    Task { await model.copy() }
                }
                .help("Save, and copy the recording’s file")
                .accessibilityIdentifier(ScreencastReviewID.copy)
                Button("Save") {
                    Task { await model.save() }
                }
                .buttonStyle(.borderedProminent)
                .help("Keep the recording in the captures folder (Return)")
                .accessibilityIdentifier(ScreencastReviewID.save)
            }
            .disabled(!model.acceptsActions)
        }
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
        } else {
            Color.black
        }
    }

    private func showCurrentVideo() {
        guard let playback, let video = model.currentVideo else { return }
        playback.show(video)
    }
}

/// Puts the review's `AVPlayerView` in the SwiftUI layout.
private struct ScreencastReviewAVPlayerView: NSViewRepresentable {
    let playback: ScreencastReviewPlayback

    func makeNSView(context: Context) -> AVPlayerView { playback.view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
