import Foundation

/// One countdown in the Timers tab. A running timer keeps the moment it ends, never a count of
/// ticks, so it stays right across sleep and relaunch.
struct TimerItem: Codable, Equatable, Identifiable {
    enum State: Codable, Equatable {
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
        /// `seen` turns true once the Timers tab has been open since it finished.
        case finished(at: Date, seen: Bool)
    }

    let id: UUID
    /// What the person typed around the duration. User content: it stays in the local timers file
    /// and on screen, and is never logged.
    var name: String?
    /// The length it was started with; Restart runs it again for this long.
    var duration: TimeInterval
    var state: State

    /// Time left at `now`: zero once finished.
    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): remaining
        case .finished: 0
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// The row's and the notice's name: the typed name, or the length ("5 min timer").
    var title: String {
        name ?? "\(TimerText.length(duration)) timer"
    }
}

/// How the Timers tab and its notices write lengths and times.
enum TimerText {
    /// A length in words: "45 sec", "5 min", "1 hr 30 min", "2 hr".
    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0 { parts.append("\(secs) sec") }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }

    /// Time left as a clock: "4:05", "31:08", "1:17:14". It counts up to the next whole second, so
    /// a timer never shows 0:00 while it is still running.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// A time of day in the person's own format ("3:47 PM").
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
