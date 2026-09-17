import SwiftUI

struct ShortcutKeycapPresentation: Equatable {
    let keys: [String]
    let accessibilityDescription: String?

    init(shortcut: String) {
        keys = KeyboardShortcutRegistry.keycapTokens(for: shortcut)
        accessibilityDescription = KeyboardShortcutRegistry.accessibilityDescription(for: shortcut)
    }
}

struct ShortcutKeycaps: View {
    let shortcut: String
    var compact = false

    var body: some View {
        let presentation = ShortcutKeycapPresentation(shortcut: shortcut)
        HStack(spacing: compact ? 3 : 6) {
            ForEach(presentation.keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: compact ? 11 : 15, weight: .semibold, design: .rounded))
                    .frame(
                        minWidth: compact ? 18 : 24,
                        minHeight: compact ? 18 : 24
                    )
                    .padding(.horizontal, compact ? 1 : 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 4 : 6))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            presentationAccessibilityLabel(presentation.accessibilityDescription)
        )
    }

    private func presentationAccessibilityLabel(_ description: String?) -> String {
        description.map { "Shortcut \($0)" } ?? "Shortcut unavailable"
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
        guard let description = KeyboardShortcutRegistry.accessibilityDescription(for: event.shortcut) else {
            return "Shortcut unavailable"
        }
        return "Shortcut \(description)"
    }
}

struct EmptyInboxView: View {
    var body: some View {
        ContentUnavailableView(
            "No key bumps yet",
            systemImage: "keyboard",
            description: Text("Manual actions with known shortcuts will appear here.")
        )
    }
}
