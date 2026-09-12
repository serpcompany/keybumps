import AppKit
import AVFoundation
import SwiftUI
import Translation

struct DictationHistoryExpansion: Equatable {
    private(set) var expandedEntryID: String?

    mutating func toggle(_ entryID: String) {
        expandedEntryID = expandedEntryID == entryID ? nil : entryID
    }
}

struct DictationHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var audioPlayer = DictationAudioPlayer()
    @State private var expansion = DictationHistoryExpansion()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Dictation History")
        .onAppear {
            model.dictationHistory.refresh()
            if expansion.expandedEntryID == nil, let first = model.dictationHistory.entries.first {
                expansion.toggle(first.id)
            }
        }
        .onDisappear { audioPlayer.stop() }
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
            HistoryClearButton(
                title: "Clear History",
                confirmationTitle: "Clear all dictation history?",
                confirmationMessage: "This permanently removes every SuperMac recording directory, transcript, and audio file.",
                destructiveActionTitle: "Clear All Recordings",
                disabled: model.dictationHistory.entries.isEmpty
            ) {
                audioPlayer.stop()
                model.dictationHistory.clear()
            }
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
                            isExpanded: expansion.expandedEntryID == entry.id,
                            isPlaying: audioPlayer.activeEntryID == entry.id && audioPlayer.isPlaying,
                            progress: audioPlayer.progress(for: entry),
                            toggleExpansion: {
                                if expansion.expandedEntryID == entry.id,
                                   audioPlayer.activeEntryID == entry.id {
                                    audioPlayer.stop()
                                }
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expansion.toggle(entry.id)
                                }
                            },
                            togglePlayback: { audioPlayer.toggle(entry) },
                            primaryActionTitle: nil,
                            primaryAction: nil,
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

enum DictationTranslationPolicy {
    static func canTranslate(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func preferredTargetIdentifier(
        sourceIdentifier: String,
        supportedIdentifiers: [String]
    ) -> String? {
        let source = Locale.Language(identifier: sourceIdentifier)
        let preferred = source.languageCode?.identifier == "ja" ? "en" : "ja"
        return supportedIdentifiers.first(where: {
            Locale.Language(identifier: $0).languageCode?.identifier == preferred
        }) ?? supportedIdentifiers.first
    }
}

struct DictationHistoryCard: View {
    let entry: DictationHistoryEntry
    let isExpanded: Bool
    let isPlaying: Bool
    let progress: Double
    let toggleExpansion: () -> Void
    let togglePlayback: () -> Void
    let primaryActionTitle: String?
    let primaryAction: (() -> Void)?
    let copy: () -> Void
    let reveal: () -> Void
    let delete: () -> Void
    @State private var showsTranslation = false
    @State private var isHeaderHovered = false

    var body: some View {
        cardContent
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpansion) {
                HStack(alignment: .top, spacing: 12) {
                    Text(entry.displayText)
                        .font(isExpanded ? .title3 : .body)
                        .fontWeight(isExpanded ? .medium : .regular)
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    isHeaderHovered ? Color.white.opacity(0.055) : .clear,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") dictation")
            .accessibilityHint("Shows or hides this recording's audio and actions")

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Button(action: togglePlayback) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .disabled(entry.audioURL == nil)
                        .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")

                        RecordingWaveform(
                            audioURL: entry.audioURL,
                            progress: progress
                        )
                        .accessibilityLabel("Audio progress")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))

