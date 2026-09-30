import Foundation

enum ShortcutProvenance: Codable, Equatable, Sendable {
    case liveAX
    case characterizedDefault(adapterID: String, compatibleApplicationVersion: String)
    case legacyUnknown
}

struct CoachingEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let applicationName: String
    let actionTitle: String
    let shortcut: String
    let rawShortcutEvidence: AXShortcutEvidence?
    let shortcutProvenance: ShortcutProvenance
    var isRead: Bool

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        applicationName: String,
        actionTitle: String,
        shortcut: String,
        rawShortcutEvidence: AXShortcutEvidence? = nil,
        shortcutProvenance: ShortcutProvenance = .legacyUnknown,
        isRead: Bool = false
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.applicationName = applicationName
        self.actionTitle = actionTitle
        self.shortcut = shortcut
        self.rawShortcutEvidence = rawShortcutEvidence
        self.shortcutProvenance = shortcutProvenance
        self.isRead = isRead
    }

    static let sample = CoachingEvent(
        applicationName: "Finder",
        actionTitle: "Open New Window",
        shortcut: "⌘N"
    )

    var canonicalShortcut: CanonicalKeyboardShortcut? {
        KeyboardShortcutRegistry.resolve(displayString: shortcut)
    }

    private enum CodingKeys: String, CodingKey {
        case id, occurredAt, applicationName, actionTitle, shortcut
        case rawShortcutEvidence, shortcutProvenance, isRead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        actionTitle = try container.decode(String.self, forKey: .actionTitle)
        shortcut = try container.decode(String.self, forKey: .shortcut)
        rawShortcutEvidence = try container.decodeIfPresent(AXShortcutEvidence.self, forKey: .rawShortcutEvidence)
        shortcutProvenance = try container.decodeIfPresent(ShortcutProvenance.self, forKey: .shortcutProvenance)
            ?? .legacyUnknown
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(applicationName, forKey: .applicationName)
        try container.encode(actionTitle, forKey: .actionTitle)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encodeIfPresent(rawShortcutEvidence, forKey: .rawShortcutEvidence)
        try container.encode(shortcutProvenance, forKey: .shortcutProvenance)
        try container.encode(isRead, forKey: .isRead)
    }
}

enum CoachingEventFactory {
    static func make(
        applicationName: String,
        actionTitle: String,
        shortcutEvidence: AXShortcutEvidence
    ) -> CoachingEvent? {
        guard let shortcut = KeyboardShortcutRegistry.resolve(shortcutEvidence) else { return nil }
        return make(
            applicationName: applicationName,
            actionTitle: actionTitle,
            shortcut: shortcut,
            rawShortcutEvidence: shortcutEvidence,
            provenance: .liveAX
        )
    }

    static func makeCharacterized(
        applicationName: String,
        actionTitle: String,
        displayShortcut: String,
        adapterID: String,
        compatibleApplicationVersion: String
    ) -> CoachingEvent? {
        guard let shortcut = KeyboardShortcutRegistry.resolve(displayString: displayShortcut) else { return nil }
        return make(
            applicationName: applicationName,
            actionTitle: actionTitle,
            shortcut: shortcut,
            rawShortcutEvidence: nil,
            provenance: .characterizedDefault(
                adapterID: adapterID,
                compatibleApplicationVersion: compatibleApplicationVersion
            )
        )
    }

    private static func make(
        applicationName: String,
        actionTitle: String,
        shortcut: CanonicalKeyboardShortcut,
        rawShortcutEvidence: AXShortcutEvidence?,
        provenance: ShortcutProvenance
    ) -> CoachingEvent {
        return CoachingEvent(
            applicationName: applicationName,
            actionTitle: actionTitle,
            shortcut: shortcut.displayString,
            rawShortcutEvidence: rawShortcutEvidence,
            shortcutProvenance: provenance
        )
    }
}
