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
    case timers
    case emoji
    case translate

    var id: String { rawValue }

    /// Tabs in Command-number order, as their owning modules register them.
    static var allCases: [CommandPaletteTab] { CapabilityCatalog.paletteTabs.map(\.tab) }

    private var registration: CapabilityPaletteTab { CapabilityCatalog.paletteTab(for: self).tab }
    /// The module that owns the tab.
    var owner: Capability { CapabilityCatalog.paletteTab(for: self).owner }
    var title: String { registration.name }
    var systemImage: String { registration.systemImage }
    var shortcutLabel: String { "⌘\(registration.commandKey)" }

    /// The tabs `CommandPaletteController` draws itself. Every other tab's rows come from its
    /// module (`CapabilityPaletteContent`).
    static let drawnByPalette: Set<CommandPaletteTab> = [.search, .clipboard, .dictation, .screenshots, .snippets]
    var prompt: String { registration.prompt }

    /// The tabs in the tab bar: those of plugins that are on, and whose data source is on too (the
    /// Screenshots tab lists Clipboard History), as Raycast leaves out turned-off extensions.
    /// Command-numbers stay fixed. The Hotkeys tab shows only when its Settings page says so, and
    /// the tab on screen always stays.
    static func visibleTabs(showsHotkeys: Bool, selected: CommandPaletteTab, enabled: Set<Capability>) -> [CommandPaletteTab] {
        allCases.filter { tab in
            tab == selected || (
                enabled.contains(tab.owner)
                    && (tab.dataSource.map(enabled.contains) ?? true)
                    && (tab != .keyboardShortcutter || showsHotkeys)
            )
        }
    }

    /// Another plugin whose data the tab lists, such as Clipboard History for Screenshots.
    var dataSource: Capability? { registration.dataSource }

    static func matchingCommandKey(_ characters: String?, in tabs: [CommandPaletteTab] = allCases) -> CommandPaletteTab? {
        tabs.first { characters == String($0.registration.commandKey) }
    }

    /// The tab Left or Right switches to: the one beside `tab` in the tab bar, stopping at either end.
    static func adjacent(to tab: CommandPaletteTab, offset: Int, in tabs: [CommandPaletteTab]) -> CommandPaletteTab? {
        guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + offset) else { return nil }
        return tabs[index + offset]
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

@MainActor
@Observable
final class CommandPaletteState {
    private(set) var tab: CommandPaletteTab = .search
    var historyQuery = "" {
        // Snippets re-ranks as you type, so a new search starts on its top match, as Quick Search's
        // does, and so does any module tab that asks. The other history tabs only filter.
        didSet {
            if tab == .snippets || tabsResettingSelectionWhileTyping.contains(tab), historyQuery != oldValue {
                selection = 0
            }
            if historyQuery != oldValue { isBrowsingGrid = false }
            // Opening, narrowing, or closing `/`'s list starts again at the first row.
            if historyQuery.hasPrefix("/") != oldValue.hasPrefix("/") || historyQuery.hasPrefix("/") && historyQuery != oldValue {
                selection = 0
            }
        }
    }
    /// The module-supplied tabs whose rows re-rank as you type.
    var tabsResettingSelectionWhileTyping: Set<CommandPaletteTab> = []
    var selection = 0 {
        didSet {
            if selectionFollowsPointer != isSelectingFromPointer { selectionFollowsPointer = isSelectingFromPointer }
            if !isSelectingFromPointer { pointerAtSelection = mouseLocation() }
        }
    }
    /// Whether the pointer moved the highlight last (#347), so lists don't scroll to it.
    private(set) var selectionFollowsPointer = false
    @ObservationIgnored private var isSelectingFromPointer = false
    /// Where the pointer was when the highlight last moved. A hover counts only once the pointer
    /// has moved from there, so rows that scroll or appear under a still pointer don't take the
    /// highlight from the keyboard (#347).
    @ObservationIgnored private var pointerAtSelection: NSPoint?
    /// The pointer's position on screen; tests supply their own.
    @ObservationIgnored var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// Where the palette last saw the pointer over its rows, and when it got there. A row that
    /// appears under a pointer resting since then, such as a search result that arrives late,
    /// doesn't take the highlight (#347).
    @ObservationIgnored private var pointerSeen: NSPoint?
    @ObservationIgnored private var pointerSeenAt: TimeInterval = -.infinity
    /// The time, in seconds; tests supply their own.
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How long after the pointer last moved a hover still counts.
    static let hoverAfterMove: TimeInterval = 0.25

    /// The pointer is over the rows' area, moving or not. A row can still take the highlight within
    /// `hoverAfterMove` of a move, or when the pointer came to rest somewhere no hover reported it:
    /// the cost of not depending on which hover callback runs first.
    func notePointer() {
        let pointer = mouseLocation()
        guard pointer != pointerSeen else { return }
        pointerSeen = pointer
        pointerSeenAt = now()
    }

    /// Any key: whatever it does to the rows (typing that filters them, an arrow that scrolls
    /// them), the pointer has to move before a row under it takes the highlight.
    func keyWasPressed() {
        pointerAtSelection = mouseLocation()
    }

    /// Moves the highlight to a row the pointer is over, if the pointer has moved since the
    /// highlight last did. Returns whether it moved.
    @discardableResult
    func selectFromPointer(_ row: Int) -> Bool {
        notePointer()
        let pointer = mouseLocation()
        guard pointer != pointerAtSelection, now() - pointerSeenAt <= Self.hoverAfterMove else { return false }
        pointerAtSelection = pointer
        guard row != selection else {
            if !selectionFollowsPointer { selectionFollowsPointer = true }
            return true
        }
        isSelectingFromPointer = true
        selection = row
        isSelectingFromPointer = false
        return true
    }
    /// Whether ⌘ is held while the palette has the keys, which shows the tabs' ⌘-numbers (#182).
    var isCommandHeld = false
    /// Whether Down has taken the arrow keys into a grid tab's items (Screenshots, Emoji). Until
    /// then nothing is highlighted, Left and Right switch tabs, and Return acts on the first item.
    var isBrowsingGrid = false {
        didSet { if !isBrowsingGrid { gridEnteredByPointer = false } }
    }
    /// Whether the pointer, not a key, brought the highlight into the grid. Until a key moves
    /// within it, Left and Right still switch tabs (#347).
    var gridEnteredByPointer = false
    /// The filter chosen from `/`'s list, shown as a chip in the search field. Choosing or removing
    /// one starts again at the first row.
    var filter: PaletteFilter? {
        didSet {
            guard filter != oldValue else { return }
            selection = 0
            isBrowsingGrid = false
        }
    }
    /// The snippet whose Delete confirmation is showing.
    var snippetPendingDeletion: Snippet?
    /// The recording whose Delete confirmation is showing.
    var dictationPendingDeletion: DictationHistoryEntry?
    /// How many times the palette has closed. Its views stay alive while it's hidden, so work that
    /// mustn't outlast a showing, such as a translation, stops when this changes.
    private(set) var closings = 0

