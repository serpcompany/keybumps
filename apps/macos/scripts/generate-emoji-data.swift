#!/usr/bin/env swift
// Builds the Emoji Picker's bundled emoji list (Keybumps/EmojiPicker/emoji.json) from three
// pinned sources (#243). The app never fetches emoji data; rerun this to update it, then bump the
// pins together and update the donor ledger.
//
//   swift scripts/generate-emoji-data.swift [cache-directory]
//
// Run from anywhere. Sources are downloaded into the cache directory (default: a temporary folder)
// unless already there, and each must match its pinned SHA-256. It fails rather than write a list
// with a skin tone it couldn't place.
//
// - Unicode emoji-test.txt, Emoji 17.0 (Unicode-3.0): the list, its order, groups, the version
//   each emoji was added, and skin-tone sequences.
// - CLDR 48.2 annotations, en.xml and annotationsDerived/en.xml (Unicode-3.0): names and keywords.
// - gemoji v4.1.0 db/emoji.json (MIT): :shortcode: aliases. Newer emoji get one made from their name.

import CryptoKit
import Foundation

struct Source {
    let file: String
    let url: String
    let sha256: String
}

let sources = [
    Source(file: "emoji-test.txt",
           url: "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
           sha256: "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda"),
    Source(file: "cldr-annotations-en.xml",
           url: "https://raw.githubusercontent.com/unicode-org/cldr/11299982335beb974c1c63c45265184e759c0f41/common/annotations/en.xml",
           sha256: "8511aadd046fdba2f0ffe590266ced8bbf48175ad139b2675d85d7141057b235"),
    Source(file: "cldr-annotations-derived-en.xml",
           url: "https://raw.githubusercontent.com/unicode-org/cldr/11299982335beb974c1c63c45265184e759c0f41/common/annotationsDerived/en.xml",
           sha256: "d76bd041c8c9e7b00b716aff8b7d9dbf509877010e191d5efd068be2553e066e"),
    Source(file: "gemoji.json",
           url: "https://raw.githubusercontent.com/github/gemoji/5476a66d2794e0d1551b1f96e449afc72e9f7bec/db/emoji.json",
           sha256: "b174ae2aeb321b52f64adb9ff412f966a7f338839d780784dd15dcad702c2dd6"),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-emoji-data: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
let cache = URL(fileURLWithPath: arguments.first ?? NSTemporaryDirectory() + "keybumps-emoji-sources", isDirectory: true)
// apps/macos, from this script's own path.
let appFolder = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = appFolder.appendingPathComponent("Keybumps/EmojiPicker/emoji.json")
try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

func load(_ source: Source) -> Data {
    let local = cache.appendingPathComponent(source.file)
    if !FileManager.default.fileExists(atPath: local.path) {
        // Download beside it, then move it in, so a broken download never stays in the cache.
        let partial = local.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--fail", "--silent", "--show-error", "--location", "--output", partial.path, source.url]
        try? curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0, (try? FileManager.default.moveItem(at: partial, to: local)) != nil else {
            try? FileManager.default.removeItem(at: partial)
            fail("couldn't download \(source.url)")
        }
    }
    guard let data = try? Data(contentsOf: local) else { fail("couldn't read \(local.path)") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == source.sha256 else { fail("\(source.file) doesn't match its pinned SHA-256 (\(digest))") }
    return data
}

/// Skin tone modifiers, light (1) to dark (5).
let toneModifiers: [Unicode.Scalar] = (0x1F3FB...0x1F3FF).compactMap(Unicode.Scalar.init)

/// The key sources are joined on: the sequence without variation selectors.
func key(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
}

/// The tone of a sequence whose modifiers are all one tone (1–5), 0 for none, nil for mixed tones.
func uniformTone(_ emoji: String) -> Int? {
    let tones = Set(emoji.unicodeScalars.compactMap { toneModifiers.firstIndex(of: $0) })
    switch tones.count {
    case 0: return 0
    case 1: return tones.first! + 1
    default: return nil
    }
}

func withoutTones(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { !toneModifiers.contains($0) }))
}

// 1. emoji-test.txt: fully-qualified sequences in order, with their group and version.
struct Entry {
    let emoji: String
    let testName: String
    let group: Int
    let version: String
    var tones: [String?] = Array(repeating: nil, count: 5)
}

