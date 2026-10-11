import AppKit
import AVKit
import SwiftUI

/// The review panel's accessibility identifiers, which the UI tests drive.
enum ScreencastReviewID {
    static let panel = "screencast.review.panel"
    static let player = "screencast.review.player"
    static let image = "screencast.review.image"
    static let duration = "screencast.review.duration"
    static let display = "screencast.review.display"
    static let trim = "screencast.review.trim"
    static let edit = "screencast.review.edit"
    static let addToScreenshots = "screencast.review.addToScreenshots"
    static let note = "screencast.review.note"
    static let type = "screencast.review.type"
    static let repository = "screencast.review.repository"
    static let repositoryHint = "screencast.review.repositoryHint"
    static let destination = "screencast.review.destination"
    static let saveAndSend = "screencast.review.saveAndSend"
    static let sendAndDelete = "screencast.review.sendAndDelete"
    static let save = "screencast.review.save"
    static let copy = "screencast.review.copy"
    static let discard = "screencast.review.discard"
    /// Discard, answering "Discard this capture?".
    static let confirmDiscard = "screencast.review.confirmDiscard"
    static let keep = "screencast.review.keep"
    static let failure = "screencast.review.failure"
}

/// The review panel: the capture (a recording's player with its trim, or the screenshot with Edit),
/// then the note, type, and repository, the destination, and the actions. Laid out after Snapzy's
/// quick-access card (BSD-3-Clause, see LICENSE.snapzy), with the duration in the preview's corner,
/// and the destination beside the send buttons, as Kap puts its share menu by Export.
struct ScreencastReviewView: View {
    static let width: CGFloat = 400
    static let previewHeight: CGFloat = 207
    static let cornerRadius: CGFloat = 16

    @Bindable var model: ScreencastReviewModel
    /// The player, for a recording shown on screen; nil under the unit-test host.
    let playback: ScreencastReviewPlayback?

