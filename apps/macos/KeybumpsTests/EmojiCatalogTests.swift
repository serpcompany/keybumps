import Foundation
import Testing
@testable import Keybumps

@Suite("Emoji Picker: the bundled emoji list")
struct EmojiCatalogTests {
    private let catalog: EmojiCatalog

    init() throws {
        catalog = try EmojiCatalog.bundled()
    }

    @Test("It's Unicode's Emoji 17.0 list in nine groups, built from the pinned sources")
    func listAndSources() {
        #expect(catalog.emoji.count == 1914)
        #expect(catalog.groups == [
            "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places",
            "Activities", "Objects", "Symbols", "Flags",
        ])
        #expect(catalog.sources == ["emoji": "17.0", "cldr": "48.2", "gemoji": "4.1.0"])
        #expect(catalog.emoji.first?.glyph == "😀", "Unicode's order")
    }

    @Test("An emoji carries its CLDR name and keywords, gemoji's aliases, and its five skin tones")
    func thumbsUp() throws {
        let thumbsUp = try #require(catalog.emoji.first { $0.glyph == "👍" })
        #expect(thumbsUp.name == "thumbs up")
        #expect(thumbsUp.keywords.contains("+1"))
        #expect(thumbsUp.aliases == ["+1", "thumbsup"])
        #expect(thumbsUp.tones == ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        #expect(catalog.groups[thumbsUp.group] == "People & Body")
    }

    @Test("A two-person emoji's tones give both people the same tone")
    func twoPeople() throws {
        let holdingHands = try #require(catalog.emoji.first { $0.glyph == "🧑‍🤝‍🧑" })
        #expect(holdingHands.tones[2] == "🧑🏽‍🤝‍🧑🏽")
        let handshake = try #require(catalog.emoji.first { $0.glyph == "🤝" })
        #expect(handshake.tones[0] == "🤝🏻")
    }

    @Test("Emoji newer than gemoji get an alias made from their name")
    func madeAliases() throws {
        let shaking = try #require(catalog.emoji.first { $0.glyph == "🙂‍↔️" })
        #expect(shaking.aliases == ["head_shaking_horizontally"])
        #expect(shaking.version == "15.1")
    }

    @Test("No duplicates, no loose tone modifiers, and every emoji has a name and an alias")
    func wellFormed() {
        let glyphs = catalog.emoji.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
        let modifiers = Set((0x1F3FB...0x1F3FF).compactMap(Unicode.Scalar.init))
        let baseHasNoTone = catalog.emoji.allSatisfy { !$0.glyph.unicodeScalars.contains(where: modifiers.contains) }
        #expect(baseHasNoTone, "Toned forms live in `tones`, not the list")
        let named = catalog.emoji.allSatisfy { !$0.name.isEmpty && !$0.aliases.isEmpty && $0.aliases.allSatisfy { !$0.isEmpty } }
        #expect(named)
        #expect(catalog.emoji.filter { !$0.tones.isEmpty }.count == 330)
    }

    @Test("Data in the wrong shape is refused, not half-read")
    func malformed() {
        #expect(throws: EmojiCatalog.LoadError.self) { try EmojiCatalog(data: Data(#"{"groups":["A"],"emoji":[["😀","x",[],[],0,"1.0"]],"sources":{}}"#.utf8)) }
        #expect(throws: EmojiCatalog.LoadError.self) { try EmojiCatalog(data: Data(#"{"groups":["A"],"emoji":[["😀","x",[],["x"],3,"1.0"]],"sources":{}}"#.utf8)) }
        #expect(throws: EmojiCatalog.LoadError.self) { try EmojiCatalog(data: Data(#"{"groups":["A"],"emoji":[["😀","x",[],["x"],0,"1.0","not tones"]],"sources":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try EmojiCatalog(data: Data("not json".utf8)) }
    }
}
