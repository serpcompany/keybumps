import Foundation

/// One emoji from the bundled list.
struct Emoji: Hashable, Sendable {
    let glyph: String
    /// Its CLDR name, such as "face with tears of joy".
    let name: String
    /// Its CLDR keywords, without the name.
    let keywords: [String]
    /// Its `:shortcode:` aliases without the colons, such as "joy"; at least one.
    let aliases: [String]
    /// Its index in `EmojiCatalog.groups`.
    let group: Int
    /// The Emoji version that added it, such as "15.1".
    let version: String
    /// Its skin-tone forms, light to dark, when it has them: five, or none. A two-person emoji's
    /// forms give both people the same tone.
    let tones: [String]
}

/// The emoji the Emoji Picker offers (#243): Unicode's list in its order, grouped, with CLDR names and
/// keywords and gemoji's aliases. `scripts/generate-emoji-data.swift` builds the bundled
/// `emoji.json` from pinned sources; nothing is fetched at run time.
struct EmojiCatalog: Sendable {
    enum LoadError: Error {
        case missing
        case malformed
    }

    /// Unicode's groups, in order: "Smileys & Emotion", "People & Body", and so on.
    let groups: [String]
    let emoji: [Emoji]
    /// The versions it was built from: "emoji", "cldr", and "gemoji".
    let sources: [String: String]

    /// The list bundled with the app.
    static func bundled(in bundle: Bundle = .main) throws -> EmojiCatalog {
        guard let url = bundle.url(forResource: "emoji", withExtension: "json") else { throw LoadError.missing }
        return try EmojiCatalog(data: Data(contentsOf: url))
    }

    /// Reads the generator's compact format: each emoji is `[glyph, name, keywords, aliases, group,
    /// version]`, with its five tones last when it has them.
    init(data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = document["groups"] as? [String],
              let records = document["emoji"] as? [[Any]],
              let sources = document["sources"] as? [String: String] else { throw LoadError.malformed }
        self.groups = groups
        self.sources = sources
        emoji = try records.map { record in
            guard record.count == 6 || record.count == 7,
                  let glyph = record[0] as? String,
                  let name = record[1] as? String,
                  let keywords = record[2] as? [String],
                  let aliases = record[3] as? [String], !aliases.isEmpty,
                  let group = record[4] as? Int, groups.indices.contains(group),
                  let version = record[5] as? String else { throw LoadError.malformed }
            let tones = record.count == 7 ? (record[6] as? [String] ?? []) : []
            guard tones.isEmpty || tones.count == 5 else { throw LoadError.malformed }
            return Emoji(glyph: glyph, name: name, keywords: keywords, aliases: aliases, group: group, version: version, tones: tones)
        }
    }
}
