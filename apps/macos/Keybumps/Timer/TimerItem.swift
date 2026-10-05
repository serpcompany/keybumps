import Foundation

/// One countdown in the Timers tab. A running timer keeps the moment it ends, never a count of
/// ticks, so it stays right across sleep and relaunch. That moment is on the wall clock, so setting
/// the Mac's clock moves it too: back an hour and a running timer runs an hour longer.
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

    /// Whether a saved timer could have been started here: a length up to Timer's limit, and
    /// a paused remainder within it. A damaged file can hold anything.
    var isPlausible: Bool {
        guard duration.isFinite, duration >= 1, duration <= TimerDurationParser.maximumDuration else { return false }
        switch state {
        case .running(let endsAt): return endsAt.timeIntervalSinceReferenceDate.isFinite
        case .paused(let remaining): return remaining.isFinite && remaining >= 0 && remaining <= duration
        case .finished(let at, _): return at.timeIntervalSinceReferenceDate.isFinite
        }
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

    /// When something happened, to follow a verb: "at 3:47 PM" today, "yesterday at 3:47 PM", or
    /// "on" a date and time before that.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time(date))"
        }
        return "on \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// A length as VoiceOver says it: "4 minutes, 5 seconds".
    static func spokenLength(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: seconds.rounded(.up)) ?? length(seconds)
    }
}
