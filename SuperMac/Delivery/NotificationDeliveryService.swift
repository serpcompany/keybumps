import Foundation

@MainActor
protocol ChannelDelivering {
    func deliver(_ event: CoachingEvent) async throws
}

@MainActor
final class NotificationDeliveryService {
    private let inbox: InboxStore
    private let adapters: [NotificationChannel: any ChannelDelivering]

    init(inbox: InboxStore, adapters: [NotificationChannel: any ChannelDelivering]) {
        self.inbox = inbox
        self.adapters = adapters
    }

    func deliver(_ event: CoachingEvent, through channels: Set<NotificationChannel>) async -> DeliveryReport {
        do {
            try inbox.append(event)
        } catch {
            return DeliveryReport(eventID: event.id, inboxRecorded: false, outcomes: [:])
        }

        var outcomes: [NotificationChannel: DeliveryOutcome] = [:]
        for channel in channels.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let adapter = adapters[channel] else {
                outcomes[channel] = .failed("No adapter is available")
                continue
            }
            do {
                try await adapter.deliver(event)
                outcomes[channel] = .delivered
            } catch {
                outcomes[channel] = .failed(error.localizedDescription)
            }
        }

        return DeliveryReport(eventID: event.id, inboxRecorded: true, outcomes: outcomes)
    }

    func preview(_ event: CoachingEvent, through channel: NotificationChannel) async -> DeliveryOutcome {
        guard let adapter = adapters[channel] else { return .failed("No adapter is available") }
        do {
            try await adapter.deliver(event)
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
