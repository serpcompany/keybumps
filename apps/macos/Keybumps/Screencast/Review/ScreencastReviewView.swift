import AppKit
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
    /// A recording's review window (#475), its player, and its sidebar.
    static let window = "screencast.review.window"
    static let playerArea = "screencast.review.playerArea"
    static let sidebar = "screencast.review.sidebar"
    /// What the window says once the recording is saved or copied, its Show in Finder, and Done.
    static let confirmation = "screencast.review.confirmation"
    static let showInFinder = "screencast.review.showInFinder"
    static let done = "screencast.review.done"
}

/// The review's text fields, which take the keyboard first.
enum ScreencastReviewField: Hashable {
    case note
    case repository
}

/// The review panel, for a screenshot: the screenshot with Edit, then the note, type, and
/// repository, the destination, and the actions. Laid out after Snapzy's quick-access card
/// (BSD-3-Clause, see LICENSE.snapzy), with the destination beside the send buttons, as Kap puts its
/// share menu by Export. A recording opens in a bigger window instead (`ScreencastRecordingReviewView`).
struct ScreencastReviewView: View {
    static let width: CGFloat = 400
    static let previewHeight: CGFloat = 207
    static let cornerRadius: CGFloat = 16

    @Bindable var model: ScreencastReviewModel

    @FocusState private var focus: ScreencastReviewField?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            screenshotPreview
            ScreencastReviewFields(model: model, focus: $focus)
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
    }

    // MARK: The screenshot

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
                    ScreencastReviewDisplayPicker(model: model)
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

    // MARK: Destination and actions

    private var destination: some View {
        HStack(spacing: 8) {
            ScreencastReviewDestination(model: model)
            Spacer()
            ScreencastReviewSendButtons(model: model)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.isConfirmingDiscard {
            ScreencastReviewDiscardQuestion(model: model)
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
                .help("Save, and copy the screenshot")
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

// MARK: Shared with a recording's window (`ScreencastRecordingReviewView`)

/// Which display's video or image shows, for a capture of every display.
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
            .help("Which display’s capture shows")
            .accessibilityLabel("Display")
            .accessibilityIdentifier(ScreencastReviewID.display)
        }
    }
}

/// The note, type, and repository.
struct ScreencastReviewFields: View {
    @Bindable var model: ScreencastReviewModel
    let focus: FocusState<ScreencastReviewField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Note", text: $model.note, prompt: Text("What happened?"))
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .note)
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
                    .focused(focus, equals: .repository)
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
}

/// Where Send goes: none until destinations come (#451).
struct ScreencastReviewDestination: View {
    let model: ScreencastReviewModel

    var body: some View {
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
    }
}

/// Send and Delete, and Save and Send, off until a destination is connected.
struct ScreencastReviewSendButtons: View {
    let model: ScreencastReviewModel

    var body: some View {
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

/// "Discard this capture?", with Keep and Discard, in place of the actions.
struct ScreencastReviewDiscardQuestion: View {
    let model: ScreencastReviewModel

    var body: some View {
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
    }
}

/// The length in a recording's player's corner, Snapzy's duration badge.
struct ScreencastReviewBadge: View {
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
struct ScreencastReviewFilledButtonStyle: ButtonStyle {
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
