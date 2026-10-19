import Foundation
import Testing
@testable import Keybumps

// Quick Search (⌘1) listing snippets by keyword, name, and text. Every snippet here is made up.

@MainActor
@Suite("Quick Search: snippets")
struct QuickSearchSnippetTests {
    static func snippet(
        _ name: String,
        keyword: String? = nil,
        text: String = "made-up text",
        sensitive: Bool = false,
        usedAt: TimeInterval? = nil
    ) -> Snippet {
        Snippet(
            name: name, text: text, keyword: keyword, isSensitive: sensitive,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            lastUsedAt: usedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    static func names(_ snippets: [Snippet], _ query: String) -> [String] {
        SnippetSearch.quickSearchMatches(snippets, query: query).map(\.snippet.name)
    }

    @Test("Snippets match by keyword, with or without its punctuation, then by name, then by text")
    func matching() {
        let snippets = [
            Self.snippet("Release note", keyword: ";ship"),
            Self.snippet("Shipping address"),
            Self.snippet("Greeting", text: "we ship on Mondays"),
            Self.snippet("API token", keyword: "``tok", sensitive: true),
        ]
        #expect(Self.names(snippets, "ship") == ["Release note", "Shipping address", "Greeting"], "Keyword first, then name, then text")
        #expect(Self.names(snippets, "``tok") == ["API token"], "A sensitive snippet's keyword and name still match")
        #expect(Self.names(snippets, "tok") == ["API token"], "…with or without the keyword's punctuation")
        #expect(Self.names(snippets, "monday") == ["Greeting"], "Part of a word in the text finds it (#555)")
        #expect(Self.names(snippets, "  ").isEmpty)
    }

    @Test("Equally good snippets keep the Snippets tab's order: recently used first")
    func recentFirst() {
        let snippets = [Self.snippet("Made-up older", usedAt: 10), Self.snippet("Made-up never"), Self.snippet("Made-up newer", usedAt: 20)]
        #expect(Self.names(snippets, "made") == ["Made-up newer", "Made-up older", "Made-up never"])
    }

    @Test("At most eight snippets are listed, so they never bury apps and files")
    func limited() {
        let snippets = (1...12).map { Self.snippet("Made-up \($0)") }
        #expect(SnippetSearch.quickSearchMatches(snippets, query: "made").count == 8)
    }

    @Test("Text matches only fill the room keyword and name matches leave")
    func textFillsLeftoverRoom() {
        let named = (1...6).map { Self.snippet("Housekeeping \($0)") }
        let texts = (1...6).map { Self.snippet("Made-up \($0)", text: "made-up housekeeping notes") }
        let matches = SnippetSearch.quickSearchMatches(texts + named, query: "house")
        #expect(matches.count == SnippetSearch.quickSearchLimit)
        #expect(matches.prefix(6).allSatisfy { $0.match == .nameWords })
        #expect(matches.suffix(2).allSatisfy { $0.match == .text })
    }

    @Test("A keyword typed in full comes first; other keyword and name matches come after apps and commands, before files; text matches come last")
    func ranking() {
        let typed = Self.snippet("Template", keyword: "clip")
        let bare = Self.snippet("Signature", keyword: ";clip")
        let named = Self.snippet("Clipping rules")
        let text = Self.snippet("Greeting", text: "made-up clipboard note")
        let app = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Clipper.app"), kind: .application)
        let file = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/fixture/clip.txt"), kind: .file)
        let clipboard = QuickSearchCommand.capability(.clipboardHistory)

        let rows = QuickSearchRanking.items(
            matching: "clip", applications: [app], files: [file], commands: [clipboard], snippets: [text, named, bare, typed]
        )
        // `;clip` without its punctuation is still a keyword match, but it doesn't jump above the
        // apps: typing "mail" should still put Mail first.
        #expect(rows == [.snippet(typed), .result(app), .command(clipboard), .snippet(bare), .snippet(named), .result(file), .snippet(text)])
        #expect(QuickSearchRanking.items(matching: ";clip", applications: [], files: [], commands: [], snippets: [named, bare]).first
            == .snippet(bare), "…and comes first when typed with it")
        #expect(QuickSearchRanking.items(matching: "clip", applications: [app], files: [file], commands: [clipboard])
            == [.result(app), .command(clipboard), .result(file)], "No snippets supplied, none listed")
    }

    @Test("A sensitive snippet's text is never matched in Quick Search")
    func sensitiveTextNeverMatched() {
        let sensitive = Self.snippet("Made-up login", text: "made-up housekeeping secret", sensitive: true)
        #expect(Self.names([sensitive], "house").isEmpty)
        #expect(QuickSearchRanking.items(matching: "house", applications: [], files: [], commands: [], snippets: [sensitive]).isEmpty)
    }

    @Test("A snippet row's footer says Copy ↵ and Paste ⌘P; other rows keep the Search tab's Open ↵")
    func footerActions() {
        let snippet = QuickSearchItem.snippet(Self.snippet("Made-up"))
        #expect(snippet.primaryActionTitle == "Copy")
        #expect(snippet.secondaryActions == [.paste()])
        let app = QuickSearchItem.result(QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Made-up.app"), kind: .application))
        #expect(app.primaryActionTitle == CommandPaletteTab.search.primaryActionTitle)
        #expect(app.primaryActionTitle == "Open")
        #expect(app.secondaryActions.isEmpty)
    }
}
