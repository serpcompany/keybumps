import Foundation

/// Settings › Changelog's notes (#416): every release's What's New
/// (`docs/releases/v<version>.md`), which every build carries as `ReleaseNotes/v<version>.md`
/// (`project.yml`), so the page works offline. It lists the installed version and older ones,
/// newest first.
enum Changelog {
    static let notesDirectoryName = "ReleaseNotes"

    struct Entry: Equatable, Identifiable {
        let version: String
        let notes: ReleaseNotesDocument
        var id: String { version }
    }

    /// This build's notes. Debug builds keep the placeholder version from `project.yml`, so they
    /// list every release.
    static func entries(in bundle: Bundle = .main, isDebugBuild: Bool = UpdatePreview.isDebugBuild) -> [Entry] {
        guard let directory = bundle.resourceURL?.appendingPathComponent(notesDirectoryName, isDirectory: true) else { return [] }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return entries(in: directory, upTo: isDebugBuild ? nil : version.flatMap(ReleaseVersion.init))
    }

    /// The notes in `directory`, newest first, leaving out any newer than `newest`.
    static func entries(in directory: URL, upTo newest: ReleaseVersion?) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> (ReleaseVersion, Entry)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "md", name.hasPrefix("v"),
                  let version = ReleaseVersion(String(name.dropFirst())),
                  newest.map({ version <= $0 }) ?? true,
                  let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (version, Entry(version: version.description, notes: ReleaseNotesDocument(markdown: markdown)))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }
}

/// A Keybumps version such as `0.0.3` or `0.0.3-beta.23`, ordered the way SemVer orders releases.
/// A QA candidate's `0.0.3-dev.issue416` counts as `0.0.3`, so it lists every 0.0.3 beta's notes
/// and none as installed.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let core: [Int]
    let prerelease: [String]
    let description: String

    init?(_ string: String) {
        let release = string.components(separatedBy: "-dev.").first ?? string
        let parts = release.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        let core = first.split(separator: ".").map { Int($0) }
        guard !core.isEmpty, !core.contains(nil) else { return nil }
        self.core = core.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        description = release
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let length = max(lhs.core.count, rhs.core.count)
        let left = lhs.core + Array(repeating: 0, count: length - lhs.core.count)
        let right = rhs.core + Array(repeating: 0, count: length - rhs.core.count)
        if left != right { return left.lexicographicallyPrecedes(right) }
        // A release ranks above its prereleases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
