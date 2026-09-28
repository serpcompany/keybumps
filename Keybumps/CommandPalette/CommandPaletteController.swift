import AppKit
import ImageIO
import Observation
import SwiftUI

enum CommandPaletteTab: String, CaseIterable, Identifiable {
    case search
    case clipboard
    case dictation
    case keyboardShortcutter
    case screenshots

    var id: String { rawValue }

    /// Tabs in Command-number order, as their owning modules register them.
    static var allCases: [CommandPaletteTab] { CapabilityCatalog.paletteTabs.map(\.tab) }

    private var registration: CapabilityPaletteTab { CapabilityCatalog.paletteTab(for: self).tab }
    /// The module that owns the tab.
    var owner: Capability { CapabilityCatalog.paletteTab(for: self).owner }
    var title: String { registration.name }
    var systemImage: String { registration.systemImage }
    var shortcutLabel: String { "⌘\(registration.commandKey)" }
    var prompt: String { registration.prompt }

    static func matchingCommandKey(_ characters: String?) -> CommandPaletteTab? {
        allCases.first { characters == String($0.registration.commandKey) }
    }

    var labelPresentation: CommandPaletteTabLabel {
        CommandPaletteTabLabel(shortcut: shortcutLabel, name: title)
    }

    var primaryActionTitle: String? { registration.primaryActionTitle }

    /// Shown in the footer after the primary action.
    var secondaryActionTitle: String? { registration.secondaryActionTitle }
}

/// What the Screenshots tab shows: only screen captures from Clipboard History.
enum ScreenshotPaletteContent: Equatable {
    case disabled
    case empty
    case entries([ClipboardEntry])

    static func resolve(entries: [ClipboardEntry], query: String, isEnabled: Bool) -> ScreenshotPaletteContent {
        guard isEnabled else { return .disabled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter { $0.isScreenshot && (trimmed.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(trimmed)) }
        return matches.isEmpty ? .empty : .entries(matches)
    }

    var entries: [ClipboardEntry] {
        guard case .entries(let entries) = self else { return [] }
        return entries
    }
}

struct CommandPaletteTabLabel: Equatable {
    let shortcut: String
    let name: String
}

enum KeyboardShortcutterHistoryContent: Equatable {
    case disabled
    case empty
    case entries([CoachingEvent])

    static func resolve(
        events: [CoachingEvent],
        query rawQuery: String,
        isEnabled: Bool
    ) -> KeyboardShortcutterHistoryContent {
        guard isEnabled else { return .disabled }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? events : events.filter {
            $0.actionTitle.localizedCaseInsensitiveContains(query)
                || $0.applicationName.localizedCaseInsensitiveContains(query)
                || $0.shortcut.localizedCaseInsensitiveContains(query)
        }
        return matches.isEmpty ? .empty : .entries(matches)
    }