    func didClose() { closings += 1 }

    func select(_ tab: CommandPaletteTab) {
        self.tab = tab
        historyQuery = ""
        selection = 0
        isBrowsingGrid = false
        filter = nil
        snippetPendingDeletion = nil
        dictationPendingDeletion = nil
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

/// Whether the palette closes when it stops being key or a click lands outside it. Escape closes it
/// either way.
enum CommandPaletteDismissalPolicy {
    /// - Parameters:
    ///   - isPresentingConfirmation: A confirmation alert shows; it takes the palette's keys too.
    ///   - isHeldOpen: Something in the palette holds it open (`holdCommandPaletteOpen`), such as a
    ///     translation whose system download prompt is a Keybumps window of its own (#321). A hold
    ///     only covers Keybumps's own windows: callers never pass it for another app.
    static func shouldDismiss(isPresentingConfirmation: Bool = false, isHeldOpen: Bool = false) -> Bool {
        !isPresentingConfirmation && !isHeldOpen
    }

    /// When the palette stops being key. A hold keeps it only while key focus went to another
    /// Keybumps window, such as the download prompt; switching to another app closes it.
    static func shouldDismissOnResignKey(
        isPresentingConfirmation: Bool,
        isHeldOpen: Bool,
        keyWentToOwnWindow: Bool
    ) -> Bool {
        shouldDismiss(isPresentingConfirmation: isPresentingConfirmation, isHeldOpen: isHeldOpen && keyWentToOwnWindow)
    }

    /// Whether the palette's keys handle a key: only one sent to the panel, or to no window. Keys
    /// typed into another Keybumps window, such as Translation's download prompt, are that window's.
    static func palettesKey(eventWindow: NSWindow?, panel: NSWindow?) -> Bool {
        eventWindow == nil || eventWindow === panel
    }

    /// Whether the palette becomes key again as the last hold lets go: it's still showing but lost
    /// key focus to a window that has since closed, and no other Keybumps window is key.
    static func shouldTakeKeyBack(isHeldOpen: Bool, isVisible: Bool, isKey: Bool, keybumpsHasKeyWindow: Bool) -> Bool {
        !isHeldOpen && isVisible && !isKey && !keybumpsHasKeyWindow
    }
}

/// Holds the Command Palette open against clicks in Keybumps's other windows once it's called with
/// `true` for an ID, until it's called with `false` for that ID or the palette closes. Outside the
/// palette it does nothing. Equal for the same palette, so the environment value doesn't redraw its
/// readers.
struct CommandPaletteHold: Equatable {
    private weak var palette: CommandPaletteController?

    init(palette: CommandPaletteController? = nil) {
        self.palette = palette
    }

    @MainActor
    func callAsFunction(_ holder: UUID, _ isHeld: Bool) {
        palette?.holdOpen(isHeld, by: holder)
    }

    /// How many times the palette has closed (`CommandPaletteState.closings`); 0 outside it.
    @MainActor
    var closings: Int { palette?.state.closings ?? 0 }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.palette === rhs.palette }
}

/// Moving the pointer over a palette row or tile highlights it, as in Raycast (#347). Outside the
/// palette it does nothing. Equal for the same palette, so the environment value doesn't redraw
/// its readers.
struct CommandPaletteHover: Equatable {
    private weak var palette: CommandPaletteController?

    init(palette: CommandPaletteController? = nil) {
        self.palette = palette
    }

    @MainActor
    func callAsFunction(_ row: Int) {
        palette?.hover(row: row)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.palette === rhs.palette }
}

extension EnvironmentValues {
    @Entry var holdCommandPaletteOpen = CommandPaletteHold()
    @Entry var paletteHover = CommandPaletteHover()
    /// False while the pointer moved the highlight, so a list doesn't scroll to the row under it.
    @Entry var paletteRevealsSelection = true
}

extension View {
    /// A row or tile that takes the highlight when the pointer moves over it (#347). Put it on the
    /// whole row, padding included.
    func paletteHoverHighlights(row: Int) -> some View {
        modifier(PaletteHoverRow(row: row))
    }
}

extension View {
    /// Keeps the highlighted row on screen as the keys move it, but not when the pointer moved it
    /// (#347, #352). Every palette list and grid uses it, inside its `ScrollViewReader`; `id` names
    /// the row at an index, matching its `.id`.
    func paletteScrollsToSelection<ID: Hashable>(_ selection: Int, proxy: ScrollViewProxy, id: @escaping (Int) -> ID?) -> some View {
        modifier(PaletteScrollsToSelection(selection: selection, proxy: proxy, id: id))
    }
}

private struct PaletteScrollsToSelection<ID: Hashable>: ViewModifier {
    let selection: Int
    let proxy: ScrollViewProxy
    let id: (Int) -> ID?
    @Environment(\.paletteRevealsSelection) private var revealsSelection

