import AppKit
import ApplicationServices

/// The app in front when a capture started and, for a browser, the website it showed: what the
/// review panel guesses the repository from, and what a sent capture says it was taken in. User
/// content: kept only in the capture's `meta.json` and the repository memory, never logged. The
/// website is its domain alone, reduced as Clipboard History's source domain is
/// (`ClipboardSourceDomain`); the page's address is never kept.
struct ScreencastCaptureContext: Codable, Equatable, Sendable {
    var appBundleIdentifier: String?
    var appName: String?
    var domain: String?
    /// A local development site the browser showed instead, such as `localhost:3000`
    /// (`ScreencastDevHost`), for the repository guess only. It isn't a website, so a sent capture
    /// doesn't name it.
    var devHost: String?

    static let none = ScreencastCaptureContext()

    init(appBundleIdentifier: String? = nil, appName: String? = nil, domain: String? = nil, devHost: String? = nil) {
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.domain = domain
        self.devHost = devHost
    }
}

/// A local development site's host, for the repository guess (owner, 2026-10-11): the names
/// Clipboard History's source domain leaves out because they aren't websites, `localhost`,
/// `*.localhost`, `*.test`, and `127.0.0.1`, with the port, since each app being built has its own
/// (`localhost:3000`). Layered on `ClipboardSourceDomain`, which doesn't change. Like a domain, it's
/// the host alone, never the path or query, and stays on this Mac.
enum ScreencastDevHost {
    static func host(ofPageAddress address: String?) -> String? {
        guard let address, let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.encodedHost?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard isDevHost(host) else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    static func isDevHost(_ host: String) -> Bool {
        if host == "127.0.0.1" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, host.unicodeScalars.allSatisfy(hostCharacters.contains),
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        switch labels.last {
        case "localhost": return true
        case "test": return labels.count >= 2
        default: return false
        }
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
}

/// Reads the capture-time context; the flow controller calls it when a capture starts. It never
/// asks for a permission. The website comes only through Accessibility, which Keybumps may already
/// have for Dictation, Window Manager, or Shortcut Coach: its focused window's `AXDocument`, or the
/// `AXURL` of the web page inside it, read only while `AXIsProcessTrusted()` (which never prompts)
/// says yes. Without it, the app alone. Never Apple Events.
struct ScreencastCaptureContextReader {
    var read: @MainActor () async -> ScreencastCaptureContext

    /// Reads nothing: the unit-test host's, and the UI-test composition's.
    static let inert = ScreencastCaptureContextReader { .none }

    static let system = ScreencastCaptureContextReader {
        let front = NSWorkspace.shared.frontmostApplication.map {
            FrontApp(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName)
        }
        return await context(
            front: front,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            isBrowser: ScreencastBrowsers.contains,
            accessibilityTrusted: { AXIsProcessTrusted() },
            pageAddress: { pid in
                await Task.detached(priority: .userInitiated) { ScreencastPageAddress.read(processIdentifier: pid) }.value
            }
        )
    }

    /// The system reader, except under the unit-test host.
    static var current: ScreencastCaptureContextReader {
        UnitTestHost.isActive ? .inert : .system
    }

    /// The app in front, as macOS names it.
    struct FrontApp: Equatable, Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let name: String?
    }

    /// The context for `front`: none for Keybumps itself; otherwise the app and, for a browser, the
    /// domain of the page in its focused window, or its local development host. `pageAddress` is
    /// asked only for a browser while Accessibility is allowed, and its answer is reduced to a host
    /// at once.
    @MainActor
    static func context(
        front: FrontApp?,
        ownProcessIdentifier: pid_t,
        isBrowser: (String) -> Bool,
        accessibilityTrusted: () -> Bool,
        pageAddress: (pid_t) async -> String?
    ) async -> ScreencastCaptureContext {
        guard let front, front.processIdentifier != ownProcessIdentifier else { return .none }
        let bundleIdentifier = front.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let name = front.name.flatMap { $0.isEmpty ? nil : $0 }
        var context = ScreencastCaptureContext(appBundleIdentifier: bundleIdentifier, appName: name)
        if let bundleIdentifier, isBrowser(bundleIdentifier), accessibilityTrusted() {
            let address = await pageAddress(front.processIdentifier)
            context.domain = ClipboardSourceDomain.host(ofPageAddress: address)
            if context.domain == nil { context.devHost = ScreencastDevHost.host(ofPageAddress: address) }
        }
        return context
    }
}

/// The apps that open web pages, as Launch Services lists them: Safari, Chrome, Firefox, Arc, and
/// the rest, without a list to keep up.
@MainActor
enum ScreencastBrowsers {
    private static var bundleIdentifiers: Set<String>?

    static func contains(_ bundleIdentifier: String) -> Bool {
        if bundleIdentifiers == nil {
            let page = URL(string: "https://example.com")!
            bundleIdentifiers = Set(NSWorkspace.shared.urlsForApplications(toOpen: page).compactMap {
                Bundle(url: $0)?.bundleIdentifier
            })
        }
        return bundleIdentifiers?.contains(bundleIdentifier) ?? false
    }
}

/// The address of the page in an app's focused window, through Accessibility: the window's
/// `AXDocument`, or else the `AXURL` of the first web area inside it. Bounded, so an app that's slow
/// to answer can't hold up the review: every element read waits at most `messagingTimeout` (macOS
/// applies a timeout to the one element it's set on, so each gets its own), never past `deadline`
/// for the whole read, and the search stops after `searchLimit` elements. The address is only
/// reduced to a host by the caller, never kept.
enum ScreencastPageAddress {
    static let messagingTimeout: Float = 0.2
    static let searchLimit = 400
    static let maximumDepth = 10
    static let deadline: TimeInterval = 1

    static func read(processIdentifier: pid_t) -> String? {
        let budget = Budget(until: Date().addingTimeInterval(deadline))
        let app = AXUIElementCreateApplication(processIdentifier)
        guard let window = budget.element(kAXFocusedWindowAttribute, of: app) else { return nil }
        if let document = budget.value(kAXDocumentAttribute, of: window) as? String, !document.isEmpty {
            return document
        }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var next = 0
        while next < queue.count, next < searchLimit, budget.hasTimeLeft {
            let (element, depth) = queue[next]
            next += 1
            if budget.value(kAXRoleAttribute, of: element) as? String == "AXWebArea",
               let address = budget.value(kAXURLAttribute, of: element) as? URL {
                return address.absoluteString
            }
            guard depth < maximumDepth, let children = budget.value(kAXChildrenAttribute, of: element) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    /// What's left of the read's time; each element read gets `messagingTimeout`, or less near the end.
    private struct Budget {
        let until: Date

        var hasTimeLeft: Bool { until.timeIntervalSinceNow > 0 }

        func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
            let left = until.timeIntervalSinceNow
            guard left > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, min(ScreencastPageAddress.messagingTimeout, Float(left)))
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }

        func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
            guard let value = value(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }
}