    var entries: [CoachingEvent] {
        guard case .entries(let entries) = self else { return [] }
        return entries
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

final class CommandPalettePanel: NSPanel {
    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum CommandPaletteDismissalPolicy {
    static func shouldDismiss(isPresentingConfirmation: Bool) -> Bool {
        !isPresentingConfirmation
    }
}

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private let search = QuickSearchModel()
    private let clipboard: ClipboardHistoryService
    private let dictationHistory: DictationHistoryService
    private let dictationService: DictationService
    private let inbox: InboxStore
    private let preferences: AppPreferences
    private let state = CommandPaletteState()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var isPresentingConfirmation = false
    /// Set while Screenshot Tools is enabled; opens the markup editor for an image item.
    var editImage: ((ClipboardEntry) -> Bool)?

    init(
        clipboard: ClipboardHistoryService,
        dictationHistory: DictationHistoryService,
        dictationService: DictationService,
        inbox: InboxStore,
        preferences: AppPreferences
    ) {
        self.clipboard = clipboard
        self.dictationHistory = dictationHistory
        self.dictationService = dictationService
        self.inbox = inbox
        self.preferences = preferences
    }

    func toggle(_ tab: CommandPaletteTab) {
        if panel?.isVisible == true, state.tab == tab {
            dismiss()
        } else {
            show(tab)
        }
    }

    func show(_ tab: CommandPaletteTab) {
        if panel == nil { makePanel() }
        guard let panel else { return }

        state.select(tab)
        search.query = ""
        position(panel)
        installKeyMonitor()
        installOutsideMonitors()
        panel.hideDuringUnitTests()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusInput()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        isPresentingConfirmation = false
        removeMonitors()
    }

    func dismiss(ifDisplaying tab: CommandPaletteTab) {
        if panel?.isVisible == true, state.tab == tab {
            dismiss()
        }
    }

    func isDisplaying(_ tab: CommandPaletteTab) -> Bool {
        panel?.isVisible == true && state.tab == tab
    }

    func windowDidResignKey(_ notification: Notification) {
        if CommandPaletteDismissalPolicy.shouldDismiss(
            isPresentingConfirmation: isPresentingConfirmation
        ) {
            dismiss()
        }
    }

    private func makePanel() {
        let size = NSSize(width: 760, height: 520)
        let panel = CommandPalettePanel(contentRect: NSRect(origin: .zero, size: size))
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("commandPalette")
        panel.contentViewController = NSHostingController(
            rootView: CommandPaletteView(
                state: state,
                search: search,
                clipboard: clipboard,
                dictationHistory: dictationHistory,
                dictationService: dictationService,
                inbox: inbox,
                preferences: preferences,
                selectTab: selectTab,
                activateSearchResult: open,
                revealSearchResult: reveal,
                copyClipboardEntry: { [weak self] entry in self?.chooseClipboardEntry(entry) },
                chooseScreenshot: { [weak self] entry in self?.chooseScreenshot(entry) },
                copyDictationText: { [weak self] text in
                    self?.copy(text, suppressClipboardHistory: true)
                },
                confirmationPresentationChanged: { [weak self] isPresented in
                    self?.isPresentingConfirmation = isPresented
                },
                dismiss: dismiss
            )
            .frame(width: size.width, height: size.height)
            .uiTestAnimationsDisabled()
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
                if let tab = CommandPaletteTab.matchingCommandKey(event.charactersIgnoringModifiers) {
                    self.selectTab(tab)
                    return nil
                }
                if event.charactersIgnoringModifiers?.lowercased() == "e", self.state.tab == .clipboard || self.state.tab == .screenshots {
                    self.editSelectedClipboardImage()
                    return nil
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
            guard let self else { return event }
            if event.window !== self.panel,
               CommandPaletteDismissalPolicy.shouldDismiss(
                   isPresentingConfirmation: self.isPresentingConfirmation
               ) {
                self.dismiss()
            }
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
            search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? search.recentItems.items.count
                : search.results.count
        case .clipboard:
            filteredClipboard.count
        case .dictation:
            filteredDictations.count
        case .keyboardShortcutter:
            filteredKeyboardShortcutter.count
        case .screenshots:
            screenshotContent.entries.count
        }
    }

    private var screenshotContent: ScreenshotPaletteContent {
        ScreenshotPaletteContent.resolve(
            entries: clipboard.entries,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools)
        )
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clipboard.entries }
        return clipboard.entries.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        let reusableEntries = dictationHistory.entries.filter { !$0.text.isEmpty }
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return reusableEntries }
        return reusableEntries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var filteredKeyboardShortcutter: [CoachingEvent] {
        keyboardShortcutterContent.entries
    }

    private var keyboardShortcutterContent: KeyboardShortcutterHistoryContent {
        KeyboardShortcutterHistoryContent.resolve(
            events: inbox.events,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.keyboardShortcutter)
        )
    }

    private func activateSelection(reveal: Bool) {
        switch state.tab {
        case .search:
            if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard search.recentItems.items.indices.contains(state.selection) else { return }
                open(search.recentItems.items[state.selection].result)
                return
            }
            guard search.results.indices.contains(state.selection) else { return }
            let result = search.results[state.selection]
            reveal ? self.reveal(result) : open(result)
        case .clipboard:
            guard filteredClipboard.indices.contains(state.selection) else { return }
            copyClipboardEntry(filteredClipboard[state.selection])
        case .dictation:
            guard filteredDictations.indices.contains(state.selection) else { return }
            let text = filteredDictations[state.selection].text
            guard !text.isEmpty else { return }
            copy(text, suppressClipboardHistory: true)
        case .keyboardShortcutter:
            break
        case .screenshots:
            let entries = screenshotContent.entries
            guard entries.indices.contains(state.selection) else { return }
            if reveal {
                copyClipboardEntry(entries[state.selection])
            } else {
                editClipboardImage(entries[state.selection])
            }
        }
    }

    private func open(_ result: QuickSearchResult) {
        let didOpen = NSWorkspace.shared.open(result.url)
        search.recordOpenResult(result, succeeded: didOpen)
        if didOpen { dismiss() }
    }

    private func reveal(_ result: QuickSearchResult) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    private func copy(_ text: String, suppressClipboardHistory: Bool) {
        let pasteboard = NSPasteboard.keybumps
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        if suppressClipboardHistory { clipboard.suppressCurrentChange() }
        dismiss()
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        guard clipboard.restore(entry) else { return }
        dismiss()
    }

