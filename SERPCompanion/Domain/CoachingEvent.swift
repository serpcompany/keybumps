import Foundation

struct CoachingEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let applicationName: String
    let actionTitle: String
    let shortcut: String
    let pointerX: Double?
    let pointerY: Double?
    var isRead: Bool

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        applicationName: String,
        actionTitle: String,
        shortcut: String,
        pointerX: Double? = nil,
        pointerY: Double? = nil,
        isRead: Bool = false
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.applicationName = applicationName
        self.actionTitle = actionTitle
        self.shortcut = shortcut
        self.pointerX = pointerX
        self.pointerY = pointerY
        self.isRead = isRead
    }

    static let sample = CoachingEvent(
        applicationName: "Finder",
        actionTitle: "Open New Window",
        shortcut: "⌘N"
    )

    var coachingTitle: String { "Try \(shortcut) next time" }
    var coachingBody: String { "\(actionTitle) in \(applicationName)" }
}
