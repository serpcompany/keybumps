import AppKit
import SwiftUI

/// The Dictation tab, in Raycast's list-and-detail layout: compact recordings on the left and the
/// highlighted recording's transcript, playback, information, and actions on the right.
struct DictationPaletteResults: View {
    let entries: [DictationHistoryEntry]
    let selection: Int
    let select: (Int) -> Void
    let choose: (String) -> Void
    let transcribe: (DictationHistoryEntry) -> Void
    let retryingEntryID: String?
    /// Delete, from the detail's button or the Delete key: asks first.
    let requestDelete: (DictationHistoryEntry) -> Void
    /// The confirmation's Delete.
    let delete: (DictationHistoryEntry) -> Void
    /// The recording whose Delete confirmation is showing.
    @Binding var pendingDeletion: DictationHistoryEntry?
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void
    @State private var audioPlayer = DictationAudioPlayer()

    /// The recordings the tab lists; shared with the controller so keyboard selection matches.
    static func filter(_ entries: [DictationHistoryEntry], query: String) -> [DictationHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.displayText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Your dictated text will appear here", systemImage: "waveform")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 330)
                    Rectangle()
                        .fill(PaletteTheme.border)
                        .frame(width: 1)
                    if entries.indices.contains(selection) {
                        detail(entries[selection])
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .onDisappear { audioPlayer.stop() }
        .alert(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    pendingDeletion = nil
                    confirmationPresentationChanged(false)
                }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                if audioPlayer.activeEntryID == entry.id { audioPlayer.stop() }
                delete(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its audio and transcript will be removed from this Mac.")
        }
        .onChange(of: entries.map(\.id)) {
            if let active = audioPlayer.activeEntryID, !entries.contains(where: { $0.id == active }) {
                audioPlayer.stop()
            }
            if selection >= entries.count { select(max(0, entries.count - 1)) }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                PaletteSectionHeader("Recent")
                Spacer()
                ClearAllButton(
                    confirmationTitle: "Clear all dictation history?",
                    confirmationMessage: "This permanently removes every Keybumps recording directory, transcript, and audio file.",
                    disabled: entries.isEmpty,
                    confirmationPresentationChanged: confirmationPresentationChanged
                ) {
                    audioPlayer.stop()
                    clear()
                }
                .buttonStyle(PalettePillButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button { select(index) } label: {
                        DictationPaletteRow(entry: entry, isTranscribing: retryingEntryID == entry.id)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if !entry.text.isEmpty { choose(entry.text) }
                    })
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
                    .paletteHoverHighlights(row: index)
                    .paletteRowBackground(isSelected: index == selection)
                    .id(entry.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .paletteScrollsToSelection(selection, proxy: proxy) { entries.indices.contains($0) ? entries[$0].id : nil }
            }
        }
    }

    private func detail(_ entry: DictationHistoryEntry) -> some View {
        DictationPaletteDetail(
            entry: entry,
            isPlaying: audioPlayer.activeEntryID == entry.id && audioPlayer.isPlaying,
            progress: audioPlayer.progress(for: entry),
            playbackRate: audioPlayer.playbackRate,
            isTranscribing: retryingEntryID == entry.id,
            togglePlayback: { audioPlayer.toggle(entry) },
            setPlaybackRate: audioPlayer.setPlaybackRate,
            copy: { choose(entry.text) },
            transcribe: { transcribe(entry) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL]) },
            delete: { requestDelete(entry) }
        )
        .id(entry.id)
    }
}

private struct DictationPaletteRow: View {
    let entry: DictationHistoryEntry
    let isTranscribing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(PaletteTheme.keycapFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(DictationHistoryCard.durationFormatter.string(from: entry.duration) ?? "0:00")
                        .monospacedDigit()
                    Text("·")
                    Text(entry.capturedAt, style: .relative)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        if isTranscribing { return "waveform.badge.magnifyingglass" }
        switch entry.state {
        case .failed, .interrupted: return "exclamationmark.triangle"
        default: return "waveform"
        }
    }

    private var tint: Color {
        entry.state == .failed || entry.state == .interrupted ? .orange : .secondary
    }
}

private struct DictationPaletteDetail: View {
    let entry: DictationHistoryEntry
    let isPlaying: Bool
    let progress: Double
    let playbackRate: Float
    let isTranscribing: Bool
    let togglePlayback: () -> Void
    let setPlaybackRate: (Float) -> Void
    let copy: () -> Void
    let transcribe: () -> Void
    let reveal: () -> Void
    let delete: () -> Void
    @State private var showsTranslation = false

    var body: some View {
        VStack(spacing: 0) { content }
    }

    @ViewBuilder private var content: some View {
        // The player and actions stay pinned at the top; only the transcript and details scroll,
        // so transcripts of any length never move them.
        VStack(alignment: .leading, spacing: 12) {
            DictationAudioTransportView(
                isPlaying: isPlaying,
                progress: progress,
                duration: entry.duration,
                playbackRate: playbackRate,
                hasAudio: entry.audioURL != nil,
                audioURL: entry.audioURL,
                togglePlayback: togglePlayback,
                setPlaybackRate: setPlaybackRate
            )
            actions
        }
        .padding([.horizontal, .top], 18)
        .padding(.bottom, 12)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.displayText)
                    .font(.system(size: 15))
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsTranslation, #available(macOS 15.0, *) {
                    LocalDictationTranslationView(
                        sourceText: entry.text,
                        recordedLanguageIdentifier: entry.language,
                        close: { showsTranslation = false }
                    )
                }

                information
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if entry.canTranscribe || isTranscribing {
                Button(isTranscribing ? "Transcribing…" : "Transcribe", systemImage: "waveform.badge.magnifyingglass", action: transcribe)
                    .disabled(isTranscribing)
            }
            if !entry.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc", action: copy)
            }
            if #available(macOS 15.0, *), DictationTranslationPolicy.canTranslate(entry.text) {
                Button("Translate", systemImage: "translate") { showsTranslation.toggle() }
            }
            Button("Show in Finder", systemImage: "folder", action: reveal)
            Spacer(minLength: 0)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                .help("Delete (⌫)")
        }
        .buttonStyle(PalettePillButtonStyle(showsIcon: true))
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaletteSectionHeader("Information")
                .padding(.bottom, 6)
            row("Recorded", entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
            row("Duration", DictationHistoryCard.durationFormatter.string(from: entry.duration) ?? "0:00")
            row("Language", Locale.current.localizedString(forIdentifier: entry.language) ?? entry.language)
            row("Status", status)
        }
    }

    private var status: String {
        if isTranscribing { return "Transcribing…" }
        switch entry.state {
        case .completed: return entry.audioURL == nil ? "Transcribed · audio unavailable" : "Transcribed"
        case .failed: return "Transcription failed"
        case .interrupted: return "Recording interrupted"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing…"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(PaletteTheme.border).frame(height: 1)
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).foregroundStyle(.primary)
            }
            .font(.system(size: 13))
            .padding(.vertical, 8)
        }
    }
}
