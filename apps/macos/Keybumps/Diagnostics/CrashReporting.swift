import Foundation
import Sentry

/// Whether and where crash reports go (ADR 0007). Pure, so tests cover it; `CrashReporter`
/// applies it to Sentry.
enum CrashReportingPolicy {
    static let destinationInfoKey = "KBCrashReportsDSN"

    /// The build's destination. Only Release builds (and so QA candidates) carry one, and a
    /// unit-test host never reports.
    static func destination(info: [String: Any]?, isUnitTestHost: Bool) -> String? {
        guard !isUnitTestHost,
              let dsn = info?[destinationInfoKey] as? String,
              dsn.hasPrefix("https://") else { return nil }
        return dsn
    }

    /// QA candidates, staging builds, and public releases report separately.
    static func environment(version: String, feedURL: String?) -> String {
        if version.contains("-dev.") { return "qa" }
        if feedURL?.contains("/staging/") == true { return "staging" }
        return "production"
    }

    /// Contexts a report keeps: the app, the Mac's model and macOS, and which plugins are on.
    /// Everything else Sentry attaches, such as locale and time zone, is dropped.
    static let keptContexts: Set<String> = ["app", "device", "os", "runtime", "trace", "plugins"]

    /// Only breadcrumbs Keybumps leaves itself, which hold stages and categories, never content.
    static func keepsBreadcrumb(category: String) -> Bool {
        category.hasPrefix("keybumps.")
    }
}

/// Removes what a crash report must never carry (ADR 0007) from its free text: paths in a home
/// folder or on another volume, URLs, and email addresses. Stack frames, versions, and error
/// categories pass through.
enum CrashReportScrubber {
    private static let rules: [(NSRegularExpression, String)] = [
        // A URL runs to the next space or quote.
        (#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]*"#, "<url>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        // A path can contain spaces, so it runs to the end of the line or the next quote: losing
        // the rest of a message is better than leaking a file name.
        (#"(?:/Users|/Volumes)/[^\n"'<>]*"#, "<path>"),
        (#"~/[^\n"'<>]*"#, "<path>"),
    ].map { pattern, replacement in
        // The patterns are constants; a typo fails every scrubber test.
        (try! NSRegularExpression(pattern: pattern), replacement)
    }

    static func scrub(_ text: String) -> String {
        rules.reduce(text) { text, rule in
            let range = NSRange(text.startIndex..., in: text)
            return rule.0.stringByReplacingMatches(in: text, range: range, withTemplate: rule.1)
        }
    }

    static func scrub(_ text: String?) -> String? {
        text.map { scrub($0) }
    }

    /// Applies the policy to an event just before Sentry sends it, crashes from an earlier run
    /// included.
    static func scrub(_ event: Event) -> Event {
        event.serverName = nil
        event.request = nil
        event.extra = nil
        event.error = nil
        // The random install identifier Sentry counts crash-free users with, and nothing else.
        event.user = event.user?.userId.map { User(userId: $0) }
        if let message = event.message {
            event.message = SentryMessage(formatted: scrub(message.formatted))
        }
        event.exceptions?.forEach { exception in
            exception.value = scrub(exception.value)
            scrubFrames(exception.stacktrace)
        }
        event.threads?.forEach { scrubFrames($0.stacktrace) }
        scrubFrames(event.stacktrace)
        event.debugMeta?.forEach { $0.codeFile = scrub($0.codeFile) }
        event.breadcrumbs = event.breadcrumbs?.filter { CrashReportingPolicy.keepsBreadcrumb(category: $0.category) }
        event.context = event.context?.filter { CrashReportingPolicy.keptContexts.contains($0.key) }
        return event
    }

    private static func scrubFrames(_ stacktrace: SentryStacktrace?) {
        stacktrace?.frames.forEach { frame in
            frame.package = scrub(frame.package)
            frame.fileName = scrub(frame.fileName)
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }
}

/// Sends crashes, freezes, and the errors Keybumps reports itself to Sentry (ADR 0007), when the
/// build carries a destination and the person hasn't turned it off in Settings › General.
@MainActor
enum CrashReporter {
    private(set) static var isRunning = false

    /// Called first thing at launch, so a crash during startup is caught too.
    static func startIfAllowed(defaults: UserDefaults = .standard) {
        guard AppPreferences.sendsCrashReports(in: defaults) else { return }
        start()
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    /// Which plugins are on, by name, so a report says what was running.
    static func recordPlugins(_ capabilities: Set<Capability>) {
        guard isRunning else { return }
        let names = capabilities.map(\.rawValue).sorted()
        SentrySDK.configureScope { $0.setContext(value: ["on": names], key: "plugins") }
    }

    private static func start(bundle: Bundle = .main) {
        guard !isRunning,
              let dsn = CrashReportingPolicy.destination(info: bundle.infoDictionary, isUnitTestHost: UnitTestHost.isActive)
        else { return }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = CrashReportingPolicy.environment(version: version, feedURL: feedURL)
            options.sendDefaultPii = false
            // Crashes and freezes only: no automatic breadcrumbs, network capture, or tracing, any
            // of which could carry user content. (Screenshots and view hierarchy are iOS-only.)
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.tracesSampleRate = nil
            options.beforeBreadcrumb = { breadcrumb in
                CrashReportingPolicy.keepsBreadcrumb(category: breadcrumb.category) ? breadcrumb : nil
            }
            options.beforeSend = { CrashReportScrubber.scrub($0) }
        }
        isRunning = true
    }

    private static func stop() {
        guard isRunning else { return }
        SentrySDK.close()
        isRunning = false
    }
}

enum CrashReportingCopy {
    static let settingsNote = "When Keybumps crashes or freezes, it sends a report to its developers through Sentry: the Keybumps and macOS versions, your Mac's model, which plugins are on, and where in Keybumps's code it happened. Reports never include your clipboard, snippets, transcripts, recordings, screenshots, searches, or file names."
}
