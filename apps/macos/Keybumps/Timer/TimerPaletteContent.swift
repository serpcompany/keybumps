import SwiftUI

/// One row of the Timers tab. While the search field has text, the first row says what Return
/// will start, or why it won't; the timers follow.
enum TimerPaletteRow: Equatable, Identifiable {
    case start(TimerDurationParser.Parsed)
    case tooLong
    case unreadable
    case timer(TimerItem)

    var id: String {
        switch self {
        case .start, .tooLong, .unreadable: "new"
        case .timer(let item): item.id.uuidString
        }
    }

    static func resolve(query: String, timers: [TimerItem]) -> [TimerPaletteRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return timers.map(Self.timer) }
        let first: TimerPaletteRow = switch TimerDurationParser.parse(text) {
        case .some(let parsed) where parsed.duration > TimerDurationParser.maximumDuration: .tooLong
        case .some(let parsed): .start(parsed)
        case .none: .unreadable
        }
        return [first] + timers.map(Self.timer)
    }

    /// What the footer says Return does on the row.
    var returnAction: String? {
        switch self {
        case .start: "Start"
        case .tooLong, .unreadable: nil
        case .timer(let item):
            switch item.state {
            case .running: "Pause"
            case .paused: "Resume"
            case .finished: "Restart"
            }
        }
    }
}

/// The Timers tab's rows, supplied by `TimerModule`. Typing is the input for a new timer, so the
/// rows aren't filtered and the selection goes back to the top as you type.
@MainActor
final class TimerPaletteContent: CapabilityPaletteContent {
    let tab = CommandPaletteTab.timers
    let resetsSelectionWhileTyping = true
    private let store: TimerStore
    private let preferences: AppPreferences
    private let notices: any PaletteNoticePresenting
    /// Runs each time the tab shows, so its finished timers count as seen.
    var shown: () -> Void = {}
    /// The timer the highlight was last drawn on, and how to move it, so it can stay on that timer
    /// when the list reorders under it.
    private var drawnSelection: (timerID: UUID, query: String, actions: PaletteContentActions)?

    init(store: TimerStore, preferences: AppPreferences, notices: any PaletteNoticePresenting) {
        self.store = store
        self.preferences = preferences
        self.notices = notices
    }

    /// Timers run only while Timer is on and Keybumps is set up and licensed (`TimerStore.isActive`),
    /// so the tab offers nothing to start before then.
    private var isRunning: Bool { preferences.enabledCapabilities.contains(.timer) && store.isActive }

    private func rows(query: String) -> [TimerPaletteRow] {
        isRunning ? TimerPaletteRow.resolve(query: query, timers: store.displayed) : []
    }

    /// Where a timer's row is now, after pausing or finishing moved it to another section.
    private func row(of id: UUID, query: String) -> Int? {
        rows(query: query).firstIndex { if case .timer(let item) = $0 { item.id == id } else { false } }
    }

    /// Moves the highlight back onto the timer it was on, as after one finished and jumped to the
    /// top while the tab was open.
    func keepSelectionOnSameTimer() {
        guard let drawnSelection, let row = row(of: drawnSelection.timerID, query: drawnSelection.query) else { return }
        drawnSelection.actions.selectRow(row)
    }

    func rowCount(query: String) -> Int {
        rows(query: query).count
    }

    /// Return starts the typed timer and closes the palette; on a timer it pauses, resumes, or
    /// restarts it.
    func activate(row: Int, query: String, palette: PaletteContentActions) {
        let rows = rows(query: query)
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .start(let parsed):
            let item = store.start(duration: parsed.duration, name: parsed.name)
            palette.dismiss()
            notices.showNotice("\(item.title) started", isWarning: false)
        case .tooLong, .unreadable:
            break
        case .timer(let item):
            item.isFinished ? store.restart(item.id) : store.togglePause(item.id)
            // It moved to another section; the highlight follows it.
            if let moved = self.row(of: item.id, query: query) { palette.selectRow(moved) }
        }
    }

    /// Delete cancels a running or paused timer, or clears a finished one.
    func delete(row: Int, query: String) -> Bool {
        let rows = rows(query: query)
        guard rows.indices.contains(row), case .timer(let item) = rows[row] else { return false }
        store.remove(item.id)
        return true
    }

    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        let rows = rows(query: query)
        return PaletteFooterActions(primary: rows.indices.contains(row) ? rows[row].returnAction : nil)
    }

    func didShow(palette: PaletteContentActions) {
        shown()
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let rows = rows(query: context.query)
        if rows.indices.contains(context.selection), case .timer(let item) = rows[context.selection] {
            drawnSelection = (item.id, context.query, context.actions)
        } else {
            drawnSelection = nil
        }
        return AnyView(TimerPaletteResults(
            store: store,
            preferences: preferences,
            query: context.query,
            selection: context.selection,
            select: context.actions.selectRow
        ))
    }
}

/// The Timers tab: the new-timer row while you type, then Finished, Running, and Paused timers,
/// each with a ring for the time left. It redraws each second only while a timer runs and the
/// palette is on screen (an animation timeline follows the display).
private struct TimerPaletteResults: View {
    @Bindable var store: TimerStore
    @Bindable var preferences: AppPreferences
    let query: String
    let selection: Int
    let select: (Int) -> Void

