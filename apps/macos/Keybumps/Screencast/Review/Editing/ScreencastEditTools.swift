import SwiftUI

/// The recording window's tools (#517), in the bar's order, each with its number and letter keys.
/// Crop and Blur join Trim in #517's second part.
enum ScreencastEditTool: String, CaseIterable, Identifiable {
    case trim

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trim: "Trim"
        }
    }

    var systemImage: String {
        switch self {
        case .trim: "timeline.selection"
        }
    }

    /// Its letter, its other key.
    var key: String {
        switch self {
        case .trim: "t"
        }
    }

    /// Its number, in the bar's order from 1.
    var number: String { String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// The tool a number or letter picks, as the Screenshot Editor's do.
    static func matching(key: String) -> ScreencastEditTool? {
        let key = key.lowercased()
        return allCases.first { $0.number == key || $0.key == key }
    }
}

/// A time in the recording window: `m:ss`, or `h:mm:ss` from an hour, rounded down to the second.
enum ScreencastEditTime {
    static func format(_ seconds: Double) -> String {
        let total = ScreencastNumbers.int(seconds, in: 0...Int(Int32.max), fallback: 0)
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let rest = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}

/// The bar's left: the tools in the Screenshot Editor's well, each with its number in the corner and
/// filled with the accent color while picked, then the picked tool's options. Dimmed while the tools
/// wait: during an export, or while the bar asks something.
struct ScreencastEditToolsBar: View {
    let model: ScreencastReviewModel

    var body: some View {
        HStack(spacing: 14) {
            ScreengrabsEditorTools {
                ForEach(ScreencastEditTool.allCases) { tool in
                    ScreengrabsEditorToolButton(
                        title: tool.title,
                        systemImage: tool.systemImage,
                        number: tool.number,
                        key: tool.key,
                        isSelected: model.tool == tool
                    ) {
                        model.pick(tool)
                    }
                    .accessibilityIdentifier(ScreencastReviewID.tool(tool))
                }
            }
            .disabled(!model.acceptsEdits)
            .opacity(model.acceptsEdits ? 1 : 0.35)

            if model.tool == .trim {
                ScreencastTrimOptions(model: model)
                    .disabled(!model.acceptsEdits)
            }
        }
    }
}

/// Trim's options in the bar: Cut Section, on while part of the timeline is selected, the edited
/// length of the whole, and Reset Trim. Narrow, the buttons drop their titles.
struct ScreencastTrimOptions: View {
    static let cutKey = "⌫"

    let model: ScreencastReviewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            options(titled: true)
            options(titled: false)
        }
    }

    private func options(titled: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: model.cutSelection) {
                if titled {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors")
                        ScreengrabsEditorActionLabel(title: "Cut Section", key: Self.cutKey)
                    }
                } else {
                    Image(systemName: "scissors")
                }
            }
            .disabled(model.trimSelection == nil)
            .help("Cut the selected part out (⌫)")
            .accessibilityLabel("Cut Section")
            .accessibilityIdentifier(ScreencastReviewID.cutSection)

            lengthLabel
                .fixedSize()
                .accessibilityIdentifier(ScreencastReviewID.length)

            Button(action: model.resetTrim) {
                if titled { Text("Reset Trim") } else { Image(systemName: "arrow.counterclockwise") }
            }
            .disabled(!model.edits.isTrimmed)
            .help("Bring back the whole recording")
            .accessibilityLabel("Reset Trim")
            .accessibilityIdentifier(ScreencastReviewID.resetTrim)
        }
        .fixedSize()
    }

    private var lengthLabel: some View {
        let length = ScreencastEditTime.format(model.edits.length)
        let whole = ScreencastEditTime.format(model.edits.duration)
        return (Text("Length ") + Text(length).fontWeight(.semibold).foregroundColor(.primary) + Text(" of \(whole)"))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Length \(length) of \(whole)")
    }
}

/// The bar while Save or Copy writes the edited recording: how far it is, and that the original
/// stays until it's done.
struct ScreencastExportProgress: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Exporting edited recording…").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(Int((progress * 100).rounded(.down)))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text("The original stays until this finishes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 236)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(ScreencastReviewID.exportProgress)
    }
}

/// Over the player when the edited recording couldn't be written: what went wrong and what to do,
/// with Save Original and Try Again. The window stays open with the edits.
struct ScreencastExportFailureBanner: View {
    let failure: ScreencastExportFailure
    let saveOriginal: () -> Void
    let tryAgain: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.message).font(.system(size: 13, weight: .semibold))
                Text(failure.advice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .fixedSize()
            Button("Save Original", action: saveOriginal)
                .controlSize(.small)
                .accessibilityIdentifier(ScreencastReviewID.saveOriginal)
            Button("Try Again", action: tryAgain)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(ScreencastReviewID.tryAgain)
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ScreencastReviewID.exportFailure)
    }
}
