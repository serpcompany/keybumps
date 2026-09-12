import AppKit
import Observation
import SwiftUI

enum CommandPaletteTab: String, CaseIterable, Identifiable {
    case search
    case clipboard
    case dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .clipboard: "Clipboard"
        case .dictation: "Dictation"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .clipboard: "clipboard"
        case .dictation: "waveform"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .search: "⌘1"
        case .clipboard: "⌘2"
        case .dictation: "⌘3"
        }
    }

    var prompt: String {
        switch self {
        case .search: "Search apps, files, and folders"
        case .clipboard: "Filter clipboard history"
        case .dictation: "Filter dictation history"
        }
    }
}

@MainActor
@Observable
final class CommandPaletteState {
    private(set) var tab: CommandPaletteTab = .search
    var historyQuery = ""
    var selection = 0

    func select(_ tab: CommandPaletteTab) {
        self.tab = tab
        historyQuery = ""
        selection = 0
    }
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private let search = QuickSearchModel()
    private let clipboard: ClipboardHistoryService
    private let dictationHistory: DictationHistoryService
    private let state = CommandPaletteState()
    private var panel: NSPanel?
    private weak var destination: NSRunningApplication?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?

    init(clipboard: ClipboardHistoryService, dictationHistory: DictationHistoryService) {
        self.clipboard = clipboard
        self.dictationHistory = dictationHistory
    }

    func toggle(_ tab: CommandPaletteTab) {
        if panel?.isVisible == true, state.tab == tab {
            dismiss()
        } else {
            show(tab)
        }
    }

    func show(_ tab: CommandPaletteTab) {
        if panel?.isVisible != true {
            destination = NSWorkspace.shared.frontmostApplication
        }
        if panel == nil { makePanel() }
        guard let panel else { return }

        state.select(tab)
        search.query = ""
        position(panel)
        installKeyMonitor()
        installOutsideMonitors()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusInput()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    func dismiss(ifDisplaying tab: CommandPaletteTab) {
        if panel?.isVisible == true, state.tab == tab {
            dismiss()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func makePanel() {
        let size = NSSize(width: 760, height: 520)
        let panel = CommandPalettePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: CommandPaletteView(
                state: state,
                search: search,
                clipboard: clipboard,
                dictationHistory: dictationHistory,
                selectTab: selectTab,
                activateSearchResult: open,
                revealSearchResult: reveal,
                pasteText: paste,
                dismiss: dismiss
            )
            .frame(width: size.width, height: size.height)
        )
        panel.setContentSize(size)
        self.panel = panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let x = screen.visibleFrame.midX - panel.frame.width / 2
        let y = screen.visibleFrame.maxY - panel.frame.height - 110
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func selectTab(_ tab: CommandPaletteTab) {
        state.select(tab)
        search.query = ""
        DispatchQueue.main.async { [weak self] in
            self?.focusInput()
        }
    }

    private func focusInput() {
        guard let panel,
              let field = firstEditableTextField(in: panel.contentView) else { return }
        panel.makeFirstResponder(field)
    }

    private func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled {
            return field
        }
        for subview in view.subviews {
            if let field = firstEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers {
                case "1": self.selectTab(.search); return nil
                case "2": self.selectTab(.clipboard); return nil
                case "3": self.selectTab(.dictation); return nil
                default: break
                }
            }

            switch event.keyCode {
            case 53:
                self.dismiss()
                return nil
            case 125:
                self.moveSelection(1)
                return nil
            case 126:
                self.moveSelection(-1)
                return nil
            case 36:
                self.activateSelection(reveal: event.modifierFlags.contains(.command))
                return nil
            default:
                return event
            }
        }
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if event.window !== self?.panel { self?.dismiss() }
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        removeOutsideMonitors()
    }

    private func removeOutsideMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }

    private func moveSelection(_ delta: Int) {
        let count = itemCount
        guard count > 0 else { return }
        state.selection = (state.selection + delta + count) % count
    }

