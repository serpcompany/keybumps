import Foundation
import Testing
@testable import Keybumps

/// The bundled emoji, all of them, whatever this Mac can draw, so results are the same everywhere.
@MainActor
private func everyEmoji() throws -> EmojiLibrary {
    EmojiLibrary(catalog: try EmojiCatalog.bundled(), canDraw: { _ in true })
}

@Suite("Emoji Picker: search")
struct EmojiSearchTests {
    @Test("Exact aliases and names come first, then names, aliases, and keywords", arguments: [
        ("thumbs", ["👍", "👎"]),
        ("+1", ["👍"]),
        (":joy:", ["😂"]),
        ("tada", ["🎉"]),
        ("party", ["🥳", "🎉"]),
        ("heart", ["❤️"]),
    ])
    @MainActor
    func ranking(query: String, first: [String]) throws {
        let results = try everyEmoji().search(query).map(\.glyph)
        #expect(Array(results.prefix(first.count)) == first, "\(query): \(results.prefix(6))")
    }

    @Test("Every word must match, in any order; nothing matches nothing")
    @MainActor
    func everyWord() throws {
        let library = try everyEmoji()
        let redHair = library.search("hair red")
        #expect(redHair.contains { $0.glyph == "👩‍🦰" })
        #expect(redHair.allSatisfy { $0.name.contains("red hair") || $0.keywords.contains("red hair") })
        #expect(library.search("zzzz").isEmpty)
        #expect(library.search("   ").isEmpty)
    }

    @Test("Hyphenated names match by their parts, and a name with a colon can match exactly")
    @MainActor
    func hyphensAndColons() throws {
        let library = try everyEmoji()
        #expect(library.search("rex").first?.glyph == "🦖", "t-rex")
        #expect(library.search("flag: united states").first?.glyph == "🇺🇸")
    }

    @Test("Among equal matches, recently used emoji come first")
    @MainActor
    func recentBreaksTies() throws {
        let library = try everyEmoji()
        // Every "face with…" emoji matches by name equally, and none exactly, so recent use decides.
        let plain = library.search("face with").map(\.glyph)
        #expect(plain.count >= 3)
        let third = plain[2]
        #expect(library.search("face with", recent: [third]).first?.glyph == third)
    }

    @Test("What the Mac can't draw is left out, and a tone it can't draw falls back to the emoji")
    @MainActor
    func renderCheckFilters() throws {
        let catalog = try EmojiCatalog.bundled()
        let library = EmojiLibrary(catalog: catalog, canDraw: { $0 != "😀" && $0 != "👍🏽" })
        #expect(library.emoji(withGlyph: "😀") == nil)
        #expect(library.emoji(withGlyph: "👍")?.tones.isEmpty == true)
        #expect(library.emoji.count == catalog.emoji.count - 1)
    }
}

@Suite("Emoji Picker: drawing check")
struct EmojiRenderCheckTests {
    @Test("Apple Color Emoji draws a real emoji, but not a made-up sequence or plain text")
    func drawing() throws {
        let check = try #require(EmojiRenderCheck(), "Apple Color Emoji is on every Mac")
        #expect(check.canDraw("😀"))
        #expect(check.canDraw("👍🏽"))
        #expect(check.canDraw("🧑‍🤝‍🧑"))
        #expect(!check.canDraw("🙂\u{200D}🍕"), "A sequence Unicode never defined splits apart")
        #expect(!check.canDraw("ab"))
    }
}

@MainActor
@Suite("Emoji Picker: recent emoji")
struct EmojiRecentsTests {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsEmojiRecents-\(UUID().uuidString).json")

    @Test("Using an emoji moves it to the front, keeps the newest 24, and survives a relaunch")
    func use() {
        defer { try? FileManager.default.removeItem(at: url) }
        let recents = EmojiRecents(storageURL: url)
        recents.use("😀")
        recents.use("👍")
        recents.use("😀")
        #expect(recents.glyphs == ["😀", "👍"])
        for index in 0..<30 { recents.use("made-up-\(index)") }
        #expect(recents.glyphs.count == EmojiRecents.limit)
        #expect(EmojiRecents(storageURL: url).glyphs == recents.glyphs)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Only this user can read it")
    }

