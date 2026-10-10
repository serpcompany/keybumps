import Foundation

/// A GitHub repository, `owner/name`, that a capture's issue goes to.
struct ScreencastRepository: Hashable, Sendable, CustomStringConvertible {
    let owner: String
    let name: String

    /// Reads what the person typed or pasted: `owner/name`, or the github.com address of the
    /// repository or of anything in it, such as an issue. Nil when it isn't a name GitHub allows.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [Substring]
        if let address = URLComponents(string: text), let scheme = address.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            guard let host = address.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
            parts = address.path.split(separator: "/")
        } else if let path = Self.dropGitHubHost(text) {
            parts = path.split(separator: "/")
        } else {
            // Exactly `owner/name`, with a trailing slash at most.
            parts = text.split(separator: "/", omittingEmptySubsequences: false)
            if parts.last?.isEmpty == true { parts.removeLast() }
            guard parts.count == 2 else { return nil }
        }
        guard parts.count >= 2 else { return nil }
        var name = String(parts[1])
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        guard Self.isOwner(parts[0]), Self.isName(name) else { return nil }
        owner = String(parts[0])
        self.name = name
    }

    var description: String { "\(owner)/\(name)" }

    /// `github.com/owner/name…` without a scheme, as the address bar copies it.
    private static func dropGitHubHost(_ text: String) -> Substring? {
        for host in ["github.com/", "www.github.com/"] where text.lowercased().hasPrefix(host) {
            return text.dropFirst(host.count).prefix { $0 != "?" && $0 != "#" }
        }
        return nil
    }

    /// GitHub's rule for an account: letters, digits, and single hyphens inside, up to 39.
    private static func isOwner(_ owner: Substring) -> Bool {
        (1...39).contains(owner.count)
            && owner.unicodeScalars.allSatisfy(ownerCharacters.contains)
            && owner.first != "-" && owner.last != "-" && !owner.contains("--")
    }

    /// GitHub's rule for a repository: letters, digits, `.`, `-`, and `_`, up to 100, never `.` or `..`.
    private static func isName(_ name: String) -> Bool {
        (1...100).contains(name.count)
            && name.unicodeScalars.allSatisfy(nameCharacters.contains)
            && name != "." && name != ".."
    }

    private static let ownerCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )
    private static let nameCharacters = ownerCharacters.union(CharacterSet(charactersIn: "._"))
}

extension ScreencastRepository: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let repository = ScreencastRepository(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not owner/name"))
        }
        self = repository
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The review panel's guess, and what it was remembered for.
struct ScreencastRepositoryGuess: Equatable {
    enum Source: Equatable {
        /// The website's domain, or the one it's a part of (`github.com` for `gist.github.com`), or a
        /// local development host (`localhost:3000`).
        case website(String)
        /// The app's bundle identifier.
        case app(String)
    }

    let repository: ScreencastRepository
    let source: Source
}

/// Which repository each website's and app's captures go to, as the person corrected the review
/// panel's guess, so the next capture there guesses it. A website wins over the app showing it: a
/// browser shows many sites. Kept on this Mac only, in `screencast-repositories.json` in
/// Application Support, through `ProductPaths` so unit tests keep theirs in their own folder. User
/// content, never logged.
@MainActor
final class ScreencastRepositoryMemory {
    static let fileName = "screencast-repositories.json"

    struct Stored: Codable, Equatable {
        /// By domain, or by local development host (`localhost:3000`).
        var websites: [String: ScreencastRepository] = [:]
        /// By bundle identifier.
        var apps: [String: ScreencastRepository] = [:]
    }

    private(set) var stored: Stored
    private let storageURL: URL
    private let fileManager: FileManager

    init(storageURL: URL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        // A file that can't be read starts the memory over; it's rewritten at the next correction.
        stored = (try? Data(contentsOf: storageURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    static var defaultStorageURL: URL {
        ProductPaths.keybumps().applicationSupport.appendingPathComponent(fileName)
    }

    static func makeDefault() -> ScreencastRepositoryMemory {
        ScreencastRepositoryMemory(storageURL: defaultStorageURL)
    }

    /// The website's repository, or the nearest site it's part of that has one (`github.com` for
    /// `gist.github.com`); else the local development host's; else the app's.
    func guess(for context: ScreencastCaptureContext) -> ScreencastRepositoryGuess? {
        if let domain = context.domain {
            var labels = domain.split(separator: ".")
            while labels.count >= 2 {
                let site = labels.joined(separator: ".")
                if let repository = stored.websites[site] {
                    return ScreencastRepositoryGuess(repository: repository, source: .website(site))
                }
                labels.removeFirst()
            }
        }
        if let devHost = context.devHost, let repository = stored.websites[devHost] {
            return ScreencastRepositoryGuess(repository: repository, source: .website(devHost))
        }
        if let app = context.appBundleIdentifier, let repository = stored.apps[app] {
            return ScreencastRepositoryGuess(repository: repository, source: .app(app))
        }
        return nil
    }

    /// Remembers `repository` for the website in `context` (or its local development host), or for
    /// the app when it showed neither.
    func remember(_ repository: ScreencastRepository, for context: ScreencastCaptureContext) {
        var updated = stored
        if let site = context.domain ?? context.devHost {
            updated.websites[site] = repository
        } else if let app = context.appBundleIdentifier {
            updated.apps[app] = repository
        }
        guard updated != stored else { return }
        stored = updated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(stored) else { return }
        try? PrivateFile.write(data, to: storageURL, fileManager: fileManager)
    }
}
