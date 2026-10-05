import Foundation

/// The emoji the Emoji Picker offers on this Mac, and its search. Built once from the bundled
/// catalog, leaving out what the Mac can't draw (`EmojiRenderCheck`).
struct EmojiLibrary: Sendable {
    let groups: [String]
    let emoji: [Emoji]
    private let byGlyph: [String: Int]
    private let tokens: [Tokens]

    /// What a search matches against, lowercased: name words, keyword words, and aliases with their
    /// parts (`thumbs_up` is also `thumbs` and `up`).
    private struct Tokens: Sendable {
        let name: String
        let nameWords: [String]
        let keywordWords: [String]
        let aliases: [String]
        let aliasWords: [String]
    }

    init(catalog: EmojiCatalog, canDraw: (String) -> Bool) {
        groups = catalog.groups
        emoji = catalog.emoji.compactMap { emoji in
            guard canDraw(emoji.glyph) else { return nil }
            // A tone the Mac can't draw falls back to the emoji itself.
            let tones = emoji.tones.allSatisfy(canDraw) ? emoji.tones : []
            return Emoji(glyph: emoji.glyph, name: emoji.name, keywords: emoji.keywords, aliases: emoji.aliases,
                         group: emoji.group, version: emoji.version, tones: tones)
        }
        byGlyph = Dictionary(emoji.enumerated().map { ($1.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        tokens = emoji.map { emoji in
            let aliases = emoji.aliases.map { $0.lowercased() }
            return Tokens(
                name: emoji.name.lowercased(),
                nameWords: Self.words(emoji.name),
                keywordWords: emoji.keywords.flatMap(Self.words),
                aliases: aliases,
                aliasWords: aliases.flatMap { $0.split(separator: "_").map(String.init) }
            )
        }
    }

    func emoji(withGlyph glyph: String) -> Emoji? {
        byGlyph[glyph].map { emoji[$0] }
    }

    /// The emoji every word of `query` matches, best first. Each word has to start a word of the
    /// name, a keyword, or an alias (colons are ignored, so `:joy:` is `joy`). An exact alias or
    /// name ranks first, then matches by name, then by alias, then by keyword; ties go to `recent`
    /// order, then Unicode's.
    func search(_ query: String, recent: [String] = []) -> [Emoji] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        let underscored = words.joined(separator: "_")
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var scored: [(index: Int, score: Int)] = []
        for (index, tokens) in tokens.enumerated() {
            if tokens.aliases.contains(underscored) || tokens.aliases.contains(whole) || tokens.name == whole {
                scored.append((index, 0))
                continue
            }
            var score = 0
            for word in words {
                if tokens.nameWords.contains(where: { $0.hasPrefix(word) }) {
                    score = max(score, 1)
                } else if tokens.aliasWords.contains(where: { $0.hasPrefix(word) }) || tokens.aliases.contains(where: { $0.hasPrefix(word) }) {
                    score = max(score, 2)
                } else if tokens.keywordWords.contains(where: { $0.hasPrefix(word) }) {
                    score = max(score, 3)
                } else {
                    score = -1
                    break
                }
            }
            if score > 0 { scored.append((index, score)) }
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let lhsRecent = recentRank[emoji[lhs.index].glyph] ?? .max
            let rhsRecent = recentRank[emoji[rhs.index].glyph] ?? .max
            if lhsRecent != rhsRecent { return lhsRecent < rhsRecent }
            return lhs.index < rhs.index
        }.map { emoji[$0.index] }
    }

    /// Lowercased words, split at spaces and punctuation but keeping `+` and `-` inside a word (`+1`).
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || ":,;()“”\"'!?.".contains($0) })
            .map(String.init)
    }
}