    @Test("A damaged file, or one past the limit, still reads safely")
    func damagedFile() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(EmojiRecents(storageURL: url).glyphs.isEmpty)
        try JSONEncoder().encode((0..<40).map { "made-up-\($0)" }).write(to: url)
        let recents = EmojiRecents(storageURL: url)
        recents.use("😀")
        #expect(recents.glyphs.count == EmojiRecents.limit)
        #expect(recents.glyphs.first == "😀")
    }

    @Test("Clearing removes them and their file")
    func clear() {
        let recents = EmojiRecents(storageURL: url)
        recents.use("😀")
        recents.clear()
        #expect(recents.glyphs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
@Suite("Emoji Picker: the Emoji tab")
struct EmojiPaletteContentTests {
    @MainActor
    private final class Palette {
        var copied: [String] = []
        var pasted: [(text: String, restores: Bool)] = []
        var actions: PaletteContentActions {
            PaletteContentActions(
                dismiss: {},
                selectRow: { _ in },
                clearQuery: {},
                copy: { [unowned self] in copied.append($0) },
                paste: { [unowned self] in pasted.append(($0, $1)) }
            )
        }
    }

    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsEmojiTab-\(UUID().uuidString).json")

    /// The tab with Emoji Picker turned on, loading at once.
    private func content(_ preferences: AppPreferences? = nil) throws -> EmojiPaletteContent {
        let library = try everyEmoji()
        let preferences = preferences ?? AppPreferences(defaults: InMemoryDefaults())
        preferences.setCapability(.emojiPicker, enabled: true)
        return EmojiPaletteContent(
            preferences: preferences,
            recents: EmojiRecents(storageURL: url),
            loadLibrary: { library },
            loadsInBackground: false
        )
    }

    @Test("With the search empty it's a grid of the groups, with Recent first once something is used")
    func grid() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = try content()
        #expect(tab.isGrid(query: ""))
        #expect(!tab.isGrid(query: "cat"))
        #expect(tab.sections.first?.title == "Smileys & Emotion")
        #expect(tab.rowCount(query: "") == 1914)

        tab.recents.use("👍")
        #expect(tab.sections.first == .init(title: "Recent", emoji: [try #require(tab.library?.emoji(withGlyph: "👍"))]))
        // Down from Recent's only emoji goes to the first row of the next section.
        #expect(tab.selection(after: .down, from: 0, query: "") == 1)
        #expect(tab.selection(after: .down, from: 1, query: "") == 1 + EmojiPaletteContent.columns)
    }

    @Test("Return copies, ⌘Return pastes and puts the clipboard back, and either makes it recent")
    func copyAndPaste() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = try content()
        let palette = Palette()
        let row = try #require(tab.rows(query: "joy").firstIndex { $0.glyph == "😂" })

        tab.activate(row: row, query: "joy", withCommand: false, palette: palette.actions)
        #expect(palette.copied == ["😂"])
        tab.activate(row: 0, query: "tada", withCommand: true, palette: palette.actions)
        #expect(palette.pasted.map(\.text) == ["🎉"])
        #expect(palette.pasted.map(\.restores) == [true])
        #expect(tab.recents.glyphs == ["🎉", "😂"])
        #expect(tab.footerActions(row: 0, query: "") == PaletteFooterActions(primary: "Copy", secondary: "Paste"))
    }

    @Test("The skin tone setting picks each emoji's form, and recent emoji are kept by their base")
    func skinTone() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.choice("medium"), of: .emojiSkinTone, for: .emojiPicker)
        let tab = try content(preferences)
        let palette = Palette()
        tab.activate(row: 0, query: "+1", withCommand: false, palette: palette.actions)
        #expect(palette.copied == ["👍🏽"])
        #expect(tab.recents.glyphs == ["👍"])
        let smile = try #require(tab.library?.emoji(withGlyph: "😀"))
        #expect(tab.glyph(for: smile) == "😀", "No tones, no change")
        let holdingHands = try #require(tab.library?.emoji(withGlyph: "🧑‍🤝‍🧑"))
        #expect(tab.glyph(for: holdingHands) == "🧑🏽‍🤝‍🧑🏽", "Both people take the tone")
    }

    @Test("Quick Search finds every matching emoji in the chosen skin tone while its setting is on (#333)")
    func quickSearchMatches() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.choice("medium"), of: .emojiSkinTone, for: .emojiPicker)
        let tab = try content(preferences)

        let thumbs = tab.quickSearchMatches("+1")
        #expect(thumbs.first == QuickSearchEmoji(glyph: "👍🏽", baseGlyph: "👍", name: "thumbs up"))
        #expect(tab.quickSearchMatches("heart").count > QuickSearchEmoji.shownAmongOtherResults)
        #expect(tab.quickSearchMatches("").isEmpty, "An empty query lists Recent Items, not emoji")

        tab.useFromQuickSearch(try #require(thumbs.first))
        #expect(tab.recents.glyphs == ["👍"], "Recent keeps the base emoji")

        preferences.set(.bool(false), of: .emojiInQuickSearch, for: .emojiPicker)
        #expect(tab.quickSearchMatches("+1").isEmpty)
        preferences.set(.bool(true), of: .emojiInQuickSearch, for: .emojiPicker)
        preferences.setCapability(.emojiPicker, enabled: false)
        #expect(tab.quickSearchMatches("+1").isEmpty, "Emoji Picker off finds none")
    }

    @Test("While Emoji Picker is off the tab has no rows")
    func offHasNoRows() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = try content()
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let library = tab.library
        let off = EmojiPaletteContent(preferences: preferences, recents: tab.recents, loadLibrary: { library }, loadsInBackground: false)
        #expect(off.rowCount(query: "") == 0)
        #expect(off.rowCount(query: "cat") == 0)
    }

    @Test("Without its list (no emoji font, or no data), the tab says it couldn't load")
    func failedLoad() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.setCapability(.emojiPicker, enabled: true)
        let tab = EmojiPaletteContent(preferences: preferences, recents: EmojiRecents(storageURL: url), loadLibrary: { nil }, loadsInBackground: false)
        #expect(tab.loadFailed)
        #expect(tab.rowCount(query: "") == 0)
    }

    @Test("With recent emoji turned off, nothing is remembered and Recent doesn't show")
    func recentOff() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.set(.bool(false), of: .emojiRemembersRecent, for: .emojiPicker)
        let tab = try content(preferences)
        let palette = Palette()
        tab.activate(row: 0, query: "+1", withCommand: false, palette: palette.actions)
        #expect(palette.copied == ["👍"])
        #expect(tab.recents.glyphs.isEmpty)
        #expect(tab.sections.first?.title == "Smileys & Emotion")
    }
}

