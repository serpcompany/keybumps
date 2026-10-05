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
    case snippets

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

/// What choosing a screenshot does. Return or a click copies it, as in the Clipboard tab.
/// Command-Return or Command-click opens it in the Screenshot Editor.
enum ScreenshotPaletteAction: Equatable {
    case copy
    case edit

    init(withCommand: Bool) {
        self = withCommand ? .edit : .copy
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
    var historyQuery = "" {
        // Snippets re-ranks as you type, so a new search starts on its top match, as Quick Search's
        // does. The other history tabs only filter.
        didSet { if tab == .snippets, historyQuery != oldValue { selection = 0 } }
    }
    var selection = 0
    /// The snippet whose Delete confirmation is showing.
    var snippetPendingDeletion: Snippet?

    func select(_ tab: CommandPaletteTab) {
        self.tab = tab
        historyQuery = ""
        selection = 0
        snippetPendingDeletion = nil
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
    private let search: QuickSearchModel
    private let clipboard: ClipboardHistoryService
    private let dictationHistory: DictationHistoryService
    private let dictationService: DictationService
    private let inbox: InboxStore
    private let preferences: AppPreferences
    private let snippets: SnippetStore
    /// The paste step Dictation also uses; the palette's copies write `pasteboard` directly.
    private let paster: any TextPasting
    private let pasteboard: NSPasteboard
    /// Internal so tests can set the tab, search, and selection without showing the panel.
    let state = CommandPaletteState()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var isPresentingConfirmation = false
    private let notices: any PaletteNoticePresenting
    /// Set while Screenshot Tools is enabled; opens the markup editor for an image item.
    var editImage: ((ClipboardEntry) -> Bool)?
    /// Opens Settings on a page, or where it was left when nil. The app shell sets it to the status
    /// menu's route.
    var openSettings: (SettingsSection?) -> Void = { _ in }
    /// Opens a Quick Search result's URL; tests replace it so they never open anything.
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Whether ⌘V can reach another app, which needs Accessibility. The shell re-reads it from
    /// macOS on every paste; without it, pasting a snippet copies it instead.
    var canPaste: () -> Bool = { false }
    /// Offers to set up Accessibility after a paste had to copy instead. Set by the shell.
    var offerPasteSetup: () -> Void = {}
    /// The app in front right now; tests replace it.
    var frontmostApp: () -> PasteTarget? = { PasteTarget.frontmost() }
    /// How long a snippet paste waits after the palette closes, so the app in front has its
    /// keyboard focus back before ⌘V.
    var pasteDelay: Duration = .milliseconds(120)
    /// The app that was in front when the palette opened: the only app ⌘Return pastes into.
    private(set) var pasteTarget: PasteTarget?
    /// The snippet paste waiting out `pasteDelay`; opening the palette again cancels it.
    private var pendingPaste: UUID?

    init(
        clipboard: ClipboardHistoryService,
        dictationHistory: DictationHistoryService,
        dictationService: DictationService,
        inbox: InboxStore,
        preferences: AppPreferences,
        snippets: SnippetStore,
        paster: any TextPasting = InertTextPaster(),
        pasteboard: NSPasteboard = .keybumps,
        notices: (any PaletteNoticePresenting)? = nil,
        search: QuickSearchModel? = nil
    ) {
        let search = search ?? QuickSearchModel()
        // Quick Search finds snippets only while Snippets is on.
        search.snippets = { preferences.enabledCapabilities.contains(.snippets) ? snippets.snippets : [] }
        self.search = search
        self.clipboard = clipboard
        self.dictationHistory = dictationHistory
        self.dictationService = dictationService
        self.inbox = inbox
        self.preferences = preferences
        self.snippets = snippets
        self.paster = paster
        self.pasteboard = pasteboard
        self.notices = notices ?? PaletteHUD.shared
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

        rememberPasteTarget()
        selectOnOpening(tab)
        position(panel)
        installKeyMonitor()
        installOutsideMonitors()
        panel.hideDuringUnitTests()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusInput()
        }
    }

    /// Runs as the palette opens. The palette never activates Keybumps, so the app in front is the
    /// one you were typing in, unless Keybumps already was (a Dock click, or Settings). Opening the
    /// palette also cancels a paste still waiting to happen.
    func rememberPasteTarget() {
        pasteTarget = frontmostApp()
        pendingPaste = nil
    }

    /// Runs as the palette opens on a tab, even while a snippet's Delete alert shows (a hot key or
    /// a Dock click). Selecting drops the pending deletion, and SwiftUI can take the alert away
    /// without calling its binding, so the palette takes its keys back here, as `ClearAllButton`
    /// does when it disappears.
    func selectOnOpening(_ tab: CommandPaletteTab) {
        if state.snippetPendingDeletion != nil { isPresentingConfirmation = false }
        state.select(tab)
        search.query = ""
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

    /// Whether the palette is on screen, on any tab.
    var isVisible: Bool { panel?.isVisible == true }

    func isDisplaying(_ tab: CommandPaletteTab) -> Bool {
        panel?.isVisible == true && state.tab == tab
    }

    /// The tab the palette is on, or was last on.
    var selectedTab: CommandPaletteTab { state.tab }

    /// Runs a command the user picked from Quick Search's results (a click, or Return on its row):
    /// learns it for ranking, as opening an app does, then runs it. It never becomes a Recent Item.
    func choose(_ command: QuickSearchCommand) {
        search.recordRunCommand(command)
        run(command)
    }

    /// Runs a Keybumps command: from `choose(_:)`, the footer's Settings button, or its Command-key
    /// shortcut in any tab. Only `choose(_:)` teaches the ranking. A capability's tab opens in place;
    /// for Settings the palette closes first.
    func run(_ command: QuickSearchCommand) {
        switch command.destination(enabledCapabilities: preferences.enabledCapabilities) {
        case .paletteTab(let tab):
            selectTab(tab)
        case .settings(let section):
            dismiss()
            openSettings(section)
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
                snippets: snippets,
                selectTab: selectTab,
                activateSearchResult: open,
                revealSearchResult: reveal,
                runCommand: { [weak self] command in self?.run(command) },
                chooseCommand: { [weak self] command in self?.choose(command) },
                chooseClipboardEntry: { [weak self] entry in self?.chooseClipboardEntry(entry) },
                copyClipboardEntry: { [weak self] entry in self?.copyClipboardEntry(entry) },
                editClipboardEntry: { [weak self] entry in _ = self?.editClipboardImage(entry) },
                chooseScreenshot: { [weak self] entry in self?.chooseScreenshot(entry) },
                copyDictationText: { [weak self] text in
                    self?.copy(text, suppressClipboardHistory: true)
                },
                snippetActions: SnippetPaletteActions(
                    copy: { [weak self] snippet in self?.copySnippet(snippet) },
                    paste: { [weak self] snippet in self?.pasteSnippet(snippet) },
                    edit: { [weak self] snippet in self?.openSnippetEditor(.edit(snippet.id)) },
                    create: { [weak self] in self?.openSnippetEditor(.new) },
                    openSettings: { [weak self] in self?.openSnippetsSettings() },
                    requestDelete: { [weak self] snippet in self?.requestSnippetDeletion(snippet) },
                    delete: { [weak self] snippet in self?.deleteSnippet(snippet) }
                ),
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
            self?.handleKeyDown(event) ?? event
        }
    }

    /// The palette's keys: returns nil for a key it handled, or the event to pass on. Tests call it
    /// with synthesized events, so no real keystroke is posted.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // A confirmation alert handles its own keys: Return confirms, Escape cancels.
        guard !isPresentingConfirmation else { return event }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            let tabs = CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab)
            if let tab = CommandPaletteTab.matchingCommandKey(event.charactersIgnoringModifiers, in: tabs) {
                selectTab(tab)
                return nil
            }
            if let command = QuickSearchCommand.matchingCommandKey(event.charactersIgnoringModifiers) {
                run(command)
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "e", state.tab == .clipboard || state.tab == .screenshots {
                editSelectedClipboardImage()
                return nil
            }
            if state.tab == .snippets, handleSnippetCommandKey(event.charactersIgnoringModifiers) {
                return nil
            }
        }

        switch event.keyCode {
        case 53:
            dismiss()
            return nil
        case 125:
            moveSelection(state.tab == .screenshots ? ScreenshotGrid.columnCount : 1)
            return nil
        case 126:
            moveSelection(state.tab == .screenshots ? -ScreenshotGrid.columnCount : -1)
            return nil
        case 123, 124:
            // Left and Right move through the screenshot grid; elsewhere they move the caret.
            guard state.tab == .screenshots, activeQuery.isEmpty else { return event }
            moveSelection(event.keyCode == 124 ? 1 : -1)
            return nil
        case 36:
            activateSelection(reveal: event.modifierFlags.contains(.command))
            return nil
        case 51, 117:
            // Delete removes the highlighted row once the search field is empty (or with Command).
            guard activeQuery.isEmpty || event.modifierFlags.contains(.command),
                  deleteSelection() else { return event }
            return nil
        default:
            return event
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
                ? search.displayedRecentItems.count
                : search.items.count
        case .clipboard:
            filteredClipboard.count
        case .dictation:
            filteredDictations.count
        case .keyboardShortcutter:
            filteredKeyboardShortcutter.count
        case .screenshots:
            screenshotContent.entries.count
        case .snippets:
            snippetContent.entries.count
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
                  search.displayedRecentItems.indices.contains(index) else { return false }
            search.recentItems.delete(search.displayedRecentItems[index])
        case .clipboard:
            guard filteredClipboard.indices.contains(index) else { return false }
            clipboard.removeFromClipboardTab(filteredClipboard[index])
        case .screenshots:
            let entries = screenshotContent.entries
            guard entries.indices.contains(index) else { return false }
            clipboard.delete(entries[index])
        case .dictation:
            guard filteredDictations.indices.contains(index) else { return false }
            dictationHistory.delete(filteredDictations[index])
        case .snippets:
            // Snippets are things you wrote, not history, so Delete asks first.
            let entries = snippetContent.entries
            guard entries.indices.contains(index) else { return false }
            requestSnippetDeletion(entries[index])
            return true
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
        guard !query.isEmpty else { return clipboard.clipboardTabEntries }
        return clipboard.clipboardTabEntries.filter { $0.matches(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        DictationPaletteResults.filter(dictationHistory.entries, query: state.historyQuery)
    }

    private var snippetContent: SnippetPaletteContent {
        SnippetPaletteContent.resolve(
            snippets: snippets.snippets,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.snippets),
            libraryState: snippets.libraryState
        )
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
                guard search.displayedRecentItems.indices.contains(state.selection) else { return }
                open(search.displayedRecentItems[state.selection].result)
                return
            }
            guard search.items.indices.contains(state.selection) else { return }
            switch search.items[state.selection] {
            case .command(let command):
                choose(command)
            case .snippet(let snippet):
                reveal ? pasteSnippet(snippet) : copySnippet(snippet)
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
            chooseScreenshot(entries[state.selection], withCommand: reveal)
        case .snippets:
            // Return copies; Command-Return pastes into the app in front.
            let entries = snippetContent.entries
            guard entries.indices.contains(state.selection) else { return }
            reveal ? pasteSnippet(entries[state.selection]) : copySnippet(entries[state.selection])
        }
    }

    /// Opens an app, file, or folder from Quick Search's results or Recent Items. A copy of Keybumps
    /// itself runs Keybumps Settings instead, as its command would (learned as that command, never a
    /// Recent Item): asking macOS to open the running app would reopen it, which shows Quick Search
    /// again, and Settings too.
    func open(_ result: QuickSearchResult) {
        if let command = QuickSearchCommand.standIn(for: result) {
            choose(command)
            return
        }
        let didOpen = openURL(result.url)
        search.recordOpenResult(result, succeeded: didOpen)
        if didOpen { dismiss() }
    }

    private func reveal(_ result: QuickSearchResult) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    @discardableResult
    private func copy(_ text: String, suppressClipboardHistory: Bool, concealed: Bool = false) -> Bool {
        guard pasteboard.writeText(text, concealed: concealed) else { return false }
        if suppressClipboardHistory { clipboard.suppressCurrentChange() }
        confirmCopy()
        return true
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        guard clipboard.restore(entry) else { return }
        confirmCopy()
    }

    /// Closes the palette and confirms the copy at the notch.
    private func confirmCopy() {
        dismiss()
        notices.showNotice("Copied to Clipboard", isWarning: false)
    }

    // MARK: Snippets

    /// Return: copies the snippet, kept out of Clipboard History as the Dictation tab's copy is. A
    /// sensitive snippet's copy carries the ConcealedType marker.
    func copySnippet(_ snippet: Snippet) {
        guard let text = snippetText(snippet),
              copy(text, suppressClipboardHistory: true, concealed: snippet.isSensitive) else { return }
        snippets.markUsed(snippet.id)
    }

    /// Command-Return: closes the palette and pastes the snippet into the app that was in front when
    /// the palette opened (the non-activating palette never took it over). When it can't paste, it
    /// copies instead and the notch notice says why (`SnippetPasteRoute`).
    func pasteSnippet(_ snippet: Snippet) {
        guard let text = snippetText(snippet) else { return }
        let route = SnippetPasteRoute.beforeClosing(canPaste: canPaste(), target: pasteTarget)
        guard route == .paste, let target = pasteTarget else {
            dismiss()
            copySnippetInstead(text, snippet: snippet, notice: route.notice)
            if route == .copy(.needsAccessibility) { offerPasteSetup() }
            return
        }
        dismiss()
        snippets.markUsed(snippet.id)
        let id = UUID()
        pendingPaste = id
        let paster = paster
        let delay = pasteDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            let isStillWanted = self.pendingPaste == id
            if isStillWanted { self.pendingPaste = nil }
            // Paste only into the same app, still in front, with the palette closed.
            guard SnippetPasteRoute.canPasteNow(
                into: target,
                frontmost: self.frontmostApp(),
                paletteIsVisible: self.panel?.isVisible == true,
                isStillWanted: isStillWanted
            ) else {
                self.copySnippetInstead(text, snippet: snippet, notice: SnippetPasteRoute.Reason.targetChanged.notice)
                return
            }
            do {
                try paster.paste(text, concealed: snippet.isSensitive)
            } catch {
                // The text still ends up on the clipboard, ready to paste by hand.
                self.copySnippetInstead(text, snippet: snippet, notice: SnippetPasteRoute.Reason.pasteFailed.notice)
            }
        }
    }

