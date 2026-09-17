import SwiftUI

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
            Text(presentation.shortcut)
                .font(.headline.monospaced())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.actionTitle) in \(presentation.applicationName). Shortcut \(presentation.shortcut).")
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
