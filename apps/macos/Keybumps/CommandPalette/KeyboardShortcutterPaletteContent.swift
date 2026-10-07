import SwiftUI

/// What the Hotkeys tab shows: Shortcut Coach's history, filtered by the search field.
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

/// The Hotkeys tab's rows, supplied by `KeyboardShortcutterModule`. They are read-only: Return and
/// Delete do nothing, and only the confirmed Clear All changes the history.
@MainActor
final class KeyboardShortcutterPaletteContent: CapabilityPaletteContent {
    let tab = CommandPaletteTab.keyboardShortcutter
    private let inbox: InboxStore
    private let preferences: AppPreferences

    init(inbox: InboxStore, preferences: AppPreferences) {
        self.inbox = inbox
        self.preferences = preferences
    }

    func rowCount(query: String) -> Int {
        content(query: query).entries.count
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        AnyView(KeyboardShortcutterResultsView(
            inbox: inbox,
            preferences: preferences,
            query: context.query,
            selection: context.selection,
            select: context.actions.selectRow,
            confirmationPresentationChanged: context.confirmationPresentationChanged
        ))
    }

    private func content(query: String) -> KeyboardShortcutterHistoryContent {
        KeyboardShortcutterHistoryContent.resolve(
            events: inbox.events,
            query: query,
            isEnabled: preferences.enabledCapabilities.contains(.keyboardShortcutter)
        )
    }
}

private struct KeyboardShortcutterResultsView: View {
    @Bindable var inbox: InboxStore
    @Bindable var preferences: AppPreferences
    let query: String
    let selection: Int
    let select: (Int) -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    private var content: KeyboardShortcutterHistoryContent {
        KeyboardShortcutterHistoryContent.resolve(
            events: inbox.events,
            query: query,
            isEnabled: preferences.enabledCapabilities.contains(.keyboardShortcutter)
        )
    }

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
                            clear: inbox.clear
                        )
                        .buttonStyle(PalettePillButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    ScrollViewReader { proxy in
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
                        .paletteHoverHighlights(row: index)
                        .paletteRowBackground(isSelected: index == selection)
                        .id(event.id)
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