    var body: some View {
        PaletteResultsContainer {
            if !preferences.enabledCapabilities.contains(.timer) {
                PaletteEmptyState(title: "Timer is turned off", systemImage: "timer")
            } else if !store.isActive {
                PaletteEmptyState(title: "Timers start once Keybumps is set up", systemImage: "timer")
            } else {
                // The time comes from the store's clock; the timeline only asks for a redraw.
                // It also runs while typing, so the new-timer row's end time stays current.
                let ticks = store.items.contains(where: \.isRunning) || !query.trimmingCharacters(in: .whitespaces).isEmpty
                TimelineView(.animation(minimumInterval: 1, paused: !ticks)) { _ in
                    let rows = TimerPaletteRow.resolve(query: query, timers: store.displayed)
                    if rows.isEmpty {
                        PaletteEmptyState(title: "Type a duration, like 5m or tea 25, and press Return", systemImage: "timer")
                    } else {
                        list(rows, now: store.now())
                    }
                }
            }
        }
    }

    private func list(_ rows: [TimerPaletteRow], now: Date) -> some View {
        ScrollViewReader { proxy in
            timerList(rows, now: now)
                .paletteScrollsToSelection(selection, proxy: proxy) { rows.indices.contains($0) ? rows[$0].id : nil }
        }
    }

    private func timerList(_ rows: [TimerPaletteRow], now: Date) -> some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let header = header(for: row, after: index > 0 ? rows[index - 1] : nil) {
                    PaletteSectionHeader(header)
                        .padding(.horizontal, 12)
                        .padding(.top, index > 0 ? 6 : 4)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                Button { select(index) } label: {
                    TimerRowView(row: row, now: now)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(.init())
                .listRowSeparator(.hidden)
                .paletteHoverHighlights(row: index)
                .paletteRowBackground(isSelected: index == selection)
                .accessibilityIdentifier(row.id == "new" ? "palette.timers.new" : "palette.timers.row")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A section header above the first row of each kind.
    private func header(for row: TimerPaletteRow, after previous: TimerPaletteRow?) -> String? {
        let title = Self.section(of: row)
        return previous.map(Self.section) == title ? nil : title
    }

    private static func section(of row: TimerPaletteRow) -> String {
        switch row {
        case .start, .tooLong, .unreadable: "New Timer"
        case .timer(let item):
            switch item.state {
            case .running: "Running"
            case .paused: "Paused"
            case .finished: "Finished"
            }
        }
    }
}

private struct TimerRowView: View {
    let row: TimerPaletteRow
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            ring
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// What VoiceOver says for the row: the time left as a length, never as a time of day.
    private var spokenLabel: String {
        switch row {
        case .start(let parsed):
            "Start \(parsed.name ?? "a timer"), \(TimerText.spokenLength(parsed.duration)), ends at \(TimerText.time(now.addingTimeInterval(parsed.duration)))"
        case .tooLong: title
        case .unreadable: title
        case .timer(let item):
            switch item.state {
            case .running(let endsAt):
                "\(item.title), running, \(TimerText.spokenLength(item.remaining(at: now))) left, ends at \(TimerText.time(endsAt))"
            case .paused(let remaining):
                "\(item.title), paused, \(TimerText.spokenLength(remaining)) left"
            case .finished(let at, _):
                "\(item.title), finished, ended \(TimerText.when(at, now: now))"
            }
        }
    }

    private var title: String {
        switch row {
        case .start(let parsed):
            parsed.name.map { "Start “\($0)”" } ?? "Start \(TimerText.length(parsed.duration)) timer"
        case .tooLong: "Timers can run up to 24 hours"
        case .unreadable: "Type a duration, like 5m, 1h30m, or tea 25"
        case .timer(let item): item.title
        }
    }

    private var subtitle: String? {
        switch row {
        case .start(let parsed): "ends at \(TimerText.time(now.addingTimeInterval(parsed.duration)))"
        case .tooLong, .unreadable: nil
        case .timer(let item):
            switch item.state {
            case .running(let endsAt): "\(TimerText.length(item.duration)) · ends \(TimerText.time(endsAt))"
            case .paused: "\(TimerText.length(item.duration)) · paused"
            case .finished(let at, _): "\(TimerText.length(item.duration)) · ended \(TimerText.when(at, now: now))"
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row {
        case .start(let parsed):
            clock(TimerText.clock(parsed.duration), dimmed: false)
        case .tooLong, .unreadable:
            EmptyView()
        case .timer(let item):
            switch item.state {
            case .running:
                clock(TimerText.clock(item.remaining(at: now)), dimmed: false)
            case .paused(let remaining):
                HStack(spacing: 10) {
                    pill("Paused", color: .secondary, filled: false)
                    clock(TimerText.clock(remaining), dimmed: true)
                }
            case .finished:
                pill("Finished", color: .green, filled: true)
            }
        }
    }

    private func clock(_ text: String, dimmed: Bool) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(dimmed ? .secondary : .primary)
    }

    private func pill(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(filled ? color.opacity(0.15) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? .clear : Color.primary.opacity(0.16), lineWidth: 1))
    }

    /// The time left as a ring: orange while running, gray while paused, a green check once done,
    /// and a plus on the new-timer row.
    @ViewBuilder
    private var ring: some View {
        let size: CGFloat = 30
        switch row {
        case .start:
            Image(systemName: "plus.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.orange)
                .frame(width: size, height: size)
        case .tooLong, .unreadable:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        case .timer(let item):
            if item.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.green)
                    .frame(width: size, height: size)
            } else {
                let fraction = item.duration > 0 ? item.remaining(at: now) / item.duration : 0
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 3.5)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(item.isRunning ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size - 4, height: size - 4)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            }
        }
    }
}
