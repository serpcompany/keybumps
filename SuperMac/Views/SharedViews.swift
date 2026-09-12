import SwiftUI

struct CoachingEventRow: View {
    let event: CoachingEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(event.isRead ? Color.secondary.opacity(0.25) : Color.green)
                .frame(width: 9, height: 9)
                .padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.actionTitle).font(.headline)
                Text(event.applicationName).font(.subheadline).foregroundStyle(.secondary)
                Text(event.occurredAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(event.shortcut)
                .font(.headline.monospaced())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.actionTitle) in \(event.applicationName). Shortcut \(event.shortcut). \(event.isRead ? "Read" : "Unread")")
    }
}

struct EmptyInboxView: View {
    var body: some View {
        ContentUnavailableView(
            "No coaching yet",
            systemImage: "keyboard",
            description: Text("Manual actions with known shortcuts will appear here.")
        )
    }
}