@MainActor
@Suite("Emoji Picker: the plugin")
struct EmojiPickerPluginTests {
    @Test("Its manifest: Writing, ⌘7, Copy and Paste, optional Accessibility, and it ships off")
    func manifest() throws {
        let descriptor = CapabilityDescriptor.emojiPicker
        #expect(descriptor.category == .writing)
        #expect(descriptor.paletteTab?.commandKey == 7)
        #expect(CommandPaletteTab.keyboardShortcutter.shortcutLabel == "⌘9", "Hotkeys moved to make room, then again for Translate")
        #expect(descriptor.requiredPermissions.isEmpty)
        #expect(descriptor.optionalPermissions.map(\.permission) == [.accessibility])
        #expect(!descriptor.isOnByDefault)
        #expect(descriptor.preferences.map(\.key) == ["skinTone", "remembersRecent", "showsInQuickSearch"])
        #expect(CapabilityShortcut.emojiPicker.defaultBinding == nil, "Open Emoji Picker starts unassigned")
        #expect(CapabilityCatalog.requiredPermissions(for: [.emojiPicker]).isEmpty, "An optional permission is never setup it needs")
        #expect(QuickSearchCommand.capability(.emojiPicker).match("emoji") == .name || QuickSearchCommand.capability(.emojiPicker).match("emoji") == .keyword)
    }
}
