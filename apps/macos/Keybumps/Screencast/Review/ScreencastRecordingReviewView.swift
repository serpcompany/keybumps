import AppKit
import AVKit
import SwiftUI

/// A recording's review window (#475), laid out after Snapzy's Video Editor (BSD-3-Clause, see
/// LICENSE.snapzy): the player on the left, `AVPlayerView` with its own controls along its bottom
/// for play, pause, and scrubbing, and the display picker and Trim under it; the review in a
/// 320-point sidebar on the right, the panel's note, type, repository, and destination; and a bottom
/// bar with Discard, Copy, and Save. Once the recording is saved or copied, the bar says so and
/// where, with Show in Finder and Done. No editing beyond the panel's Trim.
struct ScreencastRecordingReviewView: View {
    static let sidebarWidth: CGFloat = 320

    @Bindable var model: ScreencastReviewModel
    /// The player, for a window on screen; nil under the unit-test host.
    let playback: ScreencastReviewPlayback?
    /// Reveals the capture's folder (`ScreencastReviewConfirmation.folder`).
    let showInFinder: () -> Void
    /// Closes the window, once the recording is saved or copied.
    let done: () -> Void

    @FocusState private var focus: ScreencastReviewField?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                playerColumn
                Divider()
                sidebar
            }
            Divider()
            bottomBar
        }
        .uiTestAnimationsDisabled()
        // No `focus = .note` on appearing, unlike the panel: the window is for watching, so Space
        // plays at once, and a click in the note types there.
        .onChange(of: model.isWorking) { _, isWorking in
            if isWorking { playback?.pause() }
        }
    }

    // MARK: The player

    private var playerColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                ScreencastReviewPlayer(model: model, playback: playback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let duration = model.durationText {
                    ScreencastReviewBadge(text: duration)
                        .accessibilityLabel("Length")
                        .accessibilityValue(duration)
                        .accessibilityIdentifier(ScreencastReviewID.duration)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording")
            .accessibilityIdentifier(ScreencastReviewID.playerArea)
            HStack(spacing: 8) {
                ScreencastReviewDisplayPicker(model: model)
                Spacer()
                Button {
                    if let playback { model.trim(with: playback) }
                } label: {
                    Label("Trim", systemImage: "timeline.selection")
                }
                .buttonStyle(PalettePillButtonStyle(showsIcon: true))
                .disabled(!model.acceptsActions || playback == nil)
                .help(model.trimRange == nil ? "Trim the recording" : "Change the trim")
                .accessibilityIdentifier(ScreencastReviewID.trim)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreencastReviewFields(model: model, focus: $focus)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ScreencastReviewDestination(model: model)
                HStack(spacing: 8) {
                    ScreencastReviewSendButtons(model: model)
                }
            }
            if let failure = model.failure {
                Text(failure.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(ScreencastReviewID.failure)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
        .accessibilityIdentifier(ScreencastReviewID.sidebar)
    }

    // MARK: The bottom bar

    @ViewBuilder private var bottomBar: some View {
        Group {
            if model.isConfirmingDiscard {
                ScreencastReviewDiscardQuestion(model: model)
            } else if let confirmation = ScreencastReviewConfirmation(model.outcome) {
                confirmed(confirmation)
            } else {
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Discard", role: .destructive, action: model.askToDiscard)
                .buttonStyle(PalettePillButtonStyle())
                .help("Delete this capture")
                .accessibilityIdentifier(ScreencastReviewID.discard)
            Spacer()
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            }
            Button("Copy") {
                Task { await model.copy() }
            }
            .buttonStyle(PalettePillButtonStyle())
            .help("Save, and copy the recording’s file")
            .accessibilityIdentifier(ScreencastReviewID.copy)
            Button("Save") {
                Task { await model.save() }
            }
            .buttonStyle(ScreencastReviewFilledButtonStyle(tint: .accentColor))
            .help("Keep the capture with its note (Return)")
            .accessibilityIdentifier(ScreencastReviewID.save)
        }
        .disabled(!model.acceptsActions)
    }

    /// "Saved · Documents › Keybumps › captures", with Show in Finder and Done.
    private func confirmed(_ confirmation: ScreencastReviewConfirmation) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(confirmation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Text("· \(confirmation.place)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(confirmation.text)
            .accessibilityIdentifier(ScreencastReviewID.confirmation)
            Button(action: showInFinder) {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(PalettePillButtonStyle(showsIcon: true))
            .help("Show the capture’s folder in Finder")
            .accessibilityIdentifier(ScreencastReviewID.showInFinder)
            Spacer()
            Button("Done", action: done)
                .buttonStyle(ScreencastReviewFilledButtonStyle(tint: .accentColor))
                .help("Close the window (Return)")
                .accessibilityIdentifier(ScreencastReviewID.done)
        }
    }
}

/// The recording's `AVPlayerView`, showing the selected display's video with its trim, or black
/// under the unit-test host.
private struct ScreencastReviewPlayer: View {
    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?

    var body: some View {
        if let playback {
            ScreencastReviewAVPlayerView(playback: playback)
                .onAppear { showCurrentVideo() }
                .onChange(of: model.selectedDisplay) { showCurrentVideo() }
                .onChange(of: model.trimRange) { showCurrentVideo() }
                .onChange(of: model.input) {
                    if let video = model.currentVideo { playback.reload(video) }
                }
        } else {
            Color.black
        }
    }

    private func showCurrentVideo() {
        guard let playback, let video = model.currentVideo else { return }
        playback.show(video, trim: model.trimRange)
    }
}

/// Puts the review's `AVPlayerView` in the SwiftUI layout.
private struct ScreencastReviewAVPlayerView: NSViewRepresentable {
    let playback: ScreencastReviewPlayback

    func makeNSView(context: Context) -> AVPlayerView { playback.view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