    /// Command-click edits an image; a plain click keeps restoring it.
    private func chooseClipboardEntry(_ entry: ClipboardEntry) {
        if NSEvent.modifierFlags.contains(.command), editClipboardImage(entry) { return }
        copyClipboardEntry(entry)
    }

    private func editSelectedClipboardImage() {
        let entries = state.tab == .screenshots ? screenshotContent.entries : filteredClipboard
        guard entries.indices.contains(state.selection) else { return }
        editClipboardImage(entries[state.selection])
    }

    /// In the Screenshots tab a click edits; Command-click copies.
    private func chooseScreenshot(_ entry: ClipboardEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            copyClipboardEntry(entry)
        } else {
            editClipboardImage(entry)
        }
    }

    @discardableResult
    private func editClipboardImage(_ entry: ClipboardEntry) -> Bool {
        guard entry.kind == .image, let editImage else { return false }
        dismiss()
        return editImage(entry)
    }
}

private struct CommandPaletteView: View {
    @Bindable var state: CommandPaletteState
    @Bindable var search: QuickSearchModel
    @Bindable var clipboard: ClipboardHistoryService
    @Bindable var dictationHistory: DictationHistoryService
    @Bindable var dictationService: DictationService
    @Bindable var inbox: InboxStore
    @Bindable var preferences: AppPreferences
    let selectTab: (CommandPaletteTab) -> Void
    let activateSearchResult: (QuickSearchResult) -> Void
    let revealSearchResult: (QuickSearchResult) -> Void
    let copyClipboardEntry: (ClipboardEntry) -> Void
    let chooseScreenshot: (ClipboardEntry) -> Void
    let copyDictationText: (String) -> Void
    let confirmationPresentationChanged: (Bool) -> Void
    let dismiss: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaletteSearchField(
                tab: state.tab,
                searchQuery: $search.query,
                historyQuery: $state.historyQuery,
                focused: $inputFocused
            )
            PaletteTabBar(selected: state.tab, select: selectTab)
            content
            Divider().opacity(0.35)
            PaletteFooter(tab: state.tab)
        }
        .background(PaletteTheme.background, in: RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous)
                .strokeBorder(PaletteTheme.border, lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: PaletteTheme.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
        .defaultFocus($inputFocused, true)
        .onChange(of: state.tab) {
            state.selection = 0
            inputFocused = true
        }
        .onChange(of: search.query) {
            state.selection = 0
        }
        .onChange(of: search.recentItems.items.map(\.id)) {
            guard state.tab == .search,
                  search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.selection >= search.recentItems.items.count else { return }
            state.selection = max(0, search.recentItems.items.count - 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keybumps command palette")
    }

    @ViewBuilder
    private var content: some View {
        switch state.tab {
        case .search:
            SearchResultsView(
                results: search.results,
                selection: state.selection,
                query: search.query,
                recentItems: search.recentItems.items,
                open: activateSearchResult,
                reveal: revealSearchResult,
                deleteRecentItem: search.recentItems.delete,
                clearRecentItems: search.recentItems.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .clipboard:
            ClipboardResultsView(
                entries: filteredClipboard,
                selection: state.selection,
                choose: copyClipboardEntry,
                showsEditHint: preferences.enabledCapabilities.contains(.screenshotTools),
                delete: clipboard.delete,
                clear: clipboard.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .dictation:
            DictationResultsView(
                entries: filteredDictations,
                selection: state.selection,
                select: { state.selection = $0 },
                choose: copyDictationText,
                transcribe: { entry in Task { await dictationService.transcribe(entry) } },
                retryingEntryID: dictationService.retryingEntryID,
                delete: dictationHistory.delete,
                clear: dictationHistory.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .keyboardShortcutter:
            KeyboardShortcutterResultsView(
                content: keyboardShortcutterContent,
                selection: state.selection,
                select: { state.selection = $0 },
                clear: inbox.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .screenshots:
            switch screenshotContent {
            case .disabled:
                PaletteResultsContainer {
                    PaletteEmptyState(title: "Screenshot Tools is turned off", systemImage: "camera.viewfinder")
                }
            case .empty:
                PaletteResultsContainer {
                    PaletteEmptyState(
                        title: state.historyQuery.isEmpty ? "Take a screenshot with ⇧⌘4 and it appears here" : "No matching screenshots",
                        systemImage: "camera.viewfinder"
                    )
                }
            case .entries(let entries):
                ClipboardResultsView(
                    entries: entries,
                    selection: state.selection,
                    choose: chooseScreenshot,
                    showsEditHint: false,
                    delete: clipboard.delete,
                    clear: clipboard.clearScreenshots,
                    confirmationPresentationChanged: confirmationPresentationChanged,
                    emptyTitle: "No screenshots yet",
                    clearTitle: "Clear screenshots?",
                    clearMessage: "This removes screenshots from Keybumps history. The screenshot files stay where macOS saved them."
                )
            }
        }
    }

    private var screenshotContent: ScreenshotPaletteContent {
        ScreenshotPaletteContent.resolve(
            entries: clipboard.entries,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools)
        )
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clipboard.entries }
        return clipboard.entries.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return dictationHistory.entries }
        return dictationHistory.entries.filter { $0.displayText.localizedCaseInsensitiveContains(query) }
    }

    private var keyboardShortcutterContent: KeyboardShortcutterHistoryContent {
        KeyboardShortcutterHistoryContent.resolve(
            events: inbox.events,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.keyboardShortcutter)
        )
    }
}

private struct PaletteTabBar: View {
    let selected: CommandPaletteTab
    let select: (CommandPaletteTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CommandPaletteTab.allCases) { tab in
                Button {
                    select(tab)
                } label: {
                    HStack(spacing: 7) {
                        ShortcutKeycaps(shortcut: tab.labelPresentation.shortcut, compact: true)
                        Text(tab.labelPresentation.name)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        selected == tab ? PaletteTheme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: PaletteTheme.rowRadius - 2, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
                .accessibilityIdentifier("palette.tab.\(tab.rawValue)")
            }
            Spacer()
            Image("KeybumpsArrow")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Palette tabs")
    }
}

private struct KeyboardShortcutterResultsView: View {
    let content: KeyboardShortcutterHistoryContent
    let selection: Int
    let select: (Int) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            switch content {
            case .disabled:
                PaletteEmptyState(title: "Keyboard Shortcutter is turned off", systemImage: "keyboard")
            case .empty:
                PaletteEmptyState(title: "No matching hotkeys", systemImage: "keyboard")
            case .entries(let entries):
                VStack(spacing: 0) {
                    HStack {
                        PaletteSectionHeader("Recent")
                        Spacer()
                        ClearAllButton(
                            confirmationTitle: "Clear Keyboard Shortcutter history?",
                            confirmationMessage: "This permanently removes all saved Keyboard Shortcutter events.",
                            disabled: entries.isEmpty,
                            confirmationPresentationChanged: confirmationPresentationChanged,
                            clear: clear
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                    List(Array(entries.enumerated()), id: \.element.id) { index, event in
                        Button { select(index) } label: {
                            CoachingEventRow(event: event)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
}

private struct PaletteSearchField: View {
    let tab: CommandPaletteTab
    @Binding var searchQuery: String
    @Binding var historyQuery: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            if tab == .search {
                TextField(tab.prompt, text: $searchQuery)
                    .focused(focused)
            } else {
                TextField(tab.prompt, text: $historyQuery)
                    .focused(focused)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 20))
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

private struct SearchResultsView: View {
    let results: [QuickSearchResult]
    let selection: Int
    let query: String
    let recentItems: [RecentItem]
    let open: (QuickSearchResult) -> Void
    let reveal: (QuickSearchResult) -> Void
    let deleteRecentItem: (RecentItem) -> Void
    let clearRecentItems: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if recentItems.isEmpty {
                    PaletteEmptyState(
                        title: "Start typing to search your Mac",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            PaletteSectionHeader("Recent Items")
                            Spacer()
                            ClearAllButton(
                                confirmationTitle: "Clear recent items?",
                                confirmationMessage: "This permanently removes your locally saved recently opened items.",
                                disabled: recentItems.isEmpty,
                                confirmationPresentationChanged: confirmationPresentationChanged,
                                clear: clearRecentItems
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                        List(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 10) {
                                Button { open(item.result) } label: {
                                    SearchResultRow(result: item.result)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { deleteRecentItem(item) } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete recent item \(item.result.name)")
                            }
                            .listRowInsets(.init())
                            .listRowSeparator(.hidden)
                            .paletteRowBackground(isSelected: index == selection)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            } else if results.isEmpty {
                PaletteEmptyState(
                    title: "No local results",
                    systemImage: "magnifyingglass"
                )
            } else {
                ScrollViewReader { proxy in
                    List(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            open(result)
                        } label: {
                            SearchResultRow(result: result)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
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

/// Raycast's result row: icon, name, gray detail on one line, and the kind on the right.
private struct SearchResultRow: View {
    let result: QuickSearchResult

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            Text(result.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            Text(result.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(result.kind.rawValue)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ClipboardResultsView: View {
    let entries: [ClipboardEntry]
    let selection: Int
    let choose: (ClipboardEntry) -> Void
    let showsEditHint: Bool
    let delete: (ClipboardEntry) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void
    var emptyTitle = "No clipboard items yet"
    var clearTitle = "Clear clipboard history?"
    var clearMessage = "This permanently removes all clipboard items and image previews saved by Keybumps."

    var body: some View {
        PaletteResultsContainer {
            if entries.isEmpty {
                PaletteEmptyState(title: emptyTitle, systemImage: "clipboard")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        PaletteSectionHeader("Recent")
                        Spacer()
                        ClearAllButton(
                            confirmationTitle: clearTitle,
                            confirmationMessage: clearMessage,
                            disabled: entries.isEmpty,
                            confirmationPresentationChanged: confirmationPresentationChanged,
                            clear: clear
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                    List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Button { choose(entry) } label: {
                                HStack(spacing: 12) {
                                    ClipboardEntryPreview(entry: entry)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.displayText)
                                            .lineLimit(entry.kind == .image ? 1 : 2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        HStack(spacing: 5) {
                                            Text(entry.kindLabel)
                                            Text("·")
                                            Text(entry.capturedAt, style: .relative)
                                            if showsEditHint, entry.kind == .image {
                                                Text("·")
                                                Text("⌘E to edit")
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) { delete(entry) } label: {
                                Image(systemName: "trash")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete history item \(index + 1)")
                        }
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
}

private struct ClipboardEntryPreview: View {
    let entry: ClipboardEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if entry.kind == .image, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: entry.kind == .image ? "photo" : "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 32)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel(entry.isScreenshot ? "Screenshot preview" : entry.kind == .image ? "Copied image preview" : "Copied text")
        .task(id: entry.mediaPath) {
            guard entry.kind == .image, let imageURL = entry.imageURL else {
                thumbnail = nil
                return
            }
            thumbnail = await Self.loadThumbnail(from: imageURL)
        }
    }

    private static func loadThumbnail(from url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: image, size: .zero)
        }.value
    }
}

private struct DictationResultsView: View {
    let entries: [DictationHistoryEntry]
    let selection: Int
    let select: (Int) -> Void
    let choose: (String) -> Void
    let transcribe: (DictationHistoryEntry) -> Void
    let retryingEntryID: String?
    let delete: (DictationHistoryEntry) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void
    @State private var audioPlayer = DictationAudioPlayer()

    var body: some View {
        PaletteResultsContainer {
            if entries.isEmpty {
                PaletteEmptyState(title: "Your dictated text will appear here", systemImage: "waveform")
            } else {
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 9) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    DictationHistoryCard(
                                        entry: entry,
                                        isExpanded: index == selection,
                                        isPlaying: audioPlayer.activeEntryID == entry.id && audioPlayer.isPlaying,
                                        progress: audioPlayer.progress(for: entry),
                                        playbackRate: audioPlayer.playbackRate,
                                        isTranscribing: retryingEntryID == entry.id,
                                        toggleExpansion: { select(index) },
                                        togglePlayback: { audioPlayer.toggle(entry) },
                                        setPlaybackRate: audioPlayer.setPlaybackRate,
                                        transcribe: { transcribe(entry) },
                                        primaryActionTitle: "Copy",
                                        primaryAction: entry.text.isEmpty ? nil : { choose(entry.text) },
                                        copy: { DictationHistoryClipboard.copy(entry.text) },
                                        reveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL]) },
                                        delete: {
                                            if audioPlayer.activeEntryID == entry.id { audioPlayer.stop() }
                                            delete(entry)
                                        }
                                    )
                                    .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                        .onChange(of: selection) {
                            guard entries.indices.contains(selection) else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(entries[selection].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .onDisappear { audioPlayer.stop() }
        .onChange(of: entries.map(\.id)) {
            if selection >= entries.count { select(max(0, entries.count - 1)) }
        }
    }
}

private struct PaletteResultsContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Raycast's footer: the tab's actions on the right, each with its keys.
private struct PaletteFooter: View {
    let tab: CommandPaletteTab

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            hint("Select", keys: ["↑", "↓"])
            if let primaryActionTitle = tab.primaryActionTitle {
                Divider().frame(height: 14)
                hint(primaryActionTitle, keys: ["↵"])
            }
            if let secondaryActionTitle = tab.secondaryActionTitle {
                Divider().frame(height: 14)
                hint(secondaryActionTitle, keys: ["⌘", "↵"])
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.primary)
            ForEach(keys, id: \.self) { PaletteKeycap($0) }
        }
    }
}