                        Text(Self.durationFormatter.string(from: entry.duration) ?? "0:00")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 12) {
                        Text("Original")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        if entry.audioURL == nil {
                            Text("Audio unavailable").foregroundStyle(.secondary)
                        }
                        if entry.metadata.transcriptionError != nil {
                            Text("Transcription failed").foregroundStyle(.orange)
                        }
                        Spacer()
                        if let primaryActionTitle, let primaryAction {
                            Button(primaryActionTitle, systemImage: "return", action: primaryAction)
                                .buttonStyle(.borderless)
                                .help("Paste transcript")
                                .accessibilityLabel("Paste transcript")
                        }
                        Button(action: copy) { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy transcript")
                            .accessibilityLabel("Copy transcript")
                        if #available(macOS 15.0, *) {
                            Button {
                                showsTranslation = true
                            } label: {
                                Image(systemName: "translate")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!DictationTranslationPolicy.canTranslate(entry.text))
                            .help("Translate transcript")
                            .accessibilityLabel("Translate transcript")
                        } else {
                            Button(action: {}) { Image(systemName: "translate") }
                                .buttonStyle(.borderless)
                                .disabled(true)
                                .help("On-device translation requires macOS 15 or newer")
                                .accessibilityLabel("Translation unavailable")
                        }
                        Button(action: reveal) { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .help("Reveal recording in Finder")
                            .accessibilityLabel("Reveal recording in Finder")
                        Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete recording")
                            .accessibilityLabel("Delete recording")
                    }
                    .font(.callout)

                    if showsTranslation {
                        if #available(macOS 15.0, *) {
                            LocalDictationTranslationView(
                                sourceText: entry.text,
                                sourceLanguageIdentifier: entry.language,
                                close: { showsTranslation = false }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            Text("On-device translation requires macOS 15 or newer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            isExpanded ? Color.white.opacity(0.105) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(isExpanded ? 0.10 : 0.045), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}

struct HistoryClearButton: View {
    let title: String
    let confirmationTitle: String
    let confirmationMessage: String
    let destructiveActionTitle: String
    let disabled: Bool
    var confirmationPresentationChanged: (Bool) -> Void = { _ in }
    let clear: () -> Void

    @State private var showsConfirmation = false

    var body: some View {
        Button(title, systemImage: "trash", role: .destructive) {
            showsConfirmation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(disabled)
        .onChange(of: showsConfirmation) {
            confirmationPresentationChanged(showsConfirmation)
        }
        .onDisappear {
            if showsConfirmation { confirmationPresentationChanged(false) }
        }
        .alert(confirmationTitle, isPresented: $showsConfirmation) {
            Button(destructiveActionTitle, role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}

@available(macOS 15.0, *)
private struct LocalDictationTranslationView: View {
    let sourceText: String
    let sourceLanguageIdentifier: String
    let close: () -> Void

    @State private var supportedTargets: [Locale.Language] = []
    @State private var targetIdentifier = ""
    @State private var translatedText: String?
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var speechPlayer = TranslatedSpeechPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Translate to", systemImage: "translate")
                    .font(.callout.weight(.semibold))
                Picker("Target language", selection: $targetIdentifier) {
                    ForEach(supportedTargets, id: \.minimalIdentifier) { language in
                        Text(displayName(for: language)).tag(language.minimalIdentifier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(supportedTargets.isEmpty || isTranslating)

                Button(isTranslating ? "Translating…" : "Translate") {
                    triggerTranslation()
                }
                .disabled(targetIdentifier.isEmpty || isTranslating)

                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close translation")
                    .accessibilityLabel("Close translation")
            }

            if supportedTargets.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading supported languages…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let translatedText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(translatedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        Button(
                            speechPlayer.isSpeaking ? "Stop Audio" : "Play Translation",
                            systemImage: speechPlayer.isSpeaking ? "stop.fill" : "speaker.wave.2.fill"
                        ) {
                            speechPlayer.toggle(
                                text: translatedText,
                                languageIdentifier: targetIdentifier
                            )
                        }
                        .buttonStyle(.borderless)

                        Button("Copy Translation", systemImage: "doc.on.doc") {
                            DictationHistoryClipboard.copy(translatedText)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let speechError = speechPlayer.lastError {
                Text(speechError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Translation runs on this Mac. A language model may need to be downloaded the first time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .task { await loadSupportedTargets() }
        .onChange(of: targetIdentifier) { _, _ in speechPlayer.stop() }
        .onDisappear { speechPlayer.stop() }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(sourceText)
                translatedText = response.targetText
                errorMessage = nil
            } catch {
                errorMessage = "Translation could not be completed. Check that the selected language model is available."
            }
            isTranslating = false
        }
    }

    private func triggerTranslation() {
        guard !targetIdentifier.isEmpty else { return }
        speechPlayer.stop()
        isTranslating = true
        translatedText = nil
        errorMessage = nil
        let source = Locale.Language(identifier: sourceLanguageIdentifier)
        let target = Locale.Language(identifier: targetIdentifier)
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func loadSupportedTargets() async {
        let source = Locale.Language(identifier: sourceLanguageIdentifier)
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        var compatible: [Locale.Language] = []
        for language in supported where !language.isEquivalent(to: source) {
            let status = await availability.status(from: source, to: language)
            if status != .unsupported { compatible.append(language) }
        }
        supportedTargets = compatible.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
        targetIdentifier = DictationTranslationPolicy.preferredTargetIdentifier(
            sourceIdentifier: sourceLanguageIdentifier,
            supportedIdentifiers: supportedTargets.map(\.minimalIdentifier)
        ) ?? ""
    }

    private func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}

private struct RecordingWaveform: View {
    let audioURL: URL?
    let progress: Double
    @State private var samples = Array(repeating: 0.22, count: 64)

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 2
            let barWidth = max(1, (size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))
            for (index, sample) in samples.enumerated() {
                let height = max(3, size.height * CGFloat(sample))
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                let normalizedPosition = Double(index + 1) / Double(samples.count)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(normalizedPosition <= progress ? .accentColor : .secondary.opacity(0.45))
                )
            }
        }
        .frame(height: 30)
        .task(id: audioURL) {
            guard let audioURL else { return }
            samples = await AudioWaveformSampler.samples(at: audioURL, count: samples.count)
        }
    }
}

private enum AudioWaveformSampler {
    static func samples(at audioURL: URL, count: Int) async -> [Double] {
        await Task.detached(priority: .utility) {
            guard count > 0,
                  let file = try? AVAudioFile(forReading: audioURL),
                  file.length > 0 else {
                return Array(repeating: 0.22, count: max(0, count))
            }

            let frameCount: AVAudioFrameCount = 2_048
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                return Array(repeating: 0.22, count: count)
            }

            var values: [Double] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let fraction = Double(index) / Double(max(1, count - 1))
                let position = min(
                    max(0, file.length - AVAudioFramePosition(frameCount)),
                    AVAudioFramePosition(Double(file.length) * fraction)
                )
                file.framePosition = position
                buffer.frameLength = 0
                try? file.read(into: buffer, frameCount: frameCount)
                guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else {
                    values.append(0.12)
                    continue
                }
                var peak: Float = 0
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channel[frame]))
                }
                values.append(Double(peak))
            }

            let maximum = values.max() ?? 0
            guard maximum > 0 else { return Array(repeating: 0.12, count: count) }
            return values.map { max(0.10, min(1, $0 / maximum)) }
        }.value
    }
}
