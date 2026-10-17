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
/// LICENSE.snapzy): the bar the Screenshot Editor has too (`ScreencastRecordingReviewBar`, #511),
/// then the player edge to edge, `AVPlayerView` with its own controls along its bottom for play,
/// pause, and scrubbing, the video fitted to it. Save and Copy close the window, and the notch says
/// where it was saved, or that it was copied. No editing yet, and no note, type, or repository.
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
        }
        .uiTestAnimationsDisabled()
        .onChange(of: model.isWorking) { _, isWorking in
            if isWorking { playback?.pause() }
        }
    }
}

/// The recording window's bar, the Screenshot Editor's (`ScreengrabsEditorBar`, #511): no tools yet
/// (#517 adds Trim, Crop, and Blur), then a spinner while it saves, the display picker for a
/// recording of every display, and Discard, Copy, and Save, Save the window's default button. While
/// Discard is asked, "Discard this recording?" with Keep and Discard takes their place.
struct ScreencastRecordingReviewBar: View {
    /// Return, as macOS shows it beside a menu item: Save's key.
    static let returnSign = "↩"
    /// Copy's key.
    static let copyKey = "⌘C"
    static let discardQuestion = "Discard this recording?"

    let model: ScreencastReviewModel

    var body: some View {
        ScreengrabsEditorBar(
            question: model.isConfirmingDiscard ? Self.discardQuestion : nil,
            actions: Self.actions(for: model)
        ) {
            // The tools' place, empty until the recording has tools of its own.
        } accessories: {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
            ScreencastReviewDisplayPicker(model: model)
        }
    }

    /// Discard, Copy, and Save, or, while Discard is asked, Keep and Discard, which no key answers.
    /// Return saves and ⌘C copies through the review's key monitor (`ScreencastReviewKey`).
    static func actions(for model: ScreencastReviewModel) -> [ScreengrabsEditorAction] {
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
                title: "Save", key: returnSign, style: .prominent, isDefault: true,
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