    /// Puts the text on the clipboard, kept out of Clipboard History, and says why it didn't paste.
    private func copySnippetInstead(_ text: String, snippet: Snippet, notice: String?) {
        guard pasteboard.writeText(text, concealed: snippet.isSensitive) else { return }
        clipboard.suppressCurrentChange()
        if let notice { showWarning(notice) }
        snippets.markUsed(snippet.id)
    }

    /// Closes the palette and opens the snippet editor in Settings. While the saved snippets can't
    /// be read, it opens the Snippets page instead, which explains why nothing can be saved.
    func openSnippetEditor(_ request: SnippetEditorRequest) {
        guard snippets.libraryState != .readOnly else {
            openSnippetsSettings()
            return
        }
        dismiss()
        snippets.editorRequest = request
        openSettings(.snippets)
    }

    /// Closes the palette and opens Settings on the Snippets page.
    func openSnippetsSettings() {
        dismiss()
        openSettings(.snippets)
    }

    /// Shows the Delete confirmation for a snippet.
    func requestSnippetDeletion(_ snippet: Snippet) {
        state.snippetPendingDeletion = snippet
        isPresentingConfirmation = true
    }

    private func deleteSnippet(_ snippet: Snippet) {
        do {
            try snippets.delete(snippet.id)
        } catch {
            showWarning("Couldn’t delete the snippet")
        }
        state.selection = min(state.selection, max(0, itemCount - 1))
    }

