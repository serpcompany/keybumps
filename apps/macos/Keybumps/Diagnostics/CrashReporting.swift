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

    /// QA candidates report apart from public releases. (CI publishes one build to both update
    /// channels, so a build can't tell staging from production.)
    static func environment(version: String) -> String {
        version.contains("-dev.") ? "qa" : "production"
    }

    /// Contexts a report keeps: the app, the Mac's model and macOS, and which plugins are on.
    /// Everything else Sentry attaches, such as culture (locale, time zone), is dropped.
    static let keptContexts: Set<String> = ["app", "device", "os", "runtime", "trace", "plugins"]

    /// Fields dropped from kept contexts: `device_app_hash` is derived from the Mac's network
    /// address, so it's a fixed hardware identifier; locale says where someone is.
    static let droppedContextFields: [String: Set<String>] = [
        "app": ["device_app_hash"],
        "device": ["locale", "timezone"],
    ]

    /// Only breadcrumbs Keybumps leaves itself, which hold stages and categories, never content.
    static func keepsBreadcrumb(category: String) -> Bool {
        category.hasPrefix("keybumps.")
    }
}

/// Removes what a crash report must never carry (ADR 0007) from its free text: paths in a home
/// folder, on another volume, or in a temporary folder; URLs; and email addresses. Stack frames,
/// versions, and error categories pass through.
enum CrashReportScrubber {
    /// Where a path or URL ends: a line break, a double quote (straight or curly), or an angle
    /// bracket. Not at a space or an apostrophe, which file names contain ("Pat's Q3 plan.txt").
    private static let end = #"\n"“”<>"#

    private static let rules: [(NSRegularExpression, String)] = [
        // Cocoa puts a file's name in quotes, which depend on the language: “Q3 plan.txt”
        // (English, Japanese), „…“ (German), „…” (Polish), ”…” (Swedish), « … » (French),
        // »…« (Slovenian), 「…」 (Traditional Chinese), ״…״ (Hebrew), "…" (Arabic). Korean and
        // Dutch use single quotes, which can't be told from apostrophes, so those names stay.
        (#"[“„”«‹»]\s?[^“”„«»‹›\n]*\s?[”“»›«]"#, "“<name>”"),
        (#"「[^」\n]*」"#, "“<name>”"),
        (#"״[^״\n]*״"#, "“<name>”"),
        (#""[^"\n]*""#, "“<name>”"),
        // A URL or path runs to the end of the line or the next double quote: losing the rest of
        // a message is better than leaking a file name.
        (#"[A-Za-z][A-Za-z0-9+.\-]*://[^"# + end + "]*", "<url>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"(?:/Users|/Volumes|/private|/tmp|/var/folders)/[^"# + end + "]*", "<path>"),
        (#"~/[^"# + end + "]*", "<path>"),
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

    /// A binary's path keeps its file name, which is Keybumps's or a system library's, so a
    /// copy run from a home folder still shows which binary a frame is in.
    static func scrubImagePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let scrubbed = scrub(path)
        guard scrubbed != path else { return path }
        return "<path>/" + (path as NSString).lastPathComponent
    }

    /// Strings anywhere in a value, such as the raw Swift runtime messages Sentry keeps in an
    /// exception's mechanism data.
    static func scrubValue(_ value: Any) -> Any {
        switch value {
        case let text as String: return scrub(text)
        case let list as [Any]: return list.map(scrubValue)
        case let dictionary as [String: Any]: return dictionary.mapValues(scrubValue)
        default: return value
        }
    }

    /// Applies the policy to an event just before Sentry sends it, crashes from an earlier run
    /// included.
    static func scrub(_ event: Event) -> Event {
        event.serverName = nil
        event.request = nil
        event.extra = nil
        event.error = nil
        // Sentry's random install identifier, and nothing else.
        event.user = event.user?.userId.map { User(userId: $0) }
        if let message = event.message {
            event.message = SentryMessage(formatted: scrub(message.formatted))
        }
        event.exceptions?.forEach { exception in
            exception.value = scrub(exception.value)
            if let mechanism = exception.mechanism {
                mechanism.desc = scrub(mechanism.desc)
                mechanism.data = mechanism.data?.mapValues(scrubValue)
            }
            scrubFrames(exception.stacktrace)
        }
        event.threads?.forEach { scrubFrames($0.stacktrace) }
        scrubFrames(event.stacktrace)
        event.debugMeta?.forEach { $0.codeFile = scrubImagePath($0.codeFile) }
        event.breadcrumbs = event.breadcrumbs?.filter { CrashReportingPolicy.keepsBreadcrumb(category: $0.category) }
        event.context = event.context.map(scrubContexts)
        return event
    }

    static func scrubContexts(_ contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        contexts.reduce(into: [:]) { kept, entry in
            guard CrashReportingPolicy.keptContexts.contains(entry.key) else { return }
            let dropped = CrashReportingPolicy.droppedContextFields[entry.key] ?? []
            kept[entry.key] = entry.value.filter { !dropped.contains($0.key) }
        }
    }

    private static func scrubFrames(_ stacktrace: SentryStacktrace?) {
        stacktrace?.frames.forEach { frame in
            frame.package = scrubImagePath(frame.package)
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
        if isRunning { CrashReportTest.runIfRequested() }
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
        SentrySDK.start { configure($0, dsn: dsn, environment: CrashReportingPolicy.environment(version: version)) }
        isRunning = true
    }

    /// Every option the privacy promise rests on, in one place `CrashReportingTests` checks.
    nonisolated static func configure(_ options: Options, dsn: String, environment: String) {
        options.dsn = dsn
        options.environment = environment
        options.sendDefaultPii = false
        options.enableCrashHandler = true
        // Freezes of two seconds or more.
        options.enableAppHangTracking = true
        // Off whatever the SDK's default: an uncaught exception ending the app (ADR 0007, decision
        // 5), MetricKit's diagnostics, and Sentry's log capture.
        options.enableUncaughtNSExceptionReporting = false
        options.enableMetricKit = false
        options.enableLogs = false
        // No session records: they'd report every launch and how long Keybumps ran, which is
        // usage, not a crash.
        options.enableAutoSessionTracking = false
        // Turning reports off doesn't wait on the network. A report already queued while they
        // were on may still go out.
        options.shutdownTimeInterval = 0
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

    private static func stop() {
        guard isRunning else { return }
        SentrySDK.close()
        isRunning = false
    }
}

/// QA candidates only: `-KBTestCrash YES` crashes Keybumps on purpose a few seconds after launch,
/// and `-KBTestFreeze YES` freezes it for five seconds, so a candidate proves a real report
/// reaches Sentry. A crash is sent on the next launch.
@MainActor
enum CrashReportTest {
    static func isAllowed(version: String) -> Bool {
        version.contains("-dev.")
    }

    static func runIfRequested(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard isAllowed(version: version) else { return }
        if defaults.bool(forKey: "KBTestFreeze") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Thread.sleep(forTimeInterval: 5) }
        }
        if defaults.bool(forKey: "KBTestCrash") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { SentrySDK.crash() }
        }
    }
}

enum CrashReportingCopy {
    static let settingsNote = "When Keybumps crashes or freezes, it sends a report to its developers through Sentry: the Keybumps and macOS versions, your Mac's model, which plugins are on, and where in Keybumps's code it happened. Reports never include your clipboard, snippets, transcripts, recordings, screenshots, or searches, and Keybumps removes file paths and names from them."
}
