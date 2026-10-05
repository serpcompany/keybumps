import AppKit
import Foundation
import Observation

/// Runs `action` on the main actor at a moment by the wall clock, so a timer that ends while the
/// Mac sleeps fires as soon as it wakes. Tests replace it and fire by hand.
@MainActor
protocol TimerScheduling {
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction
}

@MainActor
protocol TimerScheduledAction {
    func cancel()
}

/// The production scheduler: a one-shot, strict wall-clock dispatch timer on the main queue.
/// `asyncAfter` would let macOS coalesce the wake-up up to 60 seconds late; `.strict` with a small
/// leeway fires it on time, and cancelling disarms it.
struct WallClockTimerScheduler: TimerScheduling {
    static let leeway = DispatchTimeInterval.milliseconds(100)

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledAction {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        source.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: Self.leeway)
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume()
        return ScheduledSource(source: source)
    }

    private struct ScheduledSource: TimerScheduledAction {
        let source: DispatchSourceTimer
        func cancel() { source.cancel() }
    }
}

/// A timer that just ended, and how long after its end Keybumps noticed: about zero while it runs,
/// longer when it ended while the Mac slept or Keybumps wasn't running.
struct TimerFinish: Equatable {
    let item: TimerItem
    let lateness: TimeInterval
}

/// The Timers tab's countdowns, saved in `timers.json` so they survive a relaunch. Each running
/// timer keeps the moment it ends; the store schedules one wake-up for the soonest, checks again
/// whenever the Mac wakes, and while active reports every timer that ended through `onFinish`.
@MainActor
@Observable
final class TimerStore {
    static let fileName = "timers.json"

    private(set) var items: [TimerItem] = []
    /// Called with the timers that just ended, oldest end first.
    @ObservationIgnored var onFinish: ([TimerFinish]) -> Void = { _ in }
    /// Called after every change to the timers.
    @ObservationIgnored var onChange: () -> Void = {}

    private let storageURL: URL?
    private let fileManager: FileManager
    let now: () -> Date
    private let scheduler: any TimerScheduling
    private let notifications: NotificationCenter
    @ObservationIgnored private var scheduled: (any TimerScheduledAction)?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Whether Timer is running: on, and Keybumps set up and licensed. Timers start only then.
    private(set) var isActive = false

    init(
        storageURL: URL?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        scheduler: (any TimerScheduling)? = nil,
        notifications: NotificationCenter? = nil
    ) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.now = now
        self.scheduler = scheduler ?? WallClockTimerScheduler()
        self.notifications = notifications ?? NSWorkspace.shared.notificationCenter
        load()
    }

    static func makeDefault() -> TimerStore {
        TimerStore(
            storageURL: ProductPaths.keybumps().applicationSupport.appendingPathComponent(fileName),
            // Unit tests never hear the Mac wake.
            notifications: UnitTestHost.isActive ? NotificationCenter() : nil
        )
    }

    // MARK: Running

    /// Starts checking: reports timers that ended while it wasn't (after a relaunch), schedules the
    /// next end, and checks again on every wake. Runs while Timer is on.
    func activate() {
        guard !isActive else { return }
        isActive = true
        wakeObserver = notifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDue() }
        }
        checkDue()
    }

    /// Stops checking and clears every timer: turning Timer off cancels them.
    func deactivate() {
        isActive = false
        if let wakeObserver { notifications.removeObserver(wakeObserver) }
        wakeObserver = nil
        scheduled?.cancel()
        scheduled = nil
        if !items.isEmpty { commit([]) }
    }

    /// Finishes every running timer whose end has passed, reports them, and schedules the next end.
    func checkDue() {
        guard isActive else { return }
        let current = now()
        var finished: [TimerFinish] = []
        var next = items
        for index in next.indices {
            guard case .running(let endsAt) = next[index].state, endsAt <= current else { continue }
            next[index].state = .finished(at: endsAt, seen: false)
            finished.append(TimerFinish(item: next[index], lateness: current.timeIntervalSince(endsAt)))
        }
        if !finished.isEmpty {
            commit(next)
            onFinish(finished.sorted { $0.lateness > $1.lateness })
        }
        reschedule()
    }

    // MARK: Changes

    /// Starts a new timer and returns it.
    @discardableResult
    func start(duration: TimeInterval, name: String?) -> TimerItem {
        let item = TimerItem(id: UUID(), name: name, duration: duration, state: .running(endsAt: now().addingTimeInterval(duration)))
        commit(items + [item])
        reschedule()
        return item
    }

    /// Pauses a running timer or resumes a paused one.
    func togglePause(_ id: UUID) {
        update(id) { item, now in
            switch item.state {
            case .running(let endsAt): item.state = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
            case .paused(let remaining): item.state = .running(endsAt: now.addingTimeInterval(remaining))
            case .finished: break
            }
        }
    }

    /// Runs a timer again from its full length.
    func restart(_ id: UUID) {
        update(id) { item, now in item.state = .running(endsAt: now.addingTimeInterval(item.duration)) }
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        commit(items.filter { $0.id != id })
        reschedule()
    }

    /// Marks every finished timer seen. Returns whether one wasn't yet.
    @discardableResult
    func markFinishesSeen() -> Bool {
        var next = items
        var changed = false
        for index in next.indices {
            if case .finished(let at, false) = next[index].state {
                next[index].state = .finished(at: at, seen: true)
                changed = true
            }
        }
        if changed { commit(next) }
        return changed
    }

    var hasUnseenFinish: Bool { unseenFinishCount > 0 }

    var unseenFinishCount: Int {
        items.filter { if case .finished(_, false) = $0.state { true } else { false } }.count
    }

    // MARK: Order

    /// The tab's order: finished timers, newest first; then running ones, soonest to end first;
    /// then paused ones, in the order they were started.
    var displayed: [TimerItem] {
        let finished = items.filter(\.isFinished).sorted { finishedAt($0) > finishedAt($1) }
        let running = items.filter(\.isRunning).sorted { endsAt($0) < endsAt($1) }
        let paused = items.filter { if case .paused = $0.state { true } else { false } }
        return finished + running + paused
    }

    private func finishedAt(_ item: TimerItem) -> Date {
        if case .finished(let at, _) = item.state { return at }
        return .distantPast
    }

    private func endsAt(_ item: TimerItem) -> Date {
        if case .running(let endsAt) = item.state { return endsAt }
        return .distantFuture
    }

    // MARK: Storage and scheduling

    private func update(_ id: UUID, _ change: (inout TimerItem, Date) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        change(&next[index], now())
        commit(next)
        reschedule()
    }

    /// One wake-up, for the soonest end; none while inactive or nothing runs.
    private func reschedule() {
        scheduled?.cancel()
        scheduled = nil
        guard isActive, let soonest = items.compactMap({ item -> Date? in
            if case .running(let endsAt) = item.state { return endsAt }
            return nil
        }).min() else { return }
        scheduled = scheduler.schedule(at: soonest) { [weak self] in self?.checkDue() }
    }

    /// Keeps `next` and saves it. A failed save keeps the timers running in memory; nothing about
    /// them is logged.
    private func commit(_ next: [TimerItem]) {
        items = next
        onChange()
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(next) {
            try? PrivateFile.write(data, to: storageURL, fileManager: fileManager)
        }
    }

    /// Reads the saved timers. A missing or unreadable file starts with none, and a timer with an
    /// impossible length is dropped: timers are short-lived, so there's nothing worth keeping.
    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        items = ((try? JSONDecoder().decode([TimerItem].self, from: data)) ?? []).filter(\.isPlausible)
    }
}
