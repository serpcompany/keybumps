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

    /// The tabs in the tab bar. The Hotkeys tab is hidden unless the owner shows it, or it is open.
    static func visibleTabs(showsHotkeys: Bool, selected: CommandPaletteTab) -> [CommandPaletteTab] {
        allCases.filter { $0 != .keyboardShortcutter || showsHotkeys || $0 == selected }
    }

    static func matchingCommandKey(_ characters: String?, in tabs: [CommandPaletteTab] = allCases) -> CommandPaletteTab? {
        tabs.first { characters == String($0.registration.commandKey) }
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
    private let hud = PaletteHUD.shared
    /// Set while Screenshot Tools is enabled; opens the markup editor for an image item.
    var editImage: ((ClipboardEntry) -> Bool)?
    /// Opens Settings. The app shell sets it to the status menu's route.
    var openSettings: () -> Void = {}

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

    /// Runs a Keybumps command from its Quick Search row, the footer's Settings button, or its
    /// Command-key shortcut in any tab. The palette closes first.
    func run(_ command: QuickSearchCommand) {
        dismiss()
        switch command {
        case .keybumpsSettings: openSettings()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if CommandPaletteDismissalPolicy.shouldDismiss(
            isPresentingConfirmation: isPresentingConfirmation
        ) {
            dismiss()
        }
    }

    private func makePanel() {
        let size = NSSize(width: 1040, height: 635)
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
                runCommand: { [weak self] command in self?.run(command) },
                chooseClipboardEntry: { [weak self] entry in self?.chooseClipboardEntry(entry) },
                copyClipboardEntry: { [weak self] entry in self?.copyClipboardEntry(entry) },
                editClipboardEntry: { [weak self] entry in _ = self?.editClipboardImage(entry) },
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
                let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: self.preferences.showsHotkeysTab, selected: self.state.tab)
                if let tab = CommandPaletteTab.matchingCommandKey(event.charactersIgnoringModifiers, in: tabs) {
                    self.selectTab(tab)
                    return nil
                }
                if let command = QuickSearchCommand.matchingCommandKey(event.charactersIgnoringModifiers) {
                    self.run(command)
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
                self.moveSelection(self.state.tab == .screenshots ? ScreenshotGrid.columnCount : 1)
                return nil
            case 126:
                self.moveSelection(self.state.tab == .screenshots ? -ScreenshotGrid.columnCount : -1)
                return nil
            case 123, 124:
                // Left and Right move through the screenshot grid; elsewhere they move the caret.
                guard self.state.tab == .screenshots, self.activeQuery.isEmpty else { return event }
                self.moveSelection(event.keyCode == 124 ? 1 : -1)
                return nil
            case 36:
                self.activateSelection(reveal: event.modifierFlags.contains(.command))
                return nil
            case 51, 117:
                // Delete removes the highlighted row once the search field is empty (or with Command).
                guard self.activeQuery.isEmpty || event.modifierFlags.contains(.command),
                      self.deleteSelection() else { return event }
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
        if abs(delta) > 1 {
            // Moving a grid row stops at the edges instead of wrapping to another column.
            let target = state.selection + delta
            guard (0..<count).contains(target) else { return }
            state.selection = target
        } else {
            state.selection = (state.selection + delta + count) % count
        }
    }

    private var itemCount: Int {
        switch state.tab {
        case .search:
            search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? search.recentItems.items.count
                : search.items.count
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

    private var activeQuery: String {
        state.tab == .search ? search.query : state.historyQuery
    }

    /// Deletes the highlighted row in the tabs where Delete removes items.
    private func deleteSelection() -> Bool {
        let index = state.selection
        switch state.tab {
        case .search:
            guard search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  search.recentItems.items.indices.contains(index) else { return false }
            search.recentItems.delete(search.recentItems.items[index])
        case .clipboard:
            guard filteredClipboard.indices.contains(index) else { return false }
            clipboard.delete(filteredClipboard[index])
        case .screenshots:
            let entries = screenshotContent.entries
            guard entries.indices.contains(index) else { return false }
            clipboard.delete(entries[index])
        case .dictation:
            guard filteredDictations.indices.contains(index) else { return false }
            dictationHistory.delete(filteredDictations[index])
        case .keyboardShortcutter:
            return false
        }
        state.selection = min(index, max(0, itemCount - 1))
        return true
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
        return clipboard.entries.filter { $0.matches(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        DictationPaletteResults.filter(dictationHistory.entries, query: state.historyQuery)
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
            guard search.items.indices.contains(state.selection) else { return }
            switch search.items[state.selection] {
            case .command(let command):
                run(command)
            case .result(let result):
                reveal ? self.reveal(result) : open(result)
            }
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
        confirmCopy()
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        guard clipboard.restore(entry) else { return }
        confirmCopy()
    }

    /// Closes the palette and confirms the copy at the notch.
    private func confirmCopy() {
        dismiss()
        hud.show("Copied to Clipboard")
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
    let runCommand: (QuickSearchCommand) -> Void
    /// A click: Command-click edits an image, anything else copies.
    let chooseClipboardEntry: (ClipboardEntry) -> Void
    /// Always copies, whatever keys are held (the context menu's Copy).
    let copyClipboardEntry: (ClipboardEntry) -> Void
    let editClipboardEntry: (ClipboardEntry) -> Void
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
            PaletteTabBar(
                tabs: CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab),
                selected: state.tab,
                select: selectTab
            )
            content
                .contentMargins(.bottom, 56, for: .scrollContent)
                .overlay(alignment: .bottom) {
                    PaletteFooter(tab: state.tab, openSettings: { runCommand(.keybumpsSettings) })
                }
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
                items: search.items,
                selection: state.selection,
                query: search.query,
                recentItems: search.recentItems.items,
                open: activateSearchResult,
                reveal: revealSearchResult,
                run: runCommand,
                deleteRecentItem: search.recentItems.delete,
                clearRecentItems: search.recentItems.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .clipboard:
            ClipboardResultsView(
                entries: filteredClipboard,
                selection: state.selection,
                choose: chooseClipboardEntry,
                copy: copyClipboardEntry,
                edit: preferences.enabledCapabilities.contains(.screenshotTools) ? editClipboardEntry : nil,
                delete: clipboard.delete,
                clear: clipboard.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        case .dictation:
            DictationPaletteResults(
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
                ScreenshotGrid(
                    entries: entries,
                    selection: state.selection,
                    select: { state.selection = $0 },
                    choose: chooseScreenshot,
                    delete: clipboard.delete,
                    clear: clipboard.clearScreenshots,
                    confirmationPresentationChanged: confirmationPresentationChanged
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
        return clipboard.entries.filter { $0.matches(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        DictationPaletteResults.filter(dictationHistory.entries, query: state.historyQuery)
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
    let tabs: [CommandPaletteTab]
    let selected: CommandPaletteTab
    let select: (CommandPaletteTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    select(tab)
                } label: {
                    HStack(spacing: 7) {
                        PaletteKeycaps(shortcut: tab.labelPresentation.shortcut)
                        Text(tab.labelPresentation.name)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
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
            Image(ProductIdentity.inAppBrandImageName)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 18)
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
                PaletteEmptyState(title: "Shortcut Coach is turned off", systemImage: "keyboard")
            case .empty:
                PaletteEmptyState(title: "No matching hotkeys", systemImage: "keyboard")
            case .entries(let entries):
                VStack(spacing: 0) {
                    HStack {
                        PaletteSectionHeader("Recent")
                        Spacer()
                        ClearAllButton(
                            confirmationTitle: "Clear Shortcut Coach history?",
                            confirmationMessage: "This permanently removes all saved Shortcut Coach events.",
                            disabled: entries.isEmpty,
                            confirmationPresentationChanged: confirmationPresentationChanged,
                            clear: clear
                        )
                        .buttonStyle(PalettePillButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    List(Array(entries.enumerated()), id: \.element.id) { index, event in
                        Button { select(index) } label: {
                            CoachingEventRow(event: event)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
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
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            if tab == .search {
                TextField(tab.prompt, text: $searchQuery)
                    .focused(focused)
            } else {
                TextField(tab.prompt, text: $historyQuery)
                    .focused(focused)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 22))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private struct SearchResultsView: View {
    let items: [QuickSearchItem]
    let selection: Int
    let query: String
    let recentItems: [RecentItem]
    let open: (QuickSearchResult) -> Void
    let reveal: (QuickSearchResult) -> Void
    let run: (QuickSearchCommand) -> Void
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
                            .buttonStyle(PalettePillButtonStyle())
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                        // No per-row trash button: Delete removes the highlighted Recent Item, and the
                        // context menu and VoiceOver's Delete action cover mouse and VoiceOver users.
                        List(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                            Button { open(item.result) } label: {
                                SearchResultRow(result: item.result)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") { open(item.result) }
                                Button("Reveal in Finder") { reveal(item.result) }
                                Divider()
                                Button("Delete", role: .destructive) { deleteRecentItem(item) }
                            }
                            .accessibilityAction(named: "Delete") { deleteRecentItem(item) }
                            .listRowInsets(.init())
                            .listRowSeparator(.hidden)
                            .paletteRowBackground(isSelected: index == selection)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            } else if items.isEmpty {
                PaletteEmptyState(
                    title: "No local results",
                    systemImage: "magnifyingglass"
                )
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .command(let command):
                                Button {
                                    run(command)
                                } label: {
                                    QuickSearchCommandRow(command: command)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("quickSearch.command.\(command.rawValue)")
                            case .result(let result):
                                Button {
                                    open(result)
                                } label: {
                                    SearchResultRow(result: result)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Reveal in Finder") { reveal(result) }
                                }
                            }
                        }
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection) {
                        if items.indices.contains(selection) {
                            proxy.scrollTo(items[selection].id)
                        }
                    }
                }
            }
        }
    }
}

/// Raycast's result row: icon, name, and the kind on the right. Apps show no path; files and
/// folders show only their enclosing folder's name. The full path is in the tooltip.
private struct SearchResultRow: View {
    let result: QuickSearchResult

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                .resizable()
                .frame(width: 28, height: 28)
            Text(result.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if result.kind != .application {
                Text(result.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(result.kind.rawValue)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .help(result.detail)
    }
}

/// A Keybumps command in Raycast's row: the Keybumps icon, the name, then its shortcut and kind on
/// the right.
private struct QuickSearchCommandRow: View {
    let command: QuickSearchCommand

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 28, height: 28)
            Text(command.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            PaletteKeycaps(shortcut: command.shortcut)
            Text(command.kindLabel)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ClipboardResultsView: View {
    let entries: [ClipboardEntry]
    let selection: Int
    let choose: (ClipboardEntry) -> Void
    let copy: (ClipboardEntry) -> Void
    /// Opens an image in the Screenshot Editor; nil while Screenshot Tools is off.
    let edit: ((ClipboardEntry) -> Void)?
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
                        .buttonStyle(PalettePillButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    // No per-row trash button: Delete (or ⌘⌫ while typing) removes the selected row,
                    // and the context menu and VoiceOver's Delete action cover mouse and VoiceOver users.
                    List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button { choose(entry) } label: {
                            ClipboardRow(
                                entry: entry,
                                showsEditHint: edit != nil && index == selection && entry.kind == .image
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy") { copy(entry) }
                            if let edit, entry.kind == .image {
                                Button("Edit") { edit(entry) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { delete(entry) }
                        }
                        .accessibilityAction(named: "Delete") { delete(entry) }
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

/// Raycast's row for a clipboard item. The preview (a thumbnail, or a text symbol) shows the item's
/// kind, so no kind word is shown. The content fills the middle, with when it was copied in small
/// gray text under it. Where it came from sits right-aligned in gray, like Raycast's accessories, capped so it
/// never squeezes the content.
struct ClipboardRow: View {
    /// Wide enough for a typical app name and domain side by side; longer ones truncate.
    static let accessoryMaxWidth: CGFloat = 360

    let entry: ClipboardEntry
    /// Only the selected image row shows ⌘E, since the footer doesn't list it.
    let showsEditHint: Bool

    var body: some View {
        HStack(spacing: 14) {
            ClipboardEntryPreview(entry: entry)
            VStack(alignment: .leading, spacing: 3) {
                ClipboardEntryTitle(entry: entry)
                Text(ClipboardRowPresentation.timestamp(entry.capturedAt))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    // The fixed month-first text would read as another date to day-first listeners.
                    .accessibilityLabel(ClipboardRowPresentation.spokenTimestamp(entry.capturedAt))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Right to left: the app icon column, the app name, the domain, then Edit ⌘E on the
            // selected image row. Only the name and domain give way when space runs out.
            HStack(spacing: 10) {
                HStack(spacing: 14) {
                    if showsEditHint {
                        HStack(spacing: 6) {
                            Text("Edit").fixedSize()
                            HStack(spacing: 3) {
                                PaletteKeycap("⌘")
                                PaletteKeycap("E")
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Edit with Command-E")
                    }
                    if let domain = entry.sourceDomain {
                        ClipboardSourceDomainLabel(domain: domain)
                    }
                    if let sourceApp = entry.sourceApp {
                        ClipboardSourceAppLabel(app: sourceApp)
                    }
                }
                .lineLimit(1)
                // The palette's right-aligned accessory size, as in Quick Search's rows.
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                ClipboardSourceAppIcon(app: entry.sourceApp)
            }
            .frame(maxWidth: Self.accessoryMaxWidth, alignment: .trailing)
            .layoutPriority(1)
        }
    }
}

/// The right-hand icon column: the source app's icon at one fixed size, or empty space of the same
/// size (no source app, or an app this Mac doesn't have), so names and domains line up across rows.
struct ClipboardSourceAppIcon: View {
    static let size: CGFloat = 24

    let app: ClipboardSourceApp?

    var body: some View {
        Group {
            if let app, let icon = ClipboardSourceAppIcons.icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .help("Copied from \(app.name)")
            } else {
                Color.clear
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// A clipboard item's content on one line, so every row is the same height: its text, or an image's
/// file name. An image copied from an app has no name, so it shows its pixel size instead of the
/// word "Image".
private struct ClipboardEntryTitle: View {
    let entry: ClipboardEntry
    @State private var pixelSize: String?

    var body: some View {
        Text(ClipboardRowPresentation.title(for: entry, pixelSize: pixelSize))
            .font(.system(size: 15))
            .lineLimit(1)
            .truncationMode(.tail)
            .task(id: entry.mediaPath) {
                guard entry.kind == .image, entry.sourceURL == nil, let imageURL = entry.imageURL else {
                    pixelSize = nil
                    return
                }
                pixelSize = await Task.detached(priority: .utility) {
                    ClipboardRowPresentation.pixelSize(ofImageAt: imageURL)
                }.value
            }
    }
}

/// What a Clipboard tab row shows, and says to VoiceOver, for an item.
enum ClipboardRowPresentation {
    /// The row's content: the text on one line, a file's name, or an unnamed image's pixel size once known.
    static func title(for entry: ClipboardEntry, pixelSize: String?) -> String {
        switch entry.kind {
        case .text:
            return singleLine(entry.text)
        case .image:
            guard entry.sourceURL == nil, let pixelSize else { return entry.displayText }
            return pixelSize
        }
    }

    /// Text for a one-line row: runs of spaces, tabs, and newlines become single spaces, so a
    /// multi-line copy reads as one line instead of showing only its first line. Only the start is
    /// read, since one line shows little of a long copy.
    static func singleLine(_ text: String) -> String {
        text.prefix(500).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// When an item was copied, always the same width so timestamps line up down the column:
    /// "09/03/2026 @ 03:37", or "09/03/2026 @ 03:37 PM" when the user's clock is 12-hour. It's fixed
    /// text, not a live counter.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// The same moment for VoiceOver, in the user's own date and time format.
    static func spokenTimestamp(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    /// One shared formatter, not one per row. It reads the 12/24-hour preference when first used.
    private static let timestampFormatter = makeTimestampFormatter()

    /// A 2-digit month and day, a 4-digit year, " @ ", and a 2-digit hour and minute, with a
    /// fixed-width AM/PM on a 12-hour clock. `en_US_POSIX` keeps every part the same in any locale.
    static func makeTimestampFormatter(
        usesTwentyFourHourClock: Bool = usesTwentyFourHourClock(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = usesTwentyFourHourClock ? "MM/dd/yyyy '@' HH:mm" : "MM/dd/yyyy '@' hh:mm a"
        return formatter
    }

    /// Whether the user's clock is 24-hour: the locale's preferred hour pattern has no AM/PM.
    static func usesTwentyFourHourClock(locale: Locale = .current) -> Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }

    /// An image file's pixel size, such as "1280 × 720", read from its header without decoding it.
    static func pixelSize(ofImageAt url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    /// The item's kind for VoiceOver. The row shows it only as the preview.
    static func accessibilityKind(of entry: ClipboardEntry) -> String {
        entry.isScreenshot ? "Screenshot" : entry.kind == .image ? "Copied image" : "Copied text"
    }
}

/// The name of the app a clipboard item was copied from. Its icon sits in the row's icon column,
/// to the right (`ClipboardSourceAppIcon`).
struct ClipboardSourceAppLabel: View {
    let app: ClipboardSourceApp

    var body: some View {
        Text(app.name)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Copied from \(app.name)")
            .accessibilityLabel("Copied from \(app.name)")
    }
}

/// The website a clipboard item was copied from, as its domain. A long domain loses its start, so
/// the registrable end (for example `example.com`) stays visible.
struct ClipboardSourceDomainLabel: View {
    let domain: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(domain)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .help("Copied from a page on \(domain)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Website \(domain)")
    }
}

/// App icons for source apps, looked up once per bundle identifier (including misses).
@MainActor
enum ClipboardSourceAppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for app: ClipboardSourceApp) -> NSImage? {
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleIdentifier] = icon
        return icon
    }
}

private struct ClipboardEntryPreview: View {
    /// A text item's preview: lines of text, not a document.
    static let textSymbol = "text.alignleft"

    let entry: ClipboardEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if entry.kind == .image, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: entry.kind == .image ? "photo" : ClipboardEntryPreview.textSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 38)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel(ClipboardRowPresentation.accessibilityKind(of: entry))
        .task(id: entry.mediaPath) {
            guard entry.kind == .image, let imageURL = entry.imageURL else {
                thumbnail = nil
                return
            }
            thumbnail = await Self.loadThumbnail(from: imageURL, maxPixelSize: 160)
        }
    }

    static func loadThumbnail(from url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
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

/// Raycast's Search Screenshots: a grid of large thumbnails with the name and age underneath,
/// so screenshots are recognizable at a glance. Arrow keys move through the grid.
private struct ScreenshotGrid: View {
    static let columnCount = 3

    let entries: [ClipboardEntry]
    let selection: Int
    let select: (Int) -> Void
    let choose: (ClipboardEntry) -> Void
    let delete: (ClipboardEntry) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            VStack(spacing: 0) {
                HStack {
                    PaletteSectionHeader("Recent")
                    Spacer()
                    ClearAllButton(
                        confirmationTitle: "Clear screenshots?",
                        confirmationMessage: "This removes screenshots from Keybumps history. The screenshot files stay where macOS saved them.",
                        disabled: entries.isEmpty,
                        confirmationPresentationChanged: confirmationPresentationChanged,
                        clear: clear
                    )
                    .buttonStyle(PalettePillButtonStyle())
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columnCount),
                            spacing: 14
                        ) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ScreenshotCard(
                                    entry: entry,
                                    isSelected: index == selection,
                                    choose: { select(index); choose(entry) },
                                    delete: { delete(entry) }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) {
                        guard entries.indices.contains(selection) else { return }
                        proxy.scrollTo(entries[selection].id)
                    }
                }
            }
        }
    }
}

private struct ScreenshotCard: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let choose: () -> Void
    let delete: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: choose) {
                ZStack {
                    PaletteTheme.keycapFill
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : PaletteTheme.border, lineWidth: isSelected ? 3 : 1))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if isHovering || isSelected {
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                        .buttonStyle(PalettePillButtonStyle(isCircular: true))
                        .padding(8)
                        .help("Delete (⌫)")
                        .accessibilityLabel("Delete screenshot \(entry.displayText)")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.capturedAt, style: .relative)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: entry.mediaPath) {
            guard let imageURL = entry.imageURL else { return }
            thumbnail = await ClipboardEntryPreview.loadThumbnail(from: imageURL, maxPixelSize: 640)
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

/// Raycast's footer: a round Settings button at the bottom left, and a floating pill at the bottom
/// right with the tab's actions and their keys.
private struct PaletteFooter: View {
    let tab: CommandPaletteTab
    let openSettings: () -> Void

    var body: some View {
        HStack {
            PaletteSettingsButton(action: openSettings)
            Spacer()
            HStack(spacing: 14) {
                hint("Select", keys: tab == .screenshots ? ["←", "→", "↑", "↓"] : ["↑", "↓"], isPrimary: false)
                if let primaryActionTitle = tab.primaryActionTitle {
                    hint(primaryActionTitle, keys: ["↵"], isPrimary: true)
                }
                if let secondaryActionTitle = tab.secondaryActionTitle {
                    hint(secondaryActionTitle, keys: ["⌘", "↵"], isPrimary: false)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .frame(height: PaletteTheme.footerHeight)
            .paletteFloatingSurface(Capsule())
            .allowsHitTesting(false)
        }
        .padding(10)
    }

    private func hint(_ title: String, keys: [String], isPrimary: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(isPrimary ? .primary : .secondary)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { PaletteKeycap($0) }
            }
        }
    }
}

/// Raycast's round button at the footer's left, here a gear that opens Keybumps Settings from any tab.
private struct PaletteSettingsButton: View {
    let action: () -> Void
    @State private var isHovering = false

    private let command = QuickSearchCommand.keybumpsSettings

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: PaletteTheme.footerHeight, height: PaletteTheme.footerHeight)
                .paletteFloatingSurface(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(command.title) (\(command.shortcut))")
        .accessibilityLabel(command.title)
        .accessibilityIdentifier("palette.settings")
    }
}