    private enum Field: Hashable { case note, repository }
    @FocusState private var focus: Field?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            preview
            fields
            destination
            if let failure = model.failure {
                Text(failure.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(ScreencastReviewID.failure)
            }
            actions
        }
        .padding(16)
        .frame(width: Self.width)
        .background(shape.fill(PaletteTheme.background))
        .overlay(shape.strokeBorder(PaletteTheme.border, lineWidth: 1))
        .clipShape(shape)
        .uiTestAnimationsDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review capture")
        .onAppear { focus = .note }
        .onChange(of: model.isWorking) { _, isWorking in
            if isWorking { playback?.pause() }
        }
    }

    // MARK: The capture

    @ViewBuilder private var preview: some View {
        if model.input.isVideo {
            videoPreview
        } else {
            screenshotPreview
        }
    }

    private var videoPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let playback {
                        ScreencastReviewPlayerView(playback: playback)
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
                .frame(height: Self.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let duration = model.durationText {
                    ScreencastReviewBadge(text: duration)
                        .accessibilityLabel("Length")
                        .accessibilityValue(duration)
                        .accessibilityIdentifier(ScreencastReviewID.duration)
                }
            }
            HStack(spacing: 8) {
                displayPicker
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
    }

    private var screenshotPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.black
                }
            }
            .frame(maxWidth: .infinity, maxHeight: Self.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Screenshot")
            .accessibilityIdentifier(ScreencastReviewID.image)
            if model.canEdit || model.showsAddToScreenshots || model.displayCount > 1 {
                HStack(spacing: 8) {
                    displayPicker
                    if model.showsAddToScreenshots {
                        Toggle("Also add to Screenshots (⌘3)", isOn: $model.addsToScreenshots)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 12))
                            .disabled(model.isWorking || model.isFinished)
                            .help("Saving also lists the screenshot in the Command Palette’s Screenshots tab")
                            .accessibilityIdentifier(ScreencastReviewID.addToScreenshots)
                    }
                    Spacer()
                    if model.canEdit { editButton }
                }
            }
        }
    }

    private var editButton: some View {
        Button(action: model.edit) {
            Label(model.isEditing ? "Editing…" : "Edit", systemImage: "pencil.tip.crop.circle")
        }
        .buttonStyle(PalettePillButtonStyle(showsIcon: true))
        .disabled(!model.acceptsActions)
        .help("Mark up or redact the screenshot in the Screenshot Editor")
        .accessibilityIdentifier(ScreencastReviewID.edit)
    }

    /// Which display's video or image shows, for a capture of every display.
    @ViewBuilder private var displayPicker: some View {
        if model.displayCount > 1 {
            Picker("Display", selection: $model.selectedDisplay) {
                ForEach(0..<model.displayCount, id: \.self) { index in
                    Text("\(index + 1)").tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Which display’s capture shows")
            .accessibilityLabel("Display")
            .accessibilityIdentifier(ScreencastReviewID.display)
        }
    }

    private func showCurrentVideo() {
        guard let playback, let video = model.currentVideo else { return }
        playback.show(video, trim: model.trimRange)
    }

    // MARK: Note, type, repository

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Note", text: $model.note, prompt: Text("What happened?"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .note)
                .accessibilityLabel("Note")
                .accessibilityIdentifier(ScreencastReviewID.note)

            Picker("Type", selection: $model.type) {
                ForEach(ScreencastReviewType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Type")
            .accessibilityIdentifier(ScreencastReviewID.type)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Repository", text: $model.repositoryText, prompt: Text("owner/name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .repository)
                    .accessibilityLabel("Repository")
                    .accessibilityIdentifier(ScreencastReviewID.repository)
                if let hint = model.repositoryHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier(ScreencastReviewID.repositoryHint)
                }
            }
        }
        .disabled(model.isWorking || model.isFinished)
    }

    // MARK: Destination and actions

    private var destination: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Destination")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(model.destinationTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Destination")
            .accessibilityValue(model.destinationTitle)
            .accessibilityIdentifier(ScreencastReviewID.destination)
            Spacer()
            Button("Send and Delete") {}
                .buttonStyle(PalettePillButtonStyle())
                .disabled(!model.canSend)
                .help("No destination is connected yet")
                .accessibilityIdentifier(ScreencastReviewID.sendAndDelete)
            Button("Save and Send") {}
                .buttonStyle(PalettePillButtonStyle())
                .disabled(!model.canSend)
                .help("No destination is connected yet")
                .accessibilityIdentifier(ScreencastReviewID.saveAndSend)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.isConfirmingDiscard {
            HStack(spacing: 8) {
                Text("Discard this capture?")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Keep", action: model.keep)
                    .buttonStyle(PalettePillButtonStyle())
                    .help("Keep the capture")
                    .accessibilityIdentifier(ScreencastReviewID.keep)
                Button("Discard", role: .destructive) {
                    Task { model.confirmDiscard() }
                }
                .buttonStyle(ScreencastReviewFilledButtonStyle(tint: .red))
                .help("Delete the capture and its folder")
                .accessibilityIdentifier(ScreencastReviewID.confirmDiscard)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Discard this capture?")
        } else {
            HStack(spacing: 8) {
                Button("Discard", role: .destructive, action: model.askToDiscard)
                    .buttonStyle(PalettePillButtonStyle())
                    .help("Delete this capture")
                    .accessibilityIdentifier(ScreencastReviewID.discard)
                Button("Copy") {
                    Task { await model.copy() }
                }
                .buttonStyle(PalettePillButtonStyle())
                .help(model.input.isVideo ? "Save, and copy the recording’s file" : "Save, and copy the screenshot")
                .accessibilityIdentifier(ScreencastReviewID.copy)
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving")
                }
                Button("Save") {
                    Task { await model.save() }
                }
                .buttonStyle(ScreencastReviewFilledButtonStyle(tint: .accentColor))
                .help("Keep the capture with its note (Return)")
                .accessibilityIdentifier(ScreencastReviewID.save)
            }
            .disabled(!model.acceptsActions)
        }
    }
}

/// The length in the preview's corner, Snapzy's duration badge.
private struct ScreencastReviewBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .padding(6)
            .allowsHitTesting(false)
    }
}

/// Save, and Discard answering the question: a filled capsule, in the pill buttons' size.
private struct ScreencastReviewFilledButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        ScreencastReviewFilledButton(configuration: configuration, tint: tint)
    }
}

private struct ScreencastReviewFilledButton: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule(style: .circular).fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Puts the panel's `AVPlayerView` in the SwiftUI layout.
private struct ScreencastReviewPlayerView: NSViewRepresentable {
    let playback: ScreencastReviewPlayback

    func makeNSView(context: Context) -> AVPlayerView { playback.view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
