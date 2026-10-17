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
}

/// A recording's review window's content (#475), after Snapzy's Video Editor (BSD-3-Clause, see
/// LICENSE.snapzy): the player edge to edge, `AVPlayerView` with its own controls along its bottom
/// for play, pause, and scrubbing, the video fitted to it. Discard, Copy, and Save are in the
/// window's toolbar (`ScreencastRecordingReviewToolbar`). Save and Copy close the window, and the
/// notch says where it was saved, or that it was copied. No editing, and no note, type, or
/// repository.
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

/// One control of a recording's window's toolbar, each its own toolbar item: Discard on the left, or
/// "Discard this recording?" with Keep and Discard in its place; the window's title in the middle, with
/// the display picker for a recording of every display; and Copy and Save on the right, Save the
/// window's default button, with Return's sign in it. Nothing until a review shows, nor while the
/// part makes way (`Part.isShown`).
///
/// Each button is an item of its own because macOS 26 and later draw a toolbar item's own button
/// shape around its view, not the view's button style: one item for Copy and Save drew both as
/// words in one shape, beside a title in a shape just like it (owner QA of 4030.475.4).
struct ScreencastRecordingReviewToolbar: View {
    enum Part: CaseIterable {
        /// Discard, until it's asked.
        case discard
        /// "Discard this recording?", then Keep and Discard, while it's asked.
        case question
        case keep
        case confirmDiscard
        /// The window's title, with the display picker, and a spinner while it saves.
        case title
        case copy
        case save

        /// Discard, Copy, and Save make way for the discard question while it's asked.
        func isShown(confirmingDiscard: Bool) -> Bool {
            switch self {
            case .title: true
            case .question, .keep, .confirmDiscard: confirmingDiscard
            case .discard, .copy, .save: !confirmingDiscard
            }
        }
    }

    /// Return, as macOS shows it beside a menu item: Save's key.
    static let returnSign = "↩"

    let model: ScreencastReviewModel?
    let part: Part

    var body: some View {
        if let model, part.isShown(confirmingDiscard: model.isConfirmingDiscard) {
            switch part {
            case .discard:
                Button("Discard", role: .destructive, action: model.askToDiscard)
                    .buttonStyle(.bordered)
                    .disabled(!model.acceptsActions)
                    .help("Delete this recording")
                    .accessibilityIdentifier(ScreencastReviewID.discard)
            case .question:
                Text("Discard this recording?")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
            case .keep:
                Button("Keep", action: model.keep)
                    .buttonStyle(.bordered)
                    .help("Keep the recording")
                    .accessibilityIdentifier(ScreencastReviewID.keep)
            case .confirmDiscard:
                Button("Discard", role: .destructive) {
                    Task { model.confirmDiscard() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Delete the recording and its folder")
                .accessibilityIdentifier(ScreencastReviewID.confirmDiscard)
            case .title:
                title(model)
            case .copy:
                Button("Copy") {
                    Task { await model.copy() }
                }
                .buttonStyle(.bordered)
                .disabled(!model.acceptsActions)
                .help("Save, and copy the recording’s file")
                .accessibilityIdentifier(ScreencastReviewID.copy)
            case .save:
                Button {
                    Task { await model.save() }
                } label: {
                    // Return's sign, as a menu shows a key equivalent: Return saves (owner QA of
                    // 4030.475.5). VoiceOver reads just "Save".
                    HStack(spacing: 5) {
                        Text("Save")
                        Text(Self.returnSign)
                            .opacity(0.7)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                // The window's default button. Return is the review's key monitor's, which saves.
                .keyboardShortcut(.defaultAction)
                .disabled(!model.acceptsActions)
                .help("Keep the recording in the recordings folder (Return)")
                .accessibilityLabel("Save")
                .accessibilityIdentifier(ScreencastReviewID.save)
            }
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
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
            ScreencastReviewDisplayPicker(model: model)
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
