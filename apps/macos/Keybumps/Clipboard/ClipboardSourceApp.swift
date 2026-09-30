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

/// The website a copy came from, kept as its domain (the URL's host) only. The page's full address,
/// path, query, and fragment are never kept, persisted, or logged.
enum ClipboardSourceDomain {
    /// The domain of the page a copy came from, when the browser put the page's address on the
    /// pasteboard: Chromium's source URL, or the main resource of Safari's web archive.
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

    /// The lowercased host of an http or https address; nil for any other scheme or no host.
    static func host(ofPageAddress address: String?) -> String? {
        guard let address, let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// WebKit's web archive is a property list whose main resource carries the page's address.
    static func mainResourceAddress(ofWebArchive data: Data) -> String? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mainResource = archive["WebMainResource"] as? [String: Any] else { return nil }
        return mainResource["WebResourceURL"] as? String
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
        frontmost: { NSWorkspace.shared.frontmostApplication.flatMap { ClipboardSourceApp($0) } },
        application: { ClipboardSourceApp.installed(bundleIdentifier: $0) },
        uptime: { ProcessInfo.processInfo.systemUptime }
    )
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
