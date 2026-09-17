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

    var coachingTitle: String {
        guard let first = actionTitle.first else { return actionTitle }
        return String(first).uppercased() + actionTitle.dropFirst().lowercased()
    }

    var coachingBody: String { "\(applicationName) · \(shortcut)" }
}

enum CoachingEventFactory {
    static func make(
        applicationName: String,
        actionTitle: String,
        shortcutEvidence: AXShortcutEvidence,
        pointerX: Double? = nil,
        pointerY: Double? = nil
    ) -> CoachingEvent? {
        guard let shortcut = KeyboardShortcutRegistry.resolve(shortcutEvidence) else { return nil }
        return make(
            applicationName: applicationName,
            actionTitle: actionTitle,
            displayShortcut: shortcut.displayString,
            pointerX: pointerX,
            pointerY: pointerY
        )
    }

    static func make(
        applicationName: String,
        actionTitle: String,
        displayShortcut: String,
        pointerX: Double? = nil,
        pointerY: Double? = nil
    ) -> CoachingEvent? {
        guard let shortcut = KeyboardShortcutRegistry.resolve(displayString: displayShortcut) else { return nil }
        return CoachingEvent(
            applicationName: applicationName,
            actionTitle: actionTitle,
            shortcut: shortcut.displayString,
            pointerX: pointerX,
            pointerY: pointerY
        )
    }
}
