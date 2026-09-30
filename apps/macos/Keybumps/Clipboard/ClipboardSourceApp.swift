import AppKit
import Foundation

/// The app a Clipboard History item was copied from, as far as macOS lets Keybumps tell.
/// It is user content: kept only in the local Clipboard History, never logged.
struct ClipboardSourceApp: Codable, Equatable, Hashable {
    let bundleIdentifier: String?
    let name: String
}

extension ClipboardSourceApp {
    init?(_ application: NSRunningApplication) {
        guard let name = application.localizedName, !name.isEmpty else { return nil }
        self.init(bundleIdentifier: application.bundleIdentifier, name: name)
    }

    /// The running or installed app with this bundle identifier, or nil when this Mac doesn't have it.
    static func installed(bundleIdentifier: String) -> ClipboardSourceApp? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let app = ClipboardSourceApp(running) {
            return app
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let displayName = FileManager.default.displayName(atPath: url.path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        return name.isEmpty ? nil : ClipboardSourceApp(bundleIdentifier: bundleIdentifier, name: name)
    }
}

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org: the bundle identifier of the app the content came from ("" when unknown).
    static let nspasteboardSource = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// Present on items that arrived from another device through Universal Clipboard.
    static let universalClipboard = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    /// Chromium browsers: the URL of the page a copy came from.
    static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")
    /// Safari and other WebKit views: a web archive of the copied selection.
    static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
}

/// The website a copy came from, kept as its domain (the address's host) only. The page's full
/// address, path, query, and fragment are never kept, persisted, or logged.
enum ClipboardSourceDomain {
    /// A rich copy's web archive carries the selection's images too. Decoding a bigger one on the main
    /// actor for one address isn't worth it, so that item just gets no domain.
    static let maximumWebArchiveBytes = 8 * 1_024 * 1_024

    /// The domain of the page a copy came from, when the app put the page's address on the
    /// pasteboard: Chromium's source URL, or the main resource of a WebKit web archive.
    static func read(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []
        // Reading more of another device's data would only fetch it over the network.
        if types.contains(.universalClipboard) { return nil }
        if types.contains(.chromiumSourceURL) {
            return host(ofPageAddress: pasteboard.string(forType: .chromiumSourceURL))
        }
        if types.contains(.webArchive), let archive = pasteboard.data(forType: .webArchive) {
            return host(ofPageAddress: mainResourceAddress(ofWebArchive: archive))
        }
        return nil
    }

    /// The website domain of an http or https address: its host in ASCII, so an international or
    /// lookalike domain keeps its punycode `xn--` form (as browsers show it), lowercased and without
    /// a trailing dot. Nil for other schemes and for anything that isn't a website's domain name.
    static func host(ofPageAddress address: String?) -> String? {
        // `URLComponents.host` decodes punycode and percent escapes; `encodedHost` doesn't.
        guard let address, let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.encodedHost?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return isWebsiteDomain(host) ? host : nil
    }

    /// A dotted name of letters, digits, and hyphens. That leaves out escapes, control characters,
    /// and IPv6 literals; IPv4 addresses (a numeric last label); and `localhost` and other
    /// single-label local names, which aren't websites.
    static func isWebsiteDomain(_ host: String) -> Bool {
        guard host.count <= 253, host.unicodeScalars.allSatisfy(hostCharacters.contains) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }),
              let last = labels.last, last != "localhost", !last.allSatisfy(\.isNumber) else { return false }
        return true
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// WebKit's web archive is a property list whose main resource carries the page's address.
    static func mainResourceAddress(ofWebArchive data: Data) -> String? {
        guard data.count <= maximumWebArchiveBytes,
              let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mainResource = archive["WebMainResource"] as? [String: Any] else { return nil }
        return mainResource["WebResourceURL"] as? String
    }
}

/// Prefix matching for the source app and domain in Clipboard tab search, so a short query such as
/// `com` or `www` doesn't match every item copied from the web.
enum ClipboardSourceSearch {
    /// True when `query` matches `name` from the start of a word: the start of the name, after a space
    /// or punctuation, at a capital after a lowercase letter (`Edit` in `TextEdit`), or at a letter
    /// after a digit (`Writer` in `9Writer`).
    static func matchesWordStart(_ query: String, in name: String) -> Bool {
        guard !query.isEmpty else { return false }
        var previous: Character?
        for index in name.indices {
            let character = name[index]
            let isWordCharacter = character.isLetter || character.isNumber
            let startsWord = isWordCharacter && previous.map {
                !($0.isLetter || $0.isNumber)
                    || ($0.isLowercase && character.isUppercase)
                    || ($0.isNumber && character.isLetter)
            } ?? isWordCharacter
            if startsWord, name[index...].range(of: query, options: [.caseInsensitive, .anchored], locale: .current) != nil {
                return true
            }
            previous = character
        }
        return false
    }

