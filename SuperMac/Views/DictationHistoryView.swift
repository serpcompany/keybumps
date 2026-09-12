import AppKit
import SwiftUI

struct DictationHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var audioPlayer = DictationAudioPlayer()
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Dictation History")
        .onAppear { model.dictationHistory.refresh() }
        .onDisappear { audioPlayer.stop() }
        .confirmationDialog(
            "Clear all dictation history?",
            isPresented: $showsClearConfirmation
        ) {
            Button("Clear All Recordings", role: .destructive) {
                audioPlayer.stop()
                model.dictationHistory.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every SuperMac recording directory, transcript, and audio file.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

            Button("Open Recordings Folder", systemImage: "folder") {
                NSWorkspace.shared.open(model.dictationHistory.recordingsDirectoryURL)
            }
            Button("Clear All", role: .destructive) {
                showsClearConfirmation = true
            }
            .disabled(model.dictationHistory.entries.isEmpty)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "waveform",
                    description: Text("Completed recordings will be saved here with their transcript and audio.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredEntries) { entry in
                        DictationHistoryCard(
                            entry: entry,
                            isPlaying: audioPlayer.activeEntryID == entry.id && audioPlayer.isPlaying,
                            progress: audioPlayer.progress(for: entry),
                            togglePlayback: { audioPlayer.toggle(entry) },
                            copy: { copy(entry.text) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL]) },
                            delete: {
                                if audioPlayer.activeEntryID == entry.id { audioPlayer.stop() }
                                model.dictationHistory.delete(entry)
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var filteredEntries: [DictationHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.dictationHistory.entries }
        return model.dictationHistory.entries.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func copy(_ text: String) {
        DictationHistoryClipboard.copy(text)
    }
}

enum DictationHistoryClipboard {
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

private struct DictationHistoryCard: View {
    let entry: DictationHistoryEntry
    let isPlaying: Bool
    let progress: Double
    let togglePlayback: () -> Void
    let copy: () -> Void
    let reveal: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(entry.audioURL == nil)
                .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Audio progress")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))

                Text(Self.durationFormatter.string(from: entry.duration) ?? "0:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 12) {
                Text(entry.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(Locale.current.localizedString(forIdentifier: entry.language) ?? entry.language)
                if entry.audioURL == nil {
                    Text("· Audio unavailable")
                }
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                Button(action: reveal) { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Reveal recording in Finder")
                    .accessibilityLabel("Reveal recording in Finder")
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete recording")
                    .accessibilityLabel("Delete recording")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
