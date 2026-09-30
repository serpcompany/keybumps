import SwiftUI

struct ShortcutKeycapPresentation: Equatable {
    let keys: [String]

    init(shortcut: String) {
        keys = KeyboardShortcutRegistry.keycapTokens(for: shortcut)
    }
}

struct ShortcutKeycapMetrics: Equatable {
    let fontSize: CGFloat
    let height: CGFloat
    let minimumWidth: CGFloat
    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat

    static func value(compact: Bool) -> ShortcutKeycapMetrics {
        compact
            ? ShortcutKeycapMetrics(fontSize: 11, height: 20, minimumWidth: 20, horizontalPadding: 4, cornerRadius: 5)
            : ShortcutKeycapMetrics(fontSize: 15, height: 28, minimumWidth: 28, horizontalPadding: 7, cornerRadius: 6)
    }
}

struct KeyboardKeycap: View {
    let label: String
    var compact = false

    var body: some View {
        let metrics = ShortcutKeycapMetrics.value(compact: compact)
        Text(label)
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minWidth: metrics.minimumWidth, minHeight: metrics.height, maxHeight: metrics.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
    }
}

struct ShortcutKeycaps: View {
    let shortcut: String
    var compact = false

    var body: some View {
        let presentation = ShortcutKeycapPresentation(shortcut: shortcut)
        HStack(spacing: compact ? 3 : 6) {
            ForEach(presentation.keys, id: \.self) { key in
                KeyboardKeycap(label: key, compact: compact)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KeyboardShortcutRegistry.accessibilityCopy(for: shortcut))
    }
}

struct CoachingEventRowPresentation: Equatable {
    let actionTitle: String
    let applicationName: String
    let shortcut: String

    init(event: CoachingEvent) {
        actionTitle = event.actionTitle
        applicationName = event.applicationName
        shortcut = event.shortcut
    }
}

struct CoachingEventRow: View {
    let event: CoachingEvent

    var body: some View {
        let presentation = CoachingEventRowPresentation(event: event)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.actionTitle).font(.headline)
                Text(presentation.applicationName).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutKeycaps(shortcut: presentation.shortcut)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(presentation.actionTitle) in \(presentation.applicationName). \(shortcutAccessibilityCopy)."
        )
    }

    private var shortcutAccessibilityCopy: String {
        KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut)
    }
}

struct EmptyInboxView: View {
    var body: some View {
        ContentUnavailableView(
            "No keyboard shortcut suggestions yet",
            systemImage: "keyboard",
            description: Text("Manual actions with known shortcuts will appear here.")
        )
    }
}
