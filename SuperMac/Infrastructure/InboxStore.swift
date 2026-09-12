import Foundation
import Observation

protocol EventPersistence {
    func load() throws -> [CoachingEvent]
    func save(_ events: [CoachingEvent]) throws
}

struct JSONEventPersistence: EventPersistence {
    let url: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("SuperMac", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("coaching-events.json")
    }

    func load() throws -> [CoachingEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CoachingEvent].self, from: Data(contentsOf: url))
    }

    func save(_ events: [CoachingEvent]) throws {
        let data = try JSONEncoder().encode(events)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class InboxStore {
    private(set) var events: [CoachingEvent]
    private(set) var persistenceError: String?
    private let persistence: EventPersistence

    var unreadCount: Int { events.lazy.filter { !$0.isRead }.count }

    init(persistence: EventPersistence = JSONEventPersistence()) {
        self.persistence = persistence
        do {
            events = try persistence.load().sorted { $0.occurredAt > $1.occurredAt }
        } catch {
            events = []
            persistenceError = error.localizedDescription
        }
    }

    func append(_ event: CoachingEvent) throws {
        events.insert(event, at: 0)
        try persist()
    }

    func markRead(_ id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].isRead = true
        try? persist()
    }

    func markAllRead() {
        for index in events.indices { events[index].isRead = true }
        try? persist()
    }

    func clear() {
        events.removeAll()
        try? persist()
    }

    private func persist() throws {
        do {
            try persistence.save(events)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }
}
