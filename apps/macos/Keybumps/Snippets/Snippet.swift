import Foundation

/// A named piece of text the user saved to reuse, kept on this Mac.
struct Snippet: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// The text to copy or paste. Always empty for a sensitive snippet: its text stays in the
    /// Keychain and is read only to copy, paste, or edit it (`SnippetStore.text(for:)`).
    var text: String
    /// A short word that finds the snippet in search, such as `;ship`. Never contains whitespace.
    var keyword: String?
    /// A sensitive snippet's text is hidden in the palette and Settings, left out of search, and
    /// kept in the Keychain instead of `snippets.json`.
    var isSensitive: Bool
    let createdAt: Date
    var updatedAt: Date
    /// When it was last copied or pasted. Recently used snippets come first when the search is empty.
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        text: String,
        keyword: String? = nil,
        isSensitive: Bool = false,
        createdAt: Date,
        updatedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.text = isSensitive ? "" : text
        self.keyword = keyword
        self.isSensitive = isSensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, text, keyword, isSensitive, createdAt, updatedAt, lastUsedAt
    }

    /// Only the ID and name are required, so a snippet saved by an older build, or one missing a
    /// field added later, still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
        // A sensitive snippet's text never comes from the file, even if one was written there.
        text = try isSensitive ? "" : container.decodeIfPresent(String.self, forKey: .text) ?? ""
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// A sensitive snippet is written without its text.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !isSensitive {
            try container.encode(text, forKey: .text)
        }
        try container.encodeIfPresent(keyword, forKey: .keyword)
        try container.encode(isSensitive, forKey: .isSensitive)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    }
}

/// What the snippet editor edits: a new snippet, or a copy of an existing one's fields.
struct SnippetDraft: Equatable {
    var name = ""
    var keyword = ""
    var text = ""
    var isSensitive = false

    /// What stops the draft from being saved, in the order the editor's fields show them.
    enum Problem: Equatable {
        case missingName
        case keywordHasSpaces
        case keywordInUse
        case missingText

        var message: String {
            switch self {
            case .missingName: "Give the snippet a name."
            case .keywordHasSpaces: "A keyword can’t contain spaces."
            case .keywordInUse: "Another snippet already uses this keyword."
            case .missingText: "Enter the text to save."
            }
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The keyword as saved: trimmed, or nil when empty.
    var normalizedKeyword: String? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first problem with the draft, if any. `otherKeywords` are the keywords of every other
    /// snippet; keywords are compared ignoring case, so `;Ship` and `;ship` can't both exist.
    func problem(otherKeywords: [String]) -> Problem? {
        if trimmedName.isEmpty { return .missingName }
        if let keyword = normalizedKeyword {
            if keyword.contains(where: \.isWhitespace) { return .keywordHasSpaces }
            if otherKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                return .keywordInUse
            }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingText }
        return nil
    }
}

/// What the Settings page's editor sheet is open for. The palette's New Snippet and Edit set it too,
/// so Settings opens on the Snippets page with the editor showing.
enum SnippetEditorRequest: Identifiable, Hashable {
    case new
    case edit(Snippet.ID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id.uuidString
        }
    }
}
