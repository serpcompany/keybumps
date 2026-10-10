import CoreGraphics
import Foundation

/// What the key display shows and for how long: the newest keystrokes, oldest first, with the
/// last one or two above the newest, and where the pointer clicked. Times are passed in, so it's
/// tested without a clock. Adapted from KeyCastr's `KCDefaultVisualizer`: a shortcut starts a new
/// line, typing joins the line it's on until a pause, and each line fades after a while. Unlike
/// KeyCastr, pressing the same shortcut again counts it (⌘Z ×3) instead of adding a line, so three
/// undos don't push the history off. What it holds stays in memory, only while it's on screen.
struct KeystrokeTimeline: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: Int
        /// A shortcut's keys, one per keycap, or a single keycap holding what was typed.
        var keycaps: [String]
        /// The keys run together, for the bezel: "⇧⌘4", or what was typed.
        var text: String
        /// The action's name, when Keybumps knows it (`KeystrokeActionNames`).
        var name: String?
        /// How many times in a row the shortcut was pressed; shown from the second, as ×2.
        var count = 1
        let isTyping: Bool
        var lastPress: Date
    }

    struct Click: Equatable, Identifiable {
        let id: Int
        /// In AppKit's screen coordinates: from the bottom left of the main display.
        let location: CGPoint
        let time: Date
    }

    /// The newest line and the two above it.
    static let visibleEntries = 3
    /// How long typing may pause and still join the same line. KeyCastr's own default is 0.5 s.
    static let typingBreak: TimeInterval = 0.8
    /// How much of a typed line shows: the end of it.
    static let typedCharacters = 20
    /// How long a click's ring shows.
    static let clickDuration: TimeInterval = 0.5

    private(set) var entries: [Entry] = []
    private(set) var clicks: [Click] = []
    private var nextID = 0

    /// Adds a keystroke at `time`, after dropping what's been on screen longer than `linger`.
    mutating func record(_ stroke: Keystroke, name: String?, at time: Date, linger: TimeInterval) {
        expire(at: time, linger: linger)
        if stroke.isShortcut {
            if let last = entries.indices.last, !entries[last].isTyping, entries[last].text == stroke.text {
                entries[last].count += 1
                entries[last].lastPress = time
                return
            }
            append(Entry(id: takeID(), keycaps: stroke.keycaps, text: stroke.text, name: name, isTyping: false, lastPress: time))
        } else if let last = entries.indices.last, entries[last].isTyping,
                  time.timeIntervalSince(entries[last].lastPress) <= Self.typingBreak {
            let typed = String((entries[last].text + stroke.key).suffix(Self.typedCharacters))
            entries[last].text = typed
            entries[last].keycaps = [typed]
            entries[last].lastPress = time
        } else {
            append(Entry(id: takeID(), keycaps: [stroke.key], text: stroke.key, name: nil, isTyping: true, lastPress: time))
        }
    }

    /// Adds a ring where the pointer clicked.
    mutating func recordClick(at location: CGPoint, time: Date) {
        clicks.removeAll { time.timeIntervalSince($0.time) >= Self.clickDuration }
        clicks.append(Click(id: takeID(), location: location, time: time))
    }

    /// Drops lines that have been on screen `linger` since their last press, and finished rings.
    mutating func expire(at time: Date, linger: TimeInterval) {
        entries.removeAll { time.timeIntervalSince($0.lastPress) >= linger }
        clicks.removeAll { time.timeIntervalSince($0.time) >= Self.clickDuration }
    }

    /// When the next line or ring is due to go, or nil while nothing shows.
    func nextExpiry(linger: TimeInterval) -> Date? {
        (entries.map { $0.lastPress.addingTimeInterval(linger) } + clicks.map { $0.time.addingTimeInterval(Self.clickDuration) }).min()
    }

    /// Takes typing off the screen at once, as when the display switches to Shortcuts only.
    mutating func removeTyping() {
        entries.removeAll(where: \.isTyping)
    }

    mutating func removeClicks() {
        clicks.removeAll()
    }

    mutating func removeAll() {
        entries.removeAll()
        clicks.removeAll()
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.visibleEntries { entries.removeFirst(entries.count - Self.visibleEntries) }
    }

    private mutating func takeID() -> Int {
        nextID += 1
        return nextID
    }
}