    /// True when `query` matches `domain` from the start of a label other than the last one (the
    /// top-level domain), or from a `www` label only when the query goes past `www.`.
    static func matchesLabelStart(_ query: String, in domain: String) -> Bool {
        let query = query.lowercased()
        let labels = domain.split(separator: ".")
        guard !query.isEmpty, labels.count >= 2 else { return false }
        for start in 0..<(labels.count - 1) where labels[start...].joined(separator: ".").hasPrefix(query) {
            if labels[start] == "www", query.count <= 4 { continue }
            return true
        }
        return false
    }
}

extension NSPasteboard {
    /// Marks what Keybumps just wrote as coming from Keybumps (nspasteboard.org), so Clipboard History
    /// doesn't credit the app in front, which is often the app behind the non-activating Command Palette.
    /// Call it after writing the content.
    func markCopiedByKeybumps() {
        setString(Bundle.main.bundleIdentifier ?? "", forType: .nspasteboardSource)
    }
}

/// How Clipboard History learns which app is in front and looks apps up. Tests inject made-up apps.
struct ClipboardSourceAppReader {
    var frontmost: @MainActor () -> ClipboardSourceApp?
    var application: @MainActor (_ bundleIdentifier: String) -> ClipboardSourceApp?
    var uptime: @MainActor () -> TimeInterval

    static let system = ClipboardSourceAppReader(
        frontmost: {
            ClipboardSourceAppReader.appInFront(
                keybumpsHasKeyWindow: NSApplication.shared.keyWindow != nil,
                keybumps: ClipboardSourceApp(.current),
                frontmost: NSWorkspace.shared.frontmostApplication.flatMap { ClipboardSourceApp($0) }
            )
        },
        application: { ClipboardSourceApp.installed(bundleIdentifier: $0) },
        uptime: { ProcessInfo.processInfo.systemUptime }
    )

    /// For tests and the UI-test composition: never reads the Mac's real apps.
    static let inert = ClipboardSourceAppReader(frontmost: { nil }, application: { _ in nil }, uptime: { 0 })

    /// A copy made in one of Keybumps' own windows is Keybumps', including the non-activating Command
    /// Palette, which takes key focus without making Keybumps the frontmost app.
    static func appInFront(
        keybumpsHasKeyWindow: Bool,
        keybumps: ClipboardSourceApp?,
        frontmost: ClipboardSourceApp?
    ) -> ClipboardSourceApp? {
        keybumpsHasKeyWindow ? keybumps ?? frontmost : frontmost
    }
}

/// Works out the source app of a pasteboard change Clipboard History's poll noticed.
///
/// macOS has no API that names the app that wrote the pasteboard, so in order:
/// 1. Universal Clipboard items have none; the Mac app in front didn't copy them.
/// 2. An `org.nspasteboard.source` marker names it (empty means unknown).
/// 3. Otherwise it's the app in front, sampled on every poll. If the app in front changed between two
///    polls less than `switchWindow` apart, the copy most likely came just before the switch (⌘C, ⌘Tab),
///    so the earlier app wins. Polls further apart (a throttled timer) keep the app in front now.
@MainActor
final class ClipboardSourceTracker {
    struct Sample: Equatable {
        let app: ClipboardSourceApp?
        let uptime: TimeInterval
    }

    nonisolated static let switchWindow: TimeInterval = 1

    private let reader: ClipboardSourceAppReader
    private var latest: Sample?
    private var previous: Sample?

    init(reader: ClipboardSourceAppReader) {
        self.reader = reader
    }

    /// Records the app in front; Clipboard History calls it on every poll, before checking for a change.
    func sample() {
        previous = latest
        latest = Sample(app: reader.frontmost(), uptime: reader.uptime())
    }

    func reset() {
        latest = nil
        previous = nil
    }

    func sourceApp(of pasteboard: NSPasteboard) -> ClipboardSourceApp? {
        let types = pasteboard.types ?? []
        if types.contains(.universalClipboard) { return nil }
        if types.contains(.nspasteboardSource) {
            let bundleIdentifier = pasteboard.string(forType: .nspasteboardSource)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return bundleIdentifier.isEmpty ? nil : reader.application(bundleIdentifier)
        }
        return Self.frontmostSource(latest: latest, previous: previous)
    }

    nonisolated static func frontmostSource(latest: Sample?, previous: Sample?) -> ClipboardSourceApp? {
        guard let latest else { return previous?.app }
        guard let previous, let earlierApp = previous.app, earlierApp != latest.app,
              latest.uptime - previous.uptime <= switchWindow else { return latest.app }
        return earlierApp
    }
}