    func body(content: Content) -> some View {
        content.onChange(of: selection) {
            guard revealsSelection, let target = id(selection) else { return }
            proxy.scrollTo(target)
        }
    }
}

private struct PaletteHoverRow: ViewModifier {
    let row: Int
    @Environment(\.paletteHover) private var hover

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            if case .active = phase { hover(row) }
        }
    }
}

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private let search: QuickSearchModel
    private var useQuickSearchEmoji: (QuickSearchEmoji) -> Void = { _ in }
    private let clipboard: ClipboardHistoryService
    private let dictationHistory: DictationHistoryService
    private let dictationService: DictationService
    private let preferences: AppPreferences
    private let snippets: SnippetStore
    /// The paste step Dictation also uses; the palette's copies write `pasteboard` directly.
    private let paster: any TextPasting
    private let pasteboard: NSPasteboard
    /// Internal so tests can set the tab, search, and selection without showing the panel.
    let state = CommandPaletteState()
    /// The tabs whose rows their capability modules supply (`CapabilityRegistry.paletteContents`).
    /// Every key and footer action on those tabs goes to their content, never to a case here. The
    /// shell sets it once, before the palette first shows.
    var tabContents: [CommandPaletteTab: any CapabilityPaletteContent] = [:] {
        didSet {
            precondition(panel == nil, "Set the palette's tab contents before it first shows")
            state.tabsResettingSelectionWhileTyping = Set(tabContents.values.filter(\.resetsSelectionWhileTyping).map(\.tab))
        }
    }
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var isPresentingConfirmation = false
    /// Who holds the palette open against clicks in Keybumps's other windows
    /// (`holdCommandPaletteOpen`). Closing the palette lets them all go, so a hold never outlasts
    /// one showing.
    private var openHolds: Set<UUID> = []
    var isHeldOpen: Bool { !openHolds.isEmpty }
    private let notices: any PaletteNoticePresenting
    /// Set while Screenshot Tools is enabled; opens the markup editor for an image item.
    var editImage: ((ClipboardEntry) -> Bool)?
    /// Opens Settings on a page, or where it was left when nil. The app shell sets it to the status
    /// menu's route.
    var openSettings: (SettingsSection?) -> Void = { _ in }
    /// Opens a Quick Search result's URL; tests replace it so they never open anything.
    /// Never opens anything under the unit-test host, so no test can launch an app or the browser.
    var openURL: (URL) -> Bool = { UnitTestHost.isActive ? false : NSWorkspace.shared.open($0) }
    /// Whether ⌘V can reach another app, which needs Accessibility. The shell re-reads it from
    /// macOS on every paste; without it, pasting a snippet copies it instead.
    var canPaste: () -> Bool = { false }
    /// Offers to set up Accessibility after a paste had to copy instead. Set by the shell.
    /// Offers Accessibility setup after a paste had to copy, for the plugin that pasted.
    var offerPasteSetup: (Capability) -> Void = { _ in }
    /// The app in front right now; tests replace it.
    var frontmostApp: () -> PasteTarget? = { PasteTarget.frontmost() }
    /// How long a snippet paste waits after the palette closes, so the app in front has its
    /// keyboard focus back before ⌘V.
    var pasteDelay: Duration = .milliseconds(120)
    /// Puts the clipboard back after a paste that asks for it. The shell shares one with keyword
    /// expansion, so quick pastes from either put back the clipboard from before the first.
    lazy var clipboardRestorer: ClipboardRestorer = {
        let restorer = ClipboardRestorer(pasteboard: pasteboard)
        restorer.didRestore = { [weak clipboard] in clipboard?.suppressCurrentChange() }
        return restorer
    }()
    /// The app that was in front when the palette opened: the only app ⌘Return pastes into.
    private(set) var pasteTarget: PasteTarget?
    /// The paste waiting out `pasteDelay`; opening the palette again cancels it.
    private var pendingPaste: UUID?

    init(
        clipboard: ClipboardHistoryService,
        dictationHistory: DictationHistoryService,
        dictationService: DictationService,
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
        DispatchQueue.main.async { [weak self, weak panel] in
            self?.focusInput()
            // macOS shapes a clear window's shadow from its content when it last computed it, not
            // as SwiftUI draws. Reshape it from the rounded palette once it has drawn (#309).
            panel?.invalidateShadow()
        }
    }

    /// Unit tests only: lays the palette out on `tab`, invisible and without key focus, monitors, or
    /// paste target, so a test can scroll its real lists while the owner keeps typing elsewhere.
    func layOutForTesting(_ tab: CommandPaletteTab) -> NSWindow? {
        guard UnitTestHost.isActive else { return nil }
        if panel == nil { makePanel() }
        guard let panel else { return nil }
        selectOnOpening(tab)
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
        return panel
    }

    /// Runs as the palette opens. The palette never activates Keybumps, so the app in front is the
    /// one you were typing in, unless Keybumps already was (a Dock click, or Settings). Opening the
    /// palette also cancels a paste still waiting to happen.
    func rememberPasteTarget() {
        pasteTarget = frontmostApp()
        pendingPaste = nil
    }

    /// Runs as the palette opens on a tab, even while a snippet's or recording's Delete alert shows (a hot key or
    /// a Dock click). Selecting drops the pending deletion, and SwiftUI can take the alert away
    /// without calling its binding, so the palette takes its keys back here, as `ClearAllButton`
    /// does when it disappears.
    func selectOnOpening(_ tab: CommandPaletteTab) {
        if state.snippetPendingDeletion != nil || state.dictationPendingDeletion != nil { isPresentingConfirmation = false }
        state.select(tab)
        search.query = ""
        tabContents[tab]?.didShow(palette: contentActions)
    }

    func dismiss() {
        // Before hiding, which resigns key: a held resign would otherwise queue a second dismiss.
        openHolds.removeAll()
        panel?.orderOut(nil)
        isPresentingConfirmation = false
        state.isCommandHeld = false
        state.didClose()
        removeMonitors()
    }

    /// Holds the palette open against outside clicks for `holder`, or lets it go. The palette's
    /// views reach it through `holdCommandPaletteOpen`.
    func holdOpen(_ isHeld: Bool, by holder: UUID) {
        if isHeld { openHolds.insert(holder) } else { openHolds.remove(holder) }
        // Once the prompt that took key focus is gone, the palette takes its keys back, as when
        // it opened, so Escape and the arrow keys reach it again.
        if let panel, CommandPaletteDismissalPolicy.shouldTakeKeyBack(
            isHeldOpen: isHeldOpen,
            isVisible: panel.isVisible,
            isKey: panel.isKeyWindow,
            keybumpsHasKeyWindow: NSApp.keyWindow != nil
        ) {
            panel.makeKey()
        }
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
        // ⌘ let go in another app or window never reaches the palette's monitor.
        state.isCommandHeld = false
        guard isHeldOpen else { return resignedKey(to: nil) }
        // While held, see where key focus went once it has moved: to a Keybumps window, such as
        // the download prompt, or to another app.
        DispatchQueue.main.async { [weak self] in self?.resignedKey(to: NSApp.keyWindow) }
    }

    /// Runs once the palette stopped being key, with the window that is key now (nil for another
    /// app). Internal so tests can say where key focus went.
    func resignedKey(to keyWindow: NSWindow?) {
        if let keyWindow, keyWindow === panel { return }
        if CommandPaletteDismissalPolicy.shouldDismissOnResignKey(
            isPresentingConfirmation: isPresentingConfirmation,
            isHeldOpen: isHeldOpen,
            keyWentToOwnWindow: keyWindow != nil
        ) {
            dismiss()
        }
    }

    /// Switching to another app closes the palette, held or not, so it never floats over that app.
    /// Internal so tests can say which app came to the front.
    func didActivateApp(processIdentifier: pid_t?) {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: isPresentingConfirmation) else { return }
        dismiss()
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
        // The panel never activates Keybumps, and macOS shows a window's tooltips only while its
        // app is active unless the window allows them.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.contentViewController = NSHostingController(
            rootView: CommandPaletteView(
                state: state,
                search: search,
                clipboard: clipboard,
                dictationHistory: dictationHistory,
                dictationService: dictationService,
                preferences: preferences,
                snippets: snippets,
                tabContents: tabContents,
                contentActions: contentActions,
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
                requestDictationDeletion: { [weak self] entry in self?.requestDictationDeletion(entry) },
                deleteDictation: { [weak self] entry in self?.deleteDictation(entry) },
                confirmationPresentationChanged: { [weak self] isPresented in
                    self?.isPresentingConfirmation = isPresented
                },
                chooseFilter: { [weak self] filter in self?.chooseFilter(filter) },
                chooseEmoji: { [weak self] emoji, paste in self?.chooseQuickSearchEmoji(emoji, paste: paste) },
                dismiss: dismiss
            )
            .frame(width: size.width, height: size.height)
            .environment(\.holdCommandPaletteOpen, CommandPaletteHold(palette: self))
            .environment(\.paletteHover, CommandPaletteHover(palette: self))
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
        tabContents[tab]?.didShow(palette: contentActions)
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.handleFlagsChanged(event)
                return event
            }
            return self.handleKeyDown(event)
        }
    }

    /// ⌘ going down or up while the palette has the keys shows or hides the tabs' ⌘-numbers.
    func handleFlagsChanged(_ event: NSEvent) {
        let isHeld = CommandPaletteDismissalPolicy.palettesKey(eventWindow: event.window, panel: panel)
            && Self.isCommandOnly(event.modifierFlags)
        if state.isCommandHeld != isHeld { state.isCommandHeld = isHeld }
    }

    /// Command and no other modifier. Caps Lock, Fn and the keypad flag don't count, so Caps Lock
    /// doesn't stop the palette's Command keys (#182).
    static func isCommandKey(_ event: NSEvent) -> Bool {
        isCommandOnly(event.modifierFlags)
    }

    /// ⌘ without Shift, Option, or Control: the keys that switch tabs, so the only ones that show
    /// the tabs' ⌘-numbers.
    static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command]) == .command
    }

    /// The palette's keys: returns nil for a key it handled, or the event to pass on. Tests call it
    /// with synthesized events, so no real keystroke is posted.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // A confirmation alert handles its own keys: Return confirms, Escape cancels.
        guard !isPresentingConfirmation else { return event }
        // Another Keybumps window, such as Translation's download prompt, keeps its own keys (#321).
        guard CommandPaletteDismissalPolicy.palettesKey(eventWindow: event.window, panel: panel) else { return event }
        state.keyWasPressed()

        if Self.isCommandKey(event) {
            if let tab = CommandPaletteTab.matchingCommandKey(event.charactersIgnoringModifiers, in: visibleTabs) {
                selectTab(tab)
                return nil
            }
            if let command = QuickSearchCommand.matchingCommandKey(event.charactersIgnoringModifiers) {
                run(command)
                return nil
            }
            if let tabContent, let characters = event.charactersIgnoringModifiers?.lowercased(),
               tabContent.commandKeys.contains(characters) {
                // Holding the key down does it once, so a held ⌘T doesn't keep swapping.
                if !event.isARepeat { tabContent.handleCommandKey(characters, query: state.historyQuery) }
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "e", state.tab == .clipboard || state.tab == .screenshots, filterMenu == nil {
                editSelectedClipboardImage()
                return nil
            }
            if state.tab == .snippets, handleSnippetCommandKey(event.charactersIgnoringModifiers) {
                return nil
            }
        }

        // A grid tab's rows take the plain arrow keys; with Shift, Option, Command, or Control, or
        // while an input method is composing, they stay with the search field. Down goes into the
        // grid and Up from its top row comes back out; outside it, Left and Right switch tabs.
        if let tabContent, tabContent.isGrid(query: state.historyQuery), let move = PaletteMove(keyCode: event.keyCode),
           !isComposingText, event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]) {
            // Until an arrow key moves within the grid, Left and Right switch tabs, even after the
            // pointer highlighted a tile on its way across.
            guard state.isBrowsingGrid, !(state.gridEnteredByPointer && (move == .left || move == .right)) else {
                enterGrid(or: move)
                return nil
            }
            if !(0..<itemCount).contains(state.selection) {
                state.selection = 0
                state.gridEnteredByPointer = false
            } else if let target = tabContent.selection(after: move, from: state.selection, query: state.historyQuery) {
                state.selection = target
                state.gridEnteredByPointer = false
            } else if move == .up {
                leaveGrid()
            }
            return nil
        }

        switch event.keyCode {
        case 53:
            // Escape closes `/`'s list of filters first, then the palette.
            if filterMenu != nil {
                if state.tab == .search { search.query = "" } else { state.historyQuery = "" }
            } else {
                dismiss()
            }
            return nil
        case 125:
            if isScreenshotGrid, !state.isBrowsingGrid {
                enterGrid(or: .down)
            } else {
                moveSelection(isScreenshotGrid ? ScreenshotGrid.columnCount : 1)
            }
            return nil
        case 126:
            if isScreenshotGrid, state.selection < ScreenshotGrid.columnCount {
                leaveGrid()
            } else {
                moveSelection(isScreenshotGrid ? -ScreenshotGrid.columnCount : -1)
            }
            return nil
        case 123, 124:
            // With text in the search field, Left and Right move the caret. Otherwise they move
            // through the screenshot grid once Down has gone into it, or switch to the tab beside
            // this one.
            guard activeQuery.isEmpty, !isComposingText,
                  event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]) else { return event }
            let offset = event.keyCode == 124 ? 1 : -1
            if isScreenshotGrid, state.isBrowsingGrid, !state.gridEnteredByPointer {
                if (0..<itemCount).contains(state.selection + offset) { state.selection += offset }
            } else {
                switchTab(by: offset)
            }
            return nil
        case 36:
            activateSelection(reveal: event.modifierFlags.contains(.command))
            return nil
        case 51 where activeQuery.isEmpty && state.filter != nil && event.modifierFlags.isDisjoint(with: .command):
            // Delete in an empty search field removes the filter chip first, as in a token field.
            state.filter = nil
            state.selection = 0
            return nil
        case 51, 117:
            // Delete removes the highlighted row once the search field is empty (or with Command).
            // A grid has no highlighted item until Down goes into it, and `/`'s list hides the rows,
            // so there Delete (with Command too) edits the search text.
            guard filterMenu == nil, activeQuery.isEmpty || event.modifierFlags.contains(.command),
                  !isGridTab || state.isBrowsingGrid,
                  deleteSelection() else { return event }
            return nil
        default:
            return event
        }
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        // A click in another app always closes the palette: a hold covers only Keybumps's own
        // windows, which this monitor never sees.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processIdentifier = app?.processIdentifier
            MainActor.assumeIsolated { self?.didActivateApp(processIdentifier: processIdentifier) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel,
               CommandPaletteDismissalPolicy.shouldDismiss(
                   isPresentingConfirmation: self.isPresentingConfirmation,
                   isHeldOpen: self.isHeldOpen
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
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
    }

    /// The pointer moved over a row or tile: it takes the highlight (`selectFromPointer`), and in a
    /// grid that brings the arrow keys into it too.
    func hover(row: Int) {
        // Not behind a Delete alert. A row view on its way out, after a Delete or while a list
        // re-filters, can still report.
        guard !isPresentingConfirmation, (0..<itemCount).contains(row), state.selectFromPointer(row),
              isGridTab, !state.isBrowsingGrid else { return }
        state.isBrowsingGrid = true
        state.gridEnteredByPointer = true
    }

    private func moveSelection(_ delta: Int) {
        let count = itemCount
        guard count > 0 else { return }
        // Up and Down in the screenshot grid move within it, so Left and Right do too from here.
        state.gridEnteredByPointer = false
        if abs(delta) > 1 {
            // Moving a grid row stops at the edges instead of wrapping to another column.
            let target = state.selection + delta
            guard (0..<count).contains(target) else { return }
            state.selection = target
        } else {
            state.selection = (state.selection + delta + count) % count
        }
    }

    /// The rows of the open tab, when its module supplies them.
    private var tabContent: (any CapabilityPaletteContent)? { tabContents[state.tab] }

    /// What a module tab's rows can ask of the palette.
    private var contentActions: PaletteContentActions {
        PaletteContentActions(
            dismiss: { [weak self] in self?.dismiss() },
            selectRow: { [weak self] row in
                self?.state.selection = row
                self?.state.isBrowsingGrid = true
            },
            clearQuery: { [weak self] in self?.state.historyQuery = "" },
            copy: { [weak self] text in self?.copyText(text) },
            paste: { [weak self] text, restoresClipboard in
                guard let self else { return }
                self.pasteText(text, restoresClipboard: restoresClipboard, for: self.state.tab.owner)
            }
        )
    }

    private var itemCount: Int {
        if let filterMenu { return filterMenu.count }
        if let tabContent { return tabContent.rowCount(query: state.historyQuery) }
        return switch state.tab {
        case .search:
            search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? recentSearchItems.count
                : searchItems.count
        case .clipboard:
            filteredClipboard.count
        case .dictation:
            filteredDictations.count
        case .screenshots:
            screenshotContent.entries.count
        case .snippets:
            snippetContent.entries.count
        default:
            // Module tabs answer above.
            0
        }
    }

    /// The tabs in the tab bar, which Command-number and Left and Right switch between.
    private var visibleTabs: [CommandPaletteTab] {
        CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab, enabled: preferences.enabledCapabilities)
    }

    /// Whether the open tab lays its items out in a grid. `/`'s list of filters is always a list.
    private var isGridTab: Bool {
        filterMenu == nil && (state.tab == .screenshots || tabContent?.isGrid(query: state.historyQuery) == true)
    }

    private var isScreenshotGrid: Bool { state.tab == .screenshots && filterMenu == nil }

    /// The filters `/` lists while the search field starts with it, or nil.
    private var filterMenu: [PaletteFilter]? {
        PaletteFilter.menu(in: state.tab, query: activeQuery, searchFindsEmoji: preferences.quickSearchFindsEmoji)
    }

    /// Emoji Picker's part in Quick Search (#333): the emoji a query finds, and what using one
    /// records. `matches` returns none while it's off or Show emoji in Quick Search is.
    func setQuickSearchEmoji(
        matches: @escaping (_ query: String) -> [QuickSearchEmoji],
        use: @escaping (QuickSearchEmoji) -> Void
    ) {
        search.emoji = matches
        useQuickSearchEmoji = use
    }

    /// Copies a Quick Search emoji, or with `paste` pastes it and puts the clipboard back, as the
    /// Emoji tab does.
    func chooseQuickSearchEmoji(_ emoji: QuickSearchEmoji, paste: Bool) {
        useQuickSearchEmoji(emoji)
        if paste {
            pasteText(emoji.glyph, restoresClipboard: true, for: .emojiPicker)
        } else {
            copyText(emoji.glyph)
        }
    }

    /// Applies a filter from `/`'s list and clears the `/` from the search field.
    func chooseFilter(_ filter: PaletteFilter) {
        state.filter = filter
        if state.tab == .search { search.query = "" } else { state.historyQuery = "" }
        state.selection = 0
        state.isBrowsingGrid = false
    }

    /// Outside a grid's items: Down goes into them, at the first; Left and Right switch tabs.
    private func enterGrid(or move: PaletteMove) {
        switch move {
        case .down:
            guard itemCount > 0 else { return }
            state.selection = 0
            state.isBrowsingGrid = true
        case .left, .right:
            switchTab(by: move == .right ? 1 : -1)
        case .up:
            break
        }
    }

    /// Up from a grid's top row hands the arrow keys back to the tabs.
    private func leaveGrid() {
        state.isBrowsingGrid = false
        state.selection = 0
    }

    /// Switches to the tab beside this one in the tab bar, if there is one.
    private func switchTab(by offset: Int) {
        guard let tab = CommandPaletteTab.adjacent(to: state.tab, offset: offset, in: visibleTabs) else { return }
        selectTab(tab)
    }

    /// Whether an input method (Japanese, Chinese, and so on) is composing in the search field,
    /// where Left and Right move between the parts being converted.
    private var isComposingText: Bool {
        (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    private var activeQuery: String {
        state.tab == .search ? search.query : state.historyQuery
    }

    /// Deletes the highlighted row in the tabs where Delete removes items.
    private func deleteSelection() -> Bool {
        let index = state.selection
        if let tabContent {
            guard tabContent.delete(row: index, query: state.historyQuery) else { return false }
            state.selection = min(index, max(0, itemCount - 1))
            return true
        }
        switch state.tab {
        case .search:
            guard search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  recentSearchItems.indices.contains(index) else { return false }
            search.recentItems.delete(recentSearchItems[index])
        case .clipboard:
            guard filteredClipboard.indices.contains(index) else { return false }
            clipboard.removeFromClipboardTab(filteredClipboard[index])
        case .screenshots:
            let entries = screenshotContent.entries
            guard entries.indices.contains(index) else { return false }
            clipboard.delete(entries[index])
        case .dictation:
            // A recording can't be made again, and a hover on the way to Delete can change which
            // one is highlighted, so Delete asks first.
            guard filteredDictations.indices.contains(index) else { return false }
            requestDictationDeletion(filteredDictations[index])
            return true
        case .snippets:
            // Snippets are things you wrote, not history, so Delete asks first.
            let entries = snippetContent.entries
            guard entries.indices.contains(index) else { return false }
            requestSnippetDeletion(entries[index])
            return true
        default:
            // Module tabs answer above.
            return false
        }
        state.selection = min(index, max(0, itemCount - 1))
        return true
    }

    private var screenshotContent: ScreenshotPaletteContent {
        ScreenshotPaletteContent.resolve(
            entries: state.filter.apply(clipboard.entries) { $0.matches($1) },
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools)
        )
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = state.filter.apply(clipboard.clipboardTabEntries) { $0.matches($1) }
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.matches(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        DictationPaletteResults.filter(state.filter.apply(dictationHistory.entries) { $0.matches($1) }, query: state.historyQuery)
    }

    /// Quick Search's results and recent items, narrowed by the chosen filter.
    private var searchItems: [QuickSearchItem] {
        QuickSearchEmoji.limited(state.filter.apply(search.items) { $0.matches($1) }, showsAll: state.filter == .emoji)
    }

    private var recentSearchItems: [RecentItem] {
        state.filter.apply(search.displayedRecentItems) { $0.matches(.result($1.result)) }
    }

    private var snippetContent: SnippetPaletteContent {
        SnippetPaletteContent.resolve(
            snippets: snippets.snippets,
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.snippets),
            libraryState: snippets.libraryState
        )
    }

    private func activateSelection(reveal: Bool) {
        if let filterMenu {
            if filterMenu.indices.contains(state.selection) { chooseFilter(filterMenu[state.selection]) }
            return
        }
        if let tabContent {
            tabContent.activate(row: state.selection, query: state.historyQuery, withCommand: reveal, palette: contentActions)
            return
        }
        switch state.tab {
        case .search:
            if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard recentSearchItems.indices.contains(state.selection) else { return }
                open(recentSearchItems[state.selection].result)
                return
            }
            guard searchItems.indices.contains(state.selection) else { return }
            switch searchItems[state.selection] {
            case .command(let command):
                choose(command)
            case .snippet(let snippet):
                reveal ? pasteSnippet(snippet) : copySnippet(snippet)
            case .emoji(let emoji):
                chooseQuickSearchEmoji(emoji, paste: reveal)
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
        case .screenshots:
            let entries = screenshotContent.entries
            guard entries.indices.contains(state.selection) else { return }
            chooseScreenshot(entries[state.selection], withCommand: reveal)
        case .snippets:
            // Return copies; Command-Return pastes into the app in front.
            let entries = snippetContent.entries
            guard entries.indices.contains(state.selection) else { return }
            reveal ? pasteSnippet(entries[state.selection]) : copySnippet(entries[state.selection])
        default:
            // Module tabs answer above.
            break
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

    /// A module tab's copy: kept out of Clipboard History, then the palette closes and the notch
    /// confirms it.
    func copyText(_ text: String) {
        _ = copy(text, suppressClipboardHistory: true)
    }

    /// Command-Return on a snippet: pastes it (`pasteText`), counting it as used either way.
    func pasteSnippet(_ snippet: Snippet) {
        guard let text = snippetText(snippet) else { return }
        pasteText(text, concealed: snippet.isSensitive, restoresClipboard: false, for: .snippets) { [weak self] in
            self?.snippets.markUsed(snippet.id)
        }
    }

    /// Closes the palette and pastes text into the app that was in front when the palette opened
    /// (the non-activating palette never took it over). When it can't paste, it copies instead and
    /// the notch notice says why (`PalettePasteRoute`). `used` runs once, either way. With
    /// `restoresClipboard`, what was on the clipboard comes back once the paste has been read, unless
    /// something else was copied by then. Snippets' ⌘Return and a module tab's paste both come here;
    /// `plugin` is the one pasting, named in the Accessibility setup offer.
    func pasteText(_ text: String, concealed: Bool = false, restoresClipboard: Bool, for plugin: Capability, used: @escaping () -> Void = {}) {
        let route = PalettePasteRoute.beforeClosing(canPaste: canPaste(), target: pasteTarget)
        guard route == .paste, let target = pasteTarget else {
            dismiss()
            copyInstead(text, concealed: concealed, notice: route.notice)
            used()
            if route == .copy(.needsAccessibility) { offerPasteSetup(plugin) }
            return
        }
        dismiss()
        used()
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
            guard PalettePasteRoute.canPasteNow(
                into: target,
                frontmost: self.frontmostApp(),
                paletteIsVisible: self.panel?.isVisible == true,
                isStillWanted: isStillWanted
            ) else {
                self.copyInstead(text, concealed: concealed, notice: PalettePasteRoute.Reason.targetChanged.notice)
                return
            }
            let previous = restoresClipboard ? self.clipboardRestorer.clipboardBeforePaste() : nil
            do {
                try paster.paste(text, concealed: concealed)
            } catch {
                // The text still ends up on the clipboard, ready to paste by hand.
                self.copyInstead(text, concealed: concealed, notice: PalettePasteRoute.Reason.pasteFailed.notice)
                return
            }
            if let previous { self.clipboardRestorer.restore(previous) }
        }
    }

    /// Puts the text on the clipboard, kept out of Clipboard History, and says why it didn't paste.
    private func copyInstead(_ text: String, concealed: Bool, notice: String?) {
        guard pasteboard.writeText(text, concealed: concealed) else { return }
        clipboard.suppressCurrentChange()
        if let notice { showWarning(notice) }
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

    /// Shows the Delete confirmation for a recording.
    func requestDictationDeletion(_ entry: DictationHistoryEntry) {
        state.dictationPendingDeletion = entry
        isPresentingConfirmation = true
    }

    /// The confirmation's Delete: removes the recording, keeping the highlight on a row that exists.
    func deleteDictation(_ entry: DictationHistoryEntry) {
        dictationHistory.delete(entry)
        state.selection = min(state.selection, max(0, itemCount - 1))
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
    @Bindable var preferences: AppPreferences
    @Bindable var snippets: SnippetStore
    let tabContents: [CommandPaletteTab: any CapabilityPaletteContent]
    let contentActions: PaletteContentActions
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
    /// Delete on a recording asks first (`requestDictationDeletion`); the alert's Delete deletes.
    let requestDictationDeletion: (DictationHistoryEntry) -> Void
    let deleteDictation: (DictationHistoryEntry) -> Void
    let confirmationPresentationChanged: (Bool) -> Void
    let chooseFilter: (PaletteFilter) -> Void
    /// Copies (false) or pastes (true) an emoji from Quick Search's results.
    let chooseEmoji: (QuickSearchEmoji, Bool) -> Void
    let dismiss: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaletteSearchField(
                tab: state.tab,
                searchQuery: $search.query,
                historyQuery: $state.historyQuery,
                filter: $state.filter,
                focused: $inputFocused
            )
            PaletteTabBar(
                tabs: CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab, enabled: preferences.enabledCapabilities),
                selected: state.tab,
                showsShortcuts: state.isCommandHeld,
                select: selectTab
            )
            content
                .environment(\.paletteRevealsSelection, !state.selectionFollowsPointer)
                // The pointer moving anywhere over the rows, gaps and empty space included, so a
                // row that appears under it later can tell it was resting.
                .onContinuousHover { phase in
                    if case .active = phase { state.notePointer() }
                }
                .contentMargins(.bottom, 56, for: .scrollContent)
                .overlay(alignment: .bottom) {
                    PaletteFooter(
                        tab: state.tab,
                        isGrid: PaletteFilter.menu(in: state.tab, query: state.tab == .search ? search.query : state.historyQuery) == nil
                            && (state.tab == .screenshots || tabContents[state.tab]?.isGrid(query: state.historyQuery) == true),
                        isBrowsingGrid: state.isBrowsingGrid,
                        isChoosingFilter: PaletteFilter.menu(
                            in: state.tab, query: state.tab == .search ? search.query : state.historyQuery, searchFindsEmoji: preferences.quickSearchFindsEmoji
                        ) != nil,
                        isSearchEmpty: (state.tab == .search ? search.query : state.historyQuery).isEmpty,
                        selectedSearchItem: state.tab == .search
                            ? QuickSearchModel.highlightedItem(in: searchItems, query: search.query, selection: state.selection)
                            : nil,
                        contentActions: tabContents[state.tab]?.footerActions(row: state.selection, query: state.historyQuery),
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
        // No SwiftUI shadow: the view fills the window, so one could only draw in the corners
        // outside the rounded shape, cut off square at the window's edge (#309). The window's own
        // shadow (`hasShadow`) follows the rounded shape.
        .defaultFocus($inputFocused, true)
        // Selecting a tab already starts it on its first row, or the row its content picks when it
        // shows, so a tab change only moves focus.
        .onChange(of: state.tab) {
            inputFocused = true
        }
        .onChange(of: search.query) {
            if state.tab == .search { state.selection = 0 }
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
        if let filters = PaletteFilter.menu(
            in: state.tab, query: state.tab == .search ? search.query : state.historyQuery, searchFindsEmoji: preferences.quickSearchFindsEmoji
        ) {
            PaletteFilterMenu(filters: filters, selection: state.selection, choose: chooseFilter)
        } else if let tabContent = tabContents[state.tab] {
            tabContent.makeView(PaletteContentContext(
                query: state.historyQuery,
                // A grid highlights nothing until Down goes into it.
                selection: tabContent.isGrid(query: state.historyQuery) && !state.isBrowsingGrid ? -1 : state.selection,
                actions: contentActions,
                confirmationPresentationChanged: confirmationPresentationChanged
            ))
        } else {
            builtInContent
        }
    }

    /// The tabs the palette still draws itself.
    @ViewBuilder
    private var builtInContent: some View {
        switch state.tab {
        case .search:
            SearchResultsView(
                items: searchItems,
                selection: state.selection,
                query: search.query,
                enabledCapabilities: preferences.enabledCapabilities,
                visibleTabs: CommandPaletteTab.visibleTabs(showsHotkeys: preferences.showsHotkeysTab, selected: state.tab, enabled: preferences.enabledCapabilities),
                recentItems: recentSearchItems,
                open: activateSearchResult,
                reveal: revealSearchResult,
                run: chooseCommand,
                snippetActions: snippetActions,
                chooseEmoji: chooseEmoji,
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
                requestDelete: requestDictationDeletion,
                delete: deleteDictation,
                pendingDeletion: $state.dictationPendingDeletion,
                clear: dictationHistory.clear,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
            .environment(\.dictationTranslationPair, preferences.dictationTranslationPair)
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
                    selection: state.isBrowsingGrid ? state.selection : -1,
                    select: {
                        state.selection = $0
                        state.isBrowsingGrid = true
                    },
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
        default:
            // Module tabs are drawn by their content, above.
            EmptyView()
        }
    }

    private var screenshotContent: ScreenshotPaletteContent {
        ScreenshotPaletteContent.resolve(
            entries: state.filter.apply(clipboard.entries) { $0.matches($1) },
            query: state.historyQuery,
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools)
        )
    }

    private var filteredClipboard: [ClipboardEntry] {
        let query = state.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = state.filter.apply(clipboard.clipboardTabEntries) { $0.matches($1) }
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.matches(query) }
    }

    private var filteredDictations: [DictationHistoryEntry] {
        DictationPaletteResults.filter(state.filter.apply(dictationHistory.entries) { $0.matches($1) }, query: state.historyQuery)
    }

    /// Quick Search's results and recent items, narrowed by the chosen filter.
    private var searchItems: [QuickSearchItem] {
        QuickSearchEmoji.limited(state.filter.apply(search.items) { $0.matches($1) }, showsAll: state.filter == .emoji)
    }

    private var recentSearchItems: [RecentItem] {
        state.filter.apply(search.displayedRecentItems) { $0.matches(.result($1.result)) }
    }

}

/// The palette's tabs as icons, Raycast-style (#182): the open tab also shows its name, and the
/// ⌘-numbers show only while ⌘ is held. If even that doesn't fit, the name goes too, so the bar can
/// never widen the palette past its window, which cut off its rounded corners once eight tabs had
/// names.
struct PaletteTabBar: View {
    let tabs: [CommandPaletteTab]
    let selected: CommandPaletteTab
    /// Whether ⌘ is held, which shows each tab's ⌘-number.
    var showsShortcuts = false
    let select: (CommandPaletteTab) -> Void
    /// A tab's label height, with or without its ⌘-number keycaps.
    static let labelHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                tabRow(namesSelected: true)
                tabRow(namesSelected: false)
            }
            Spacer(minLength: 8)
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

    /// The tabs with the open one named, or icons only: what `ViewThatFits` chooses between.
    func tabRow(namesSelected: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(tab, showsName: namesSelected && tab == selected)
            }
        }
    }

    private func tabButton(_ tab: CommandPaletteTab, showsName: Bool) -> some View {
        let label = tab.labelPresentation
        return Button {
            select(tab)
        } label: {
            HStack(spacing: 6) {
                if showsShortcuts {
                    PaletteKeycaps(shortcut: label.shortcut)
                }
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18, height: 18)
                if showsName {
                    Text(label.name)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // The keycaps' height, so holding ⌘ doesn't move the palette's content down.
            .frame(height: PaletteTabBar.labelHeight)
            .font(.system(size: 14))
            .foregroundStyle(selected == tab ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                selected == tab ? PaletteTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: PaletteTheme.rowRadius - 2, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label.name) (\(label.shortcut))")
        .accessibilityLabel(label.name)
        .accessibilityHint(KeyboardShortcutRegistry.accessibilityCopy(for: label.shortcut))
        .accessibilityAddTraits(selected == tab ? .isSelected : [])
        .accessibilityIdentifier("palette.tab.\(tab.rawValue)")
    }
}

private struct PaletteSearchField: View {
    let tab: CommandPaletteTab
    @Binding var searchQuery: String
    @Binding var historyQuery: String
    /// The filter chosen from `/`'s list, shown as a chip before the text.
    @Binding var filter: PaletteFilter?
    var focused: FocusState<Bool>.Binding

    /// The tab's own placeholder, which the UI tests find the field by, until a filter is chosen.
    private var prompt: String {
        guard let filter else { return tab.prompt }
        return "Search \(filter.title.lowercased())"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            if let filter {
                PaletteFilterChip(filter: filter) { self.filter = nil }
            }
            if tab == .search {
                TextField(prompt, text: $searchQuery)
                    .focused(focused)
            } else {
                TextField(prompt, text: $historyQuery)
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
    let chooseEmoji: (QuickSearchEmoji, Bool) -> Void
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
                        ScrollViewReader { proxy in
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
                                .paletteHoverHighlights(row: index)
                                .paletteRowBackground(isSelected: index == selection)
                                .id(item.id)
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .paletteScrollsToSelection(selection, proxy: proxy) { recentItems.indices.contains($0) ? recentItems[$0].id : nil }
                        }
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
                            case .emoji(let emoji):
                                Button {
                                    chooseEmoji(emoji, false)
                                } label: {
                                    QuickSearchEmojiRow(emoji: emoji)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Copy") { chooseEmoji(emoji, false) }
                                    Button("Paste") { chooseEmoji(emoji, true) }
                                }
                                .accessibilityAction(named: "Paste") { chooseEmoji(emoji, true) }
                                .accessibilityHint("Copies the emoji")
                                .accessibilityIdentifier("quickSearch.emoji")
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
                        .paletteHoverHighlights(row: index)
                        .paletteRowBackground(isSelected: index == selection)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .paletteScrollsToSelection(selection, proxy: proxy) { items.indices.contains($0) ? items[$0].id : nil }
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

/// An emoji in Quick Search's results (#333): the emoji where an icon goes, then its name.
private struct QuickSearchEmojiRow: View {
    let emoji: QuickSearchEmoji

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji.glyph)
                .font(.system(size: 20))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(emoji.name.prefix(1).uppercased() + emoji.name.dropFirst())
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("Emoji")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
        case .plugins:
            SettingsIconTile(systemImage: SettingsSection.plugins.icon, tint: .indigo, size: 24)
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
                    ScrollViewReader { proxy in
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
                                .paletteHoverHighlights(row: index)
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .paletteScrollsToSelection(selection, proxy: proxy) { entries.indices.contains($0) ? entries[$0].id : nil }
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

extension PaletteFooterActions {
    /// What the footer names: a module tab's actions for its selected row, else Quick Search's
    /// highlighted row's (a snippet copies and pastes), else the tab's registered titles.
    static func resolve(tab: CommandPaletteTab, searchItem: QuickSearchItem?, content: PaletteFooterActions?) -> PaletteFooterActions {
        if let content { return content }
        return PaletteFooterActions(
            primary: searchItem?.primaryActionTitle ?? tab.primaryActionTitle,
            secondary: searchItem?.secondaryActionTitle ?? tab.secondaryActionTitle
        )
    }
}

/// Raycast's footer: a round Settings button at the bottom left, and a floating pill at the bottom
/// right with the tab's actions and their keys.
private struct PaletteFooter: View {
    let tab: CommandPaletteTab
    /// Whether Left and Right move the selection too.
    let isGrid: Bool
    /// Whether Down has gone into the grid, so the arrow keys move through its items.
    let isBrowsingGrid: Bool
    /// Whether `/`'s list of filters is showing, whose rows Return applies.
    let isChoosingFilter: Bool
    /// Whether the search field is empty, so Left and Right switch tabs rather than move the caret.
    let isSearchEmpty: Bool
    /// Quick Search's highlighted row, whose actions the footer names (a snippet copies and pastes).
    let selectedSearchItem: QuickSearchItem?
    /// A module tab's actions for its selected row; they replace the tab's registered titles.
    let contentActions: PaletteFooterActions?
    let openSettings: () -> Void

    private var actions: PaletteFooterActions {
        if isChoosingFilter { return PaletteFooterActions(primary: "Filter", secondary: nil) }
        return PaletteFooterActions.resolve(tab: tab, searchItem: selectedSearchItem, content: contentActions)
    }
    private var primaryActionTitle: String? { actions.primary }
    private var secondaryActionTitle: String? { actions.secondary }

    var body: some View {
        HStack {
            PaletteSettingsButton(action: openSettings)
            Spacer()
            HStack(spacing: 14) {
                hint("Select", keys: isGrid ? (isBrowsingGrid ? ["←", "→", "↑", "↓"] : ["↓"]) : ["↑", "↓"], isPrimary: false)
                if !(isGrid && isBrowsingGrid), isSearchEmpty {
                    hint("Change Tab", keys: ["←", "→"], isPrimary: false)
                }
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
