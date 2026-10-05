import Foundation

/// Reads what someone types in the Timers tab: a duration, with an optional name before or after
/// it ("tea 5m", "5m tea"). The duration forms are adapted from Tock's parser (edelstone/tock, MIT;
/// `LICENSE.tock`, and the donor ledger): `25` (a bare number is minutes), `90s`, `5m`, `1h30m`,
/// `1h 30` (a number with no unit takes the next smaller one), `1.5h` or `1,5h`, `5:00`, and
/// `1:30:00`. Numbers are plain decimals: no signs, exponents, or hex.
enum TimerDurationParser {
    struct Parsed: Equatable {
        /// Whole seconds.
        let duration: TimeInterval
        /// The words around the duration, or nil when there are none.
        let name: String?
    }

    /// The longest timer Keybumps starts.
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    /// Longer text is never read as a timer, so pasting a document into the field costs nothing.
    static let maximumInputLength = 200

    /// A duration is at most this many words ("in 1 hr 15 min").
    private static let maximumDurationWords = 6

    /// The duration and name in `input`, or nil when no run of words at its start or end reads as a
    /// duration of at least a second. A duration longer than `maximumDuration` still parses, so the
    /// Timers tab can say why it won't start.
    static func parse(_ input: String) -> Parsed? {
        guard input.count <= maximumInputLength else { return nil }
        let words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        // The duration is the longest run of words at the start, or failing that the end, that
        // reads as one; whatever is left is the name.
        for length in stride(from: min(words.count, maximumDurationWords), through: 1, by: -1) {
            if let duration = duration(in: words.prefix(length)) {
                return Parsed(duration: duration, name: name(from: words.dropFirst(length)))
            }
            if length < words.count, let duration = duration(in: words.suffix(length)) {
                return Parsed(duration: duration, name: name(from: words.dropLast(length)))
            }
        }
        return nil
    }

    private static func duration(in words: ArraySlice<String>) -> TimeInterval? {
        var words = Array(words)
        // "in 10 minutes", "for 5m"
        if let first = words.first?.lowercased(), connectingWords.contains(first) { words.removeFirst() }
        guard !words.isEmpty, let seconds = seconds(in: words.joined(separator: " ").lowercased()) else { return nil }
        let whole = seconds.rounded()
        return whole >= 1 ? whole : nil
    }

    private static func name(from words: ArraySlice<String>) -> String? {
        var words = Array(words)
        // "tea for 5m", "5m for tea": the joining word isn't part of the name.
        while let last = words.last?.lowercased(), connectingWords.contains(last) { words.removeLast() }
        while let first = words.first?.lowercased(), connectingWords.contains(first) { words.removeFirst() }
        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static let connectingWords: Set<String> = ["in", "for"]

    /// Seconds in lowercased `text`, which holds only a duration. The arithmetic is in `Double`, so
    /// no length of digits can overflow; anything past `maximumDuration` is simply too long.
    static func seconds(in text: String) -> TimeInterval? {
        let text = text.replacingOccurrences(of: ",", with: ".")
        return colonSeconds(in: text) ?? compositeSeconds(in: text) ?? numberSeconds(in: text)
    }

    /// `5:00` is minutes and seconds; `1:30:00` adds hours. Parts after the first stay under 60.
    private static func colonSeconds(in text: String) -> TimeInterval? {
        guard text.contains(":") else { return nil }
        let parts = text.replacingOccurrences(of: " ", with: "")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// One or more numbers, each with a unit (`1h30m`, `1.5h`, `90s`), where a number without one
    /// takes the next smaller unit after the one before it (`1h 30`). A part may be zero (`1h0m`)
    /// as long as the total isn't.
    private static func compositeSeconds(in text: String) -> TimeInterval? {
        var rest = Substring(text)
        var total: TimeInterval = 0
        var lastUnit: Unit?
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { break }
            guard let (value, afterNumber) = number(at: rest) else { return nil }
            rest = afterNumber.drop(while: \.isWhitespace)
            let token = rest.prefix(while: \.isLetter)
            if !token.isEmpty {
                guard let unit = Unit(String(token)) else { return nil }
                total += value * unit.seconds
                lastUnit = unit
                rest = rest.dropFirst(token.count)
            } else {
                guard let next = lastUnit?.nextSmaller else { return nil }
                total += value * next.seconds
                lastUnit = next
            }
        }
        return total > 0 ? total : nil
    }

    /// A bare number, which is minutes (`25`, `2.5`).
    private static func numberSeconds(in text: String) -> TimeInterval? {
        guard let (minutes, rest) = number(at: Substring(text)), rest.isEmpty, minutes > 0 else { return nil }
        return minutes * Unit.minute.seconds
    }

    /// A plain decimal at the start of `text` (digits, then optionally a point and more digits), and
    /// what follows it.
    private static func number(at text: Substring) -> (Double, Substring)? {
        let whole = text.prefix(while: \.isASCIIDigit)
        guard !whole.isEmpty else { return nil }
        var end = text.index(text.startIndex, offsetBy: whole.count)
        if end < text.endIndex, text[end] == "." {
            let fraction = text[text.index(after: end)...].prefix(while: \.isASCIIDigit)
            if !fraction.isEmpty { end = fraction.endIndex }
        }
        guard let value = Double(text[..<end]), value.isFinite else { return nil }
        return (value, text[end...])
    }

    private enum Unit {
        case hour, minute, second

        init?(_ token: String) {
            switch token {
            case "h", "hr", "hrs", "hour", "hours": self = .hour
            case "m", "min", "mins", "minute", "minutes": self = .minute
            case "s", "sec", "secs", "second", "seconds": self = .second
            default: return nil
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .hour: 3600
            case .minute: 60
            case .second: 1
            }
        }

        var nextSmaller: Unit? {
            switch self {
            case .hour: .minute
            case .minute: .second
            case .second: nil
            }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
