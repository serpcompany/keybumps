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

    /// Contexts a report keeps: the app, the Mac's model and macOS, which plugins are on, and for a
    /// problem report, permission states and the contact email the person chose to give.
    /// Everything else Sentry attaches, such as culture (locale, time zone), is dropped.
    static let keptContexts: Set<String> = ["app", "device", "os", "runtime", "trace", "plugins", "permissions", "report"]

    /// Fields dropped from kept contexts: `device_app_hash` is derived from the Mac's network
    /// address, so it's a fixed hardware identifier; locale says where someone is.
    static let droppedContextFields: [String: Set<String>] = [
        "app": ["device_app_hash"],
        "device": ["locale", "timezone"],
    ]

    /// Sentry's folder, Keybumps' own. Sentry's default is the Caches folder itself, which every
    /// unsandboxed app shares, along with the install identifier Sentry keeps there.
    static func cacheDirectory(caches: String, bundleID: String) -> String {
        ((caches as NSString).appendingPathComponent(bundleID) as NSString).appendingPathComponent("Sentry")
    }

    /// Sentry's queue while it runs only to send problem reports: apart from its usual queue, so a
    /// crash report queued before reports were turned off never goes out with a problem report.
    static func sendOnlyDirectory(in cacheDirectory: String) -> String {
        (cacheDirectory as NSString).appendingPathComponent("Problem reports")
    }

    /// An email address, in any script ("josé@…", "o'brien@…", Devanagari with its vowel marks):
    /// what the scrubber removes from free text, and the only thing a problem report's contact field
    /// may hold. A match starts only where a run of address characters starts, and the part before
    /// the @ never backtracks, so a long pasted token or a paragraph of Chinese stays fast.
    static let emailPattern = #"(?<![\p{L}\p{M}\p{N}._%+'\-])[\p{L}\p{M}\p{N}._%+'\-]++@[\p{L}\p{M}\p{N}.\-]+\.\p{L}[\p{L}\p{M}]+"#

    static let installIDKey = "crashReportsInstallID"

    /// A random identifier Keybumps creates once and keeps, so reports from one copy can be told
    /// apart from another's, whether Sentry runs for crashes or only for a problem report.
    static func installID(defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: installIDKey), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// Whether a Sentry folder holds a report it couldn't deliver yet. Sentry queues each one as a
    /// file in `io.sentry/<hash>/envelopes`.
    static func hasQueuedReports(in directory: String, fileManager: FileManager = .default) -> Bool {
        guard let paths = fileManager.enumerator(atPath: directory) else { return false }
        for case let path as String in paths
        where ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "envelopes" {
            return true
        }
        return false
    }

    /// Moves reports waiting in one Sentry folder's queue to the same place in another's. Both
    /// queues use the same destination, so the relative path (`io.sentry/<hash>/envelopes/…`) is
    /// the same, and Sentry running on the target folder sends them, retrying when the network
    /// returns.
    static func moveQueuedReports(from source: String, to target: String, fileManager: FileManager = .default) {
        guard let paths = fileManager.enumerator(atPath: source) else { return }
        for case let path as String in paths
        where ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "envelopes" {
            let destination = (target as NSString).appendingPathComponent(path)
            try? fileManager.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? fileManager.moveItem(atPath: (source as NSString).appendingPathComponent(path), toPath: destination)
        }
    }

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

    private static let quotedNameRules: [(NSRegularExpression, String)] = compile([
        // Cocoa puts a file's name in quotes, which depend on the language: “Q3 plan.txt”
        // (English, Japanese), „…“ (German), „…” (Polish), ”…” (Swedish), « … » (French),
        // »…« (Slovenian), 「…」 (Traditional Chinese), ״…״ (Hebrew), "…" (Arabic). Korean and
        // Dutch use single quotes, which can't be told from apostrophes, so those names stay.
        (#"[“„”«‹»]\s?[^“”„«»‹›\n]*\s?[”“»›«]"#, "“<name>”"),
        (#"「[^」\n]*」"#, "“<name>”"),
        (#"״[^״\n]*״"#, "“<name>”"),
        (#""[^"\n]*""#, "“<name>”"),
    ])

    private static let pathRules: [(NSRegularExpression, String)] = compile([
        // A URL or path runs to the end of the line or the next double quote: losing the rest of
        // a message is better than leaking a file name.
        // Only from the start of a scheme, which never backtracks, so a long run of letters stays fast.
        (#"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*+://[^"# + end + "]*", "<url>"),
        (CrashReportingPolicy.emailPattern, "<email>"),
        (#"(?:/Users|/Volumes|/private|/tmp|/var/folders)/[^"# + end + "]*", "<path>"),
        (#"~/[^"# + end + "]*", "<path>"),
    ])

    private static func compile(_ rules: [(String, String)]) -> [(NSRegularExpression, String)] {
        rules.map { pattern, replacement in
            // The patterns are constants; a typo fails every scrubber test.
            (try! NSRegularExpression(pattern: pattern), replacement)
        }
    }

    private static func apply(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
        rules.reduce(text) { text, rule in
            let range = NSRange(text.startIndex..., in: text)
            return rule.0.stringByReplacingMatches(in: text, range: range, withTemplate: rule.1)
        }
    }

    static func scrub(_ text: String) -> String {
        apply(pathRules, to: apply(quotedNameRules, to: text))
    }

    /// What a person writes in a problem report: paths, URLs, and email addresses go, but quoted
    /// text stays, since it's their words (“Language” doesn't open), not a name Cocoa quoted.
    static func scrubWritten(_ text: String) -> String {
        apply(pathRules, to: text)
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
        // The install identifier, and nothing else. (`beforeSend` then sets it to Keybumps' own.)
        event.user = event.user?.userId.map { User(userId: $0) }
        if let message = event.message {
            let isWritten = event.tags?[ProblemReport.tag.key] == ProblemReport.tag.value
            event.message = SentryMessage(formatted: isWritten ? scrubWritten(message.formatted) : scrub(message.formatted))
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

/// CrashReporter's modes, and what each event asks of Sentry, apart from Sentry so tests can play
/// every order of events.
struct CrashReporterMachine: Equatable {
    enum Mode: Equatable { case off, reporting, sendingOnly }
    enum Action: Equatable { case startReporting, startSendingOnly, capture, flush, close }

    private(set) var mode = Mode.off
    /// Flushes still running while Sentry runs only to send problem reports.
    private(set) var inFlight = 0
    /// Reports were turned on while problem reports were sending; they start once those are sent.
    private(set) var startsWhenSent = false

    mutating func turnOn() -> [Action] {
        switch mode {
        case .reporting:
            return []
        case .sendingOnly:
            startsWhenSent = true
            return []
        case .off:
            mode = .reporting
            return [.startReporting]
        }
    }

    mutating func turnOff() -> [Action] {
        startsWhenSent = false
        guard mode == .reporting else { return [] }
        mode = .off
        return [.close]
    }

    /// A problem report the person sends. With reports off, Sentry starts just to send it.
    mutating func send() -> [Action] {
        switch mode {
        case .reporting:
            return [.capture]
        case .sendingOnly:
            inFlight += 1
            return [.capture, .flush]
        case .off:
            mode = .sendingOnly
            inFlight = 1
            return [.startSendingOnly, .capture, .flush]
        }
    }

    /// Problem reports an earlier send couldn't deliver, found at launch before reporting starts.
    mutating func drain() -> [Action] {
        guard mode == .off else { return [] }
        mode = .sendingOnly
        inFlight = 1
        return [.startSendingOnly, .flush]
    }

    mutating func flushed() -> [Action] {
        inFlight -= 1
        guard mode == .sendingOnly, inFlight == 0 else { return [] }
        guard startsWhenSent else {
            mode = .off
            return [.close]
        }
        startsWhenSent = false
        mode = .reporting
        return [.close, .startReporting]
    }
}

/// Sends crashes, freezes, and problem reports to Sentry (ADR 0007). Crashes and freezes go only
/// when the build carries a destination and the person hasn't turned reports off in Settings ›
/// General. A problem report someone writes goes either way: with reports off, Sentry runs just
/// long enough to send it, with crash and freeze reporting off.
@MainActor
enum CrashReporter {
    private static var machine = CrashReporterMachine()
    /// Which plugins are on, kept so a new start of Sentry reports them too.
    private static var pluginNames: [String] = []

    nonisolated static let bundleID = Bundle.main.bundleIdentifier ?? "com.serp.keybumps"

    /// Whether crashes and freezes are being reported.
    static var isRunning: Bool { machine.mode == .reporting }

    /// Called first thing at launch, so a crash during startup is caught too. A problem report an
    /// earlier send couldn't deliver joins the crash-report queue when reports are on; with them
    /// off, Sentry starts just to send it.
    static func startIfAllowed(defaults: UserDefaults = .standard) {
        guard destination() != nil else { return }
        if AppPreferences.sendsCrashReports(in: defaults) {
            apply(machine.turnOn())
        } else if CrashReportingPolicy.hasQueuedReports(in: sendOnlyDirectory) {
            apply(machine.drain())
        }
    }

    static func setEnabled(_ enabled: Bool) {
        apply(enabled ? machine.turnOn() : machine.turnOff())
    }

    /// Which plugins are on, by name, so a report says what was running.
    static func recordPlugins(_ capabilities: Set<Capability>) {
        pluginNames = capabilities.map(\.rawValue).sorted()
        guard machine.mode != .off else { return }
        let names = pluginNames
        SentrySDK.configureScope { $0.setContext(value: ["on": names], key: "plugins") }
    }

    /// Whether this build can send a problem report at all.
    static var canSendProblemReports: Bool {
        destination() != nil
    }

    /// Sends a problem report. Returns false when this build has nowhere to send it.
    static func send(_ report: ProblemReport, plugins: Set<Capability>) -> Bool {
        guard destination() != nil else { return false }
        pluginNames = plugins.map(\.rawValue).sorted()
        apply(machine.send(), event: report.event())
        return true
    }

    private static func apply(_ actions: [CrashReporterMachine.Action], event: Event? = nil) {
        for action in actions {
            switch action {
            case .startReporting, .startSendingOnly:
                guard let dsn = destination() else { return }
                if action == .startReporting {
                    // A problem report still waiting goes with the crash reports, retried until sent.
                    CrashReportingPolicy.moveQueuedReports(from: sendOnlyDirectory, to: mainDirectory)
                }
                let environment = currentEnvironment()
                let installID = CrashReportingPolicy.installID(defaults: .standard)
                let sendingOnly = action == .startSendingOnly
                SentrySDK.start { options in
                    if sendingOnly {
                        configureSendingOnly(options, dsn: dsn, environment: environment, installID: installID)
                    } else {
                        configure(options, dsn: dsn, environment: environment, installID: installID)
                    }
                }
                let names = pluginNames
                SentrySDK.configureScope { $0.setContext(value: ["on": names], key: "plugins") }
            case .capture:
                if let event { SentrySDK.capture(event: event) }
            case .flush:
                // Closing at once would leave the report queued until Sentry next runs to send one.
                Task.detached(priority: .utility) {
                    SentrySDK.flush(timeout: 15)
                    await MainActor.run { apply(machine.flushed()) }
                }
            case .close:
                SentrySDK.close()
            }
        }
    }

    private static var mainDirectory: String {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        return CrashReportingPolicy.cacheDirectory(caches: caches, bundleID: bundleID)
    }

    private static var sendOnlyDirectory: String {
        CrashReportingPolicy.sendOnlyDirectory(in: mainDirectory)
    }

    private static func destination(bundle: Bundle = .main) -> String? {
        CrashReportingPolicy.destination(info: bundle.infoDictionary, isUnitTestHost: UnitTestHost.isActive)
    }

    private static func currentEnvironment(bundle: Bundle = .main) -> String {
        CrashReportingPolicy.environment(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    /// Every option the privacy promise rests on, in one place `CrashReportingTests` checks.
    nonisolated static func configure(
        _ options: Options,
        dsn: String,
        environment: String,
        installID: String,
        bundleID: String = CrashReporter.bundleID
    ) {
        options.dsn = dsn
        options.environment = environment
        options.cacheDirectoryPath = CrashReportingPolicy.cacheDirectory(caches: options.cacheDirectoryPath, bundleID: bundleID)
        // Keybumps' own identifier on every report. Sentry still keeps an `INSTALLATION` file of its
        // own in the folder, but never sends it: the user is set here and again in `beforeSend`.
        options.initialScope = { scope in
            scope.setUser(User(userId: installID))
            return scope
        }
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
        options.beforeSend = { event in
            let scrubbed = CrashReportScrubber.scrub(event)
            scrubbed.user = User(userId: installID)
            return scrubbed
        }
    }

    /// Sentry running only to send problem reports, with reports off: no crash handler, no freeze
    /// tracking, and its own queue.
    nonisolated static func configureSendingOnly(
        _ options: Options,
        dsn: String,
        environment: String,
        installID: String,
        bundleID: String = CrashReporter.bundleID
    ) {
        configure(options, dsn: dsn, environment: environment, installID: installID, bundleID: bundleID)
        options.enableCrashHandler = false
        options.enableAppHangTracking = false
        options.cacheDirectoryPath = CrashReportingPolicy.sendOnlyDirectory(in: options.cacheDirectoryPath)
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