    /// A sensitive snippet's text comes from the Keychain, which can refuse it.
    private func snippetText(_ snippet: Snippet) -> String? {
        guard let text = snippets.text(for: snippet) else {
            showWarning("Couldn’t read this snippet from the Keychain")
            return nil
        }
        return text
    }

    private func showWarning(_ message: String) {
        notices.showNotice(message, isWarning: true)
    }

    /// ⌘N makes a new snippet and ⌘E edits the highlighted one, both in Settings. While Snippets is
    /// off, they do nothing.
    private func handleSnippetCommandKey(_ characters: String?) -> Bool {
        guard ["n", "e"].contains(characters?.lowercased()) else { return false }
        guard preferences.enabledCapabilities.contains(.snippets) else { return true }
        switch characters?.lowercased() {
        case "n":
            openSnippetEditor(.new)
            return true
        case "e":
            let entries = snippetContent.entries
            if entries.indices.contains(state.selection) {
                openSnippetEditor(.edit(entries[state.selection].id))
            }
            return true
        default:
            return false
        }
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

    /// A click on a screenshot copies it; Command-click edits it.
    private func chooseScreenshot(_ entry: ClipboardEntry) {
        chooseScreenshot(entry, withCommand: NSEvent.modifierFlags.contains(.command))
    }

    /// Return and a click copy a screenshot; with Command held they open it in the Screenshot Editor.
    private func chooseScreenshot(_ entry: ClipboardEntry, withCommand: Bool) {
        switch ScreenshotPaletteAction(withCommand: withCommand) {
        case .copy: copyClipboardEntry(entry)
        case .edit: editClipboardImage(entry)
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
    @Bindable var snippets: SnippetStore
    let selectTab: (CommandPaletteTab) -> Void
    let activateSearchResult: (QuickSearchResult) -> Void
    let revealSearchResult: (QuickSearchResult) -> Void
    /// Runs a command without teaching the ranking (the footer's Settings button).
    let runCommand: (QuickSearchCommand) -> Void
    /// Runs a command picked from Quick Search's results, which teaches the ranking.
    let chooseCommand: (QuickSearchCommand) -> Void
    /// A click: Command-click edits an image, anything else copies.
    let chooseClipboardEntry: (ClipboardEntry) -> Void
    /// Always copies, whatever keys are held (the context menu's Copy).
    let copyClipboardEntry: (ClipboardEntry) -> Void
    let editClipboardEntry: (ClipboardEntry) -> Void
    let chooseScreenshot: (ClipboardEntry) -> Void
    let copyDictationText: (String) -> Void
    let snippetActions: SnippetPaletteActions
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
                    PaletteFooter(
                        tab: state.tab,
                        selectedSearchItem: state.tab == .search ? search.highlightedItem(at: state.selection) : nil,
                        openSettings: { runCommand(.keybumpsSettings) }
                    )
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
        .onChange(of: search.displayedRecentItems.map(\.id)) {
            guard state.tab == .search,
                  search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.selection >= search.displayedRecentItems.count else { return }
            state.selection = max(0, search.displayedRecentItems.count - 1)
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
                enabledCapabilities: preferences.enabledCapabilities,
                visibleTabs: CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab),
                recentItems: search.displayedRecentItems,
                open: activateSearchResult,
                reveal: revealSearchResult,
                run: chooseCommand,
                snippetActions: snippetActions,
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
                delete: clipboard.removeFromClipboardTab,
                clear: clipboard.clearClipboardTab,
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
        case .snippets:
            SnippetPaletteResults(
                content: SnippetPaletteContent.resolve(
                    snippets: snippets.snippets,
                    query: state.historyQuery,
                    isEnabled: preferences.enabledCapabilities.contains(.snippets),
                    libraryState: snippets.libraryState
                ),
                selection: state.selection,
                actions: snippetActions,
                pendingDeletion: $state.snippetPendingDeletion,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
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
        guard !query.isEmpty else { return clipboard.clipboardTabEntries }
        return clipboard.clipboardTabEntries.filter { $0.matches(query) }
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
    /// Where each command goes, and what its row shows, depend on these.
    let enabledCapabilities: Set<Capability>
    let visibleTabs: [CommandPaletteTab]
    let recentItems: [RecentItem]
    let open: (QuickSearchResult) -> Void
    let reveal: (QuickSearchResult) -> Void
    let run: (QuickSearchCommand) -> Void
    let snippetActions: SnippetPaletteActions
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
                    .accessibilityIdentifier("quickSearch.noRecentItems")
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
                                let hint = command.destination(enabledCapabilities: enabledCapabilities).hint
                                Button {
                                    run(command)
                                } label: {
                                    QuickSearchCommandRow(
                                        command: command,
                                        shortcut: command.rowShortcut(
                                            enabledCapabilities: enabledCapabilities,
                                            visibleTabs: visibleTabs
                                        ),
                                        isTurnedOff: command.isTurnedOff(enabledCapabilities: enabledCapabilities)
                                    )
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(hint)
                                .accessibilityHint(hint)
                                .accessibilityIdentifier("quickSearch.command.\(command.id)")
                            case .snippet(let snippet):
                                Button {
                                    snippetActions.copy(snippet)
                                } label: {
                                    QuickSearchSnippetRow(snippet: snippet)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Copy") { snippetActions.copy(snippet) }
                                    Button("Paste") { snippetActions.paste(snippet) }
                                }
                                .accessibilityAction(named: "Paste") { snippetActions.paste(snippet) }
                                .accessibilityHint("Copies the snippet")
                                .accessibilityIdentifier("quickSearch.snippet")
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

/// A snippet in Quick Search's row layout: the snippet icon, its name (with a lock when it's
/// sensitive), and its keyword chip and kind on the right. Its text never shows here.
private struct QuickSearchSnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SnippetPaletteResults.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(snippet.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if snippet.isSensitive {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Sensitive: the text is kept in the Keychain")
                    .accessibilityLabel("Sensitive")
            }
            Spacer(minLength: 12)
            if let keyword = snippet.keyword {
                SnippetKeywordChip(keyword: keyword)
            }
            Text("Snippet")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Keybumps command in Raycast's row: its icon (the Keybumps icon, or the capability's Settings
/// tile), the name, Turned off for a capability that's off, then its shortcut and kind on the right.
private struct QuickSearchCommandRow: View {
    let command: QuickSearchCommand
    let shortcut: String?
    let isTurnedOff: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)
            Text(command.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if isTurnedOff {
                Text("Turned off")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let shortcut {
                PaletteKeycaps(shortcut: shortcut)
            }
            Text(command.kindLabel)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch command {
        case .keybumpsSettings:
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
        case .capability(let capability):
            SettingsIconTile(systemImage: capability.systemImage, tint: capability.descriptor.iconTint, size: 24)
                .accessibilityHidden(true)
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
    var clearMessage = "This clears the Clipboard tab. Screenshots stay in the Screenshots tab."

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

struct PaletteResultsContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PaletteEmptyState: View {
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
    /// Quick Search's highlighted row, whose actions the footer names (a snippet copies and pastes).
    let selectedSearchItem: QuickSearchItem?
    let openSettings: () -> Void

    private var primaryActionTitle: String? { selectedSearchItem?.primaryActionTitle ?? tab.primaryActionTitle }
    private var secondaryActionTitle: String? { selectedSearchItem?.secondaryActionTitle ?? tab.secondaryActionTitle }

    var body: some View {
        HStack {
            PaletteSettingsButton(action: openSettings)
            Spacer()
            HStack(spacing: 14) {
                hint("Select", keys: tab == .screenshots ? ["←", "→", "↑", "↓"] : ["↑", "↓"], isPrimary: false)
                if let primaryActionTitle {
                    hint(primaryActionTitle, keys: ["↵"], isPrimary: true)
                }
                if let secondaryActionTitle {
                    hint(secondaryActionTitle, keys: ["⌘", "↵"], isPrimary: false)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .frame(height: PaletteTheme.footerHeight)
            .paletteFloatingSurface()
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
                .paletteFloatingSurface()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(command.shortcut.map { "\(command.title) (\($0))" } ?? command.title)
        .accessibilityLabel(command.title)
        .accessibilityIdentifier("palette.settings")
    }
}
