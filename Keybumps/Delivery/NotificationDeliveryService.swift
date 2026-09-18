import Foundation

@MainActor
protocol ChannelDelivering {
    func deliver(_ event: CoachingEvent) async throws
}

enum PreviewChannelPlan {
    static func channels(
        for clickedChannel: NotificationChannel,
        selectedChannels: Set<NotificationChannel>
    ) -> Set<NotificationChannel> {
        guard clickedChannel != .sound, selectedChannels.contains(.sound) else {
            return [clickedChannel]
        }
        return [clickedChannel, .sound]
    }
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
        await preview(event, through: [channel])[channel] ?? .failed("No adapter is available")
    }

    func preview(
        _ event: CoachingEvent,
        through channels: Set<NotificationChannel>
    ) async -> [NotificationChannel: DeliveryOutcome] {
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
        return outcomes
    }
}