guard let testText = String(data: load(sources[0]), encoding: .utf8) else { fail("emoji-test.txt isn't UTF-8") }
var groups: [String] = []
var entries: [Entry] = []
var indexByKey: [String: Int] = [:]
var toned: [(emoji: String, tone: Int)] = []
var skippedGroup = false
for line in testText.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.hasPrefix("# group: ") {
        let name = String(line.dropFirst("# group: ".count))
        skippedGroup = name == "Component"
        if !skippedGroup { groups.append(name) }
        continue
    }
    guard !skippedGroup, !line.hasPrefix("#"), line.contains("; fully-qualified") else { continue }
    // 1F600 ; fully-qualified # 😀 E1.0 grinning face
    guard let hash = line.firstIndex(of: "#") else { continue }
    let comment = line[line.index(after: hash)...].split(separator: " ", maxSplits: 2)
    guard comment.count == 3, comment[1].hasPrefix("E") else { fail("unexpected line: \(line)") }
    let emoji = String(comment[0])
    switch uniformTone(emoji) {
    case 0:
        indexByKey[key(emoji)] = entries.count
        entries.append(Entry(emoji: emoji, testName: String(comment[2]), group: groups.count - 1, version: String(comment[1].dropFirst())))
    case let tone?:
        toned.append((emoji, tone))
    case nil:
        continue // Mixed tones: the picker applies one tone to everyone in an emoji.
    }
}
var orphanTones = 0
for (emoji, tone) in toned {
    guard let index = indexByKey[key(withoutTones(emoji))] else {
        orphanTones += 1
        continue
    }
    entries[index].tones[tone - 1] = emoji
}
guard orphanTones == 0 else { fail("\(orphanTones) toned sequences have no base emoji; check the grouping") }
let partialTones = entries.filter { tones in let count = tones.tones.compactMap { $0 }.count; return count > 0 && count < 5 }
guard partialTones.isEmpty else { fail("\(partialTones.count) emoji have only some of their five tones, such as \(partialTones[0].emoji)") }

// 2. CLDR: names (type="tts") and keywords, for base and derived sequences.
final class AnnotationReader: NSObject, XMLParserDelegate {
    var names: [String: String] = [:]
    var keywords: [String: [String]] = [:]
    private var cp: String?
    private var isName = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "annotation" else { return }
        cp = attributes["cp"]
        isName = attributes["type"] == "tts"
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if cp != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "annotation", let cp else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isName {
            names[key(cp)] = value
        } else {
            keywords[key(cp)] = value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        self.cp = nil
    }
}

let annotations = AnnotationReader()
for source in sources[1...2] {
    let parser = XMLParser(data: load(source))
    parser.delegate = annotations
    guard parser.parse() else { fail("couldn't parse \(source.file)") }
}

// 3. gemoji: :shortcode: aliases.
struct Gemoji: Decodable {
    let emoji: String
    let aliases: [String]
}
guard let gemoji = try? JSONDecoder().decode([Gemoji].self, from: load(sources[3])) else { fail("couldn't parse gemoji.json") }
var aliasesByKey: [String: [String]] = [:]
for record in gemoji { aliasesByKey[key(record.emoji)] = record.aliases }

/// An alias for emoji gemoji doesn't know yet, made from the name, as emojibase's CLDR preset does.
func alias(fromName name: String) -> String {
    name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: "_")
}

// 4. One compact record per emoji: [emoji, name, keywords, aliases, group, version, tones?].
var made = 0
var records: [[Any]] = []
for entry in entries {
    let name = annotations.names[key(entry.emoji)] ?? entry.testName
    let keywords = (annotations.keywords[key(entry.emoji)] ?? []).filter { $0.lowercased() != name.lowercased() }
    var aliases = aliasesByKey[key(entry.emoji)] ?? []
    if aliases.isEmpty {
        aliases = [alias(fromName: name)]
        made += 1
    }
    var record: [Any] = [entry.emoji, name, keywords, aliases, entry.group, entry.version]
    let tones = entry.tones.compactMap { $0 }
    if tones.count == 5 { record.append(tones) }
    records.append(record)
}

let document: [String: Any] = [
    "sources": ["emoji": "17.0", "cldr": "48.2", "gemoji": "4.1.0"],
    "groups": groups,
    "emoji": records,
]
let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
try data.write(to: output)
let withTones = records.filter { $0.count == 7 }.count
print("Wrote \(output.path): \(records.count) emoji in \(groups.count) groups, \(withTones) with skin tones, \(made) aliases made from names, \(orphanTones) toned sequences without a base, \(data.count / 1024) KB.")
