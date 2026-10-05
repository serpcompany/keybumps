import Foundation

/// The emoji picked most recently, newest first, kept only on this Mac in its own file (#243). They
/// are user content: shown in the Emoji tab, never logged. Each is kept by its base emoji, so it
/// follows a change of skin tone.
@MainActor
@Observable
final class EmojiRecents {
    static let fileName = "emoji-recent.json"
    static let limit = 24

    private(set) var glyphs: [String]
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let fileManager: FileManager

    init(storageURL: URL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        glyphs = (try? Data(contentsOf: storageURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    static func makeDefault() -> EmojiRecents {
        EmojiRecents(storageURL: ProductPaths.keybumps().applicationSupport.appendingPathComponent(fileName))
    }

    /// Moves an emoji to the front, keeping the newest `limit`.
    func use(_ glyph: String) {
        glyphs.removeAll { $0 == glyph }
        glyphs.insert(glyph, at: 0)
        if glyphs.count > Self.limit { glyphs.removeLast(glyphs.count - Self.limit) }
        save()
    }

    func clear() {
        guard !glyphs.isEmpty || fileManager.fileExists(atPath: storageURL.path) else { return }
        glyphs = []
        try? fileManager.removeItem(at: storageURL)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(glyphs) else { return }
        try? PrivateFile.write(data, to: storageURL, fileManager: fileManager)
    }
}