    private var itemCount: Int {
        switch state.tab {
        case .search:
            search.results.count
        case .clipboard:
            filteredClipboard.count
        case .dictation:
            filteredDictations.count
        }
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clipboard.entries }
        return clipboard.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return dictationHistory.entries }
        return dictationHistory.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private func activateSelection(reveal: Bool) {
        switch state.tab {
        case .search:
            guard search.results.indices.contains(state.selection) else { return }
            let result = search.results[state.selection]
            reveal ? self.reveal(result) : open(result)
        case .clipboard:
            guard filteredClipboard.indices.contains(state.selection) else { return }
            paste(filteredClipboard[state.selection].text)
        case .dictation:
            guard filteredDictations.indices.contains(state.selection) else { return }
            paste(filteredDictations[state.selection].text)
        }
    }

    private func open(_ result: QuickSearchResult) {
        dismiss()
        NSWorkspace.shared.open(result.url)
    }

    private func reveal(_ result: QuickSearchResult) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    private func paste(_ text: String) {
        let target = destination
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        dismiss()
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let target,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

private struct CommandPaletteView: View {
    @Bindable var state: CommandPaletteState
    @Bindable var search: QuickSearchModel
    @Bindable var clipboard: ClipboardHistoryService
    @Bindable var dictationHistory: DictationHistoryService
    let selectTab: (CommandPaletteTab) -> Void
    let activateSearchResult: (QuickSearchResult) -> Void
    let revealSearchResult: (QuickSearchResult) -> Void
    let pasteText: (String) -> Void
    let dismiss: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaletteTabBar(selected: state.tab, select: selectTab)
            Divider().opacity(0.55)
            PaletteSearchField(
                tab: state.tab,
                searchQuery: $search.query,
                historyQuery: $state.historyQuery,
                focused: $inputFocused
            )
            Divider().opacity(0.55)
            content
            Divider().opacity(0.55)
            PaletteFooter(tab: state.tab)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
        .defaultFocus($inputFocused, true)
        .onChange(of: state.tab) {
            state.selection = 0
            inputFocused = true
        }
        .onChange(of: search.query) {
            state.selection = 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SuperMac command palette")
    }

    @ViewBuilder
    private var content: some View {
        switch state.tab {
        case .search:
            SearchResultsView(
                results: search.results,
                selection: state.selection,
                query: search.query,
                open: activateSearchResult,
                reveal: revealSearchResult
            )
        case .clipboard:
            ClipboardResultsView(
                entries: filteredClipboard,
                selection: state.selection,
                choose: pasteText,
                delete: clipboard.delete,
                clear: clipboard.clear
            )
        case .dictation:
            DictationResultsView(
                entries: filteredDictations,
                selection: state.selection,
                choose: pasteText,
                delete: dictationHistory.delete,
                clear: dictationHistory.clear
            )
        }
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clipboard.entries }
        return clipboard.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return dictationHistory.entries }
        return dictationHistory.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

private struct PaletteTabBar: View {
    let selected: CommandPaletteTab
    let select: (CommandPaletteTab) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CommandPaletteTab.allCases) { tab in
                Button {
                    select(tab)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                        Text(tab.title)
                        Text(tab.shortcutLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(selected == tab ? Color.white.opacity(0.11) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
            Spacer()
            Image("SuperMacArrow")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Palette tabs")
    }
}

private struct PaletteSearchField: View {
    let tab: CommandPaletteTab
    @Binding var searchQuery: String
    @Binding var historyQuery: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            if tab == .search {
                TextField(tab.prompt, text: $searchQuery)
                    .focused(focused)
            } else {
                TextField(tab.prompt, text: $historyQuery)
                    .focused(focused)
            }
            Text("esc")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .textFieldStyle(.plain)
        .font(.system(size: 23, weight: .medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

private struct SearchResultsView: View {
    let results: [QuickSearchResult]
    let selection: Int
    let query: String
    let open: (QuickSearchResult) -> Void
    let reveal: (QuickSearchResult) -> Void

    var body: some View {
        PaletteResultsContainer {
            if results.isEmpty {
                PaletteEmptyState(
                    title: query.isEmpty ? "Start typing to search your Mac" : "No local results",
                    systemImage: "magnifyingglass"
                )
            } else {
                ScrollViewReader { proxy in
                    List(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            open(result)
                        } label: {
                            HStack(spacing: 13) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                                    .resizable()
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(result.kind.rawValue) · \(result.detail)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if index == selection {
                                    Text("↩")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .listRowBackground(index == selection ? Color.accentColor.opacity(0.22) : Color.clear)
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(result) }
                        }
                        .id(result.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection) {
                        if results.indices.contains(selection) {
                            proxy.scrollTo(results[selection].id)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardResultsView: View {
    let entries: [ClipboardEntry]
    let selection: Int
    let choose: (String) -> Void
    let delete: (ClipboardEntry) -> Void
    let clear: () -> Void

    var body: some View {
        HistoryResultsContainer(
            entries: entries,
            selection: selection,
            emptyTitle: "No copied text yet",
            emptyImage: "clipboard",
            text: { $0.text },
            choose: { choose($0.text) },
            delete: delete,
            clear: clear,
            subtitle: { Text($0.capturedAt, style: .relative) }
        )
    }
}

private struct DictationResultsView: View {
    let entries: [DictationHistoryEntry]
    let selection: Int
    let choose: (String) -> Void
    let delete: (DictationHistoryEntry) -> Void
    let clear: () -> Void

    var body: some View {
        HistoryResultsContainer(
            entries: entries,
            selection: selection,
            emptyTitle: "Your dictated text will appear here",
            emptyImage: "waveform",
            text: { $0.text },
            choose: { choose($0.text) },
            delete: delete,
            clear: clear,
            subtitle: { entry in
                HStack(spacing: 5) {
                    Text(Locale.current.localizedString(forIdentifier: entry.language) ?? entry.language)
                    Text("·")
                    Text(entry.capturedAt, style: .relative)
                }
            }
        )
    }
}

private struct HistoryResultsContainer<Entry: Identifiable, Subtitle: View>: View {
    let entries: [Entry]
    let selection: Int
    let emptyTitle: String
    let emptyImage: String
    let text: (Entry) -> String
    let choose: (Entry) -> Void
    let delete: (Entry) -> Void
    let clear: () -> Void
    @ViewBuilder let subtitle: (Entry) -> Subtitle

    var body: some View {
        PaletteResultsContainer {
            if entries.isEmpty {
                PaletteEmptyState(title: emptyTitle, systemImage: emptyImage)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Recent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear History", systemImage: "trash", role: .destructive, action: clear)
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)

                    List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Button {
                                choose(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(text(entry))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    subtitle(entry)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                delete(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete history item \(index + 1)")
                        }
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .listRowBackground(index == selection ? Color.accentColor.opacity(0.22) : Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

}

private struct PaletteResultsContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.08))
    }
}

private struct PaletteEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PaletteFooter: View {
    let tab: CommandPaletteTab

    var body: some View {
        HStack(spacing: 14) {
            Label("Select", systemImage: "arrow.up.arrow.down")
            Label(tab == .search ? "Open" : "Paste", systemImage: "return")
            if tab == .search {
                Label("Reveal", systemImage: "command")
            }
            Spacer()
            Text("Local only")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
