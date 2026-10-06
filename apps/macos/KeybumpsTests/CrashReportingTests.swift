import Foundation
import Sentry
import Testing
@testable import Keybumps

@MainActor
struct CrashReportingTests {
    private let dsn = "https://key@o1.ingest.us.sentry.io/2"

    @Test func onlyABuildWithADestinationReports() {
        #expect(CrashReportingPolicy.destination(info: ["KBCrashReportsDSN": dsn], isUnitTestHost: false) == dsn)
        // Debug builds carry an empty setting.
        #expect(CrashReportingPolicy.destination(info: ["KBCrashReportsDSN": ""], isUnitTestHost: false) == nil)
        #expect(CrashReportingPolicy.destination(info: [:], isUnitTestHost: false) == nil)
        #expect(CrashReportingPolicy.destination(info: ["KBCrashReportsDSN": dsn], isUnitTestHost: true) == nil)
    }

    @Test func reportingIsConfiguredForCrashesAndFreezesOnly() throws {
        let options = Options()
        CrashReporter.configure(options, dsn: dsn, environment: "qa")
        #expect(options.environment == "qa")
        #expect(!options.sendDefaultPii)
        #expect(!options.enableAutoSessionTracking)
        #expect(options.shutdownTimeInterval == 0)
        #expect(!options.enableAutoBreadcrumbTracking)
        #expect(!options.enableNetworkBreadcrumbs)
        #expect(!options.enableNetworkTracking)
        #expect(!options.enableCaptureFailedRequests)
        #expect(!options.enableAutoPerformanceTracing)
        #expect(!options.enableFileIOTracing)
        #expect(!options.enableCoreDataTracing)
        #expect(options.tracesSampleRate == nil)
        #expect(options.enableCrashHandler)
        #expect(options.enableAppHangTracking)
        #expect(!options.enableUncaughtNSExceptionReporting)
        #expect(!options.enableMetricKit)
        #expect(!options.enableLogs)

        let beforeSend = try #require(options.beforeSend)
        let event = Event()
        event.serverName = "Pat's MacBook Pro"
        #expect(beforeSend(event)?.serverName == nil)
        let beforeBreadcrumb = try #require(options.beforeBreadcrumb)
        #expect(beforeBreadcrumb(Breadcrumb(level: .info, category: "ui.click")) == nil)
    }

    @Test func qaCandidatesReportApartFromReleases() {
        #expect(CrashReportingPolicy.environment(version: "0.0.3-beta.16") == "production")
        #expect(CrashReportingPolicy.environment(version: "0.0.3-dev.issue258") == "qa")
    }

    @Test func crashReportsAreOnUntilTurnedOff() {
        let defaults = InMemoryDefaults()
        #expect(AppPreferences.sendsCrashReports(in: defaults))
        #expect(AppPreferences(defaults: defaults).sendsCrashReports)

        AppPreferences(defaults: defaults).sendsCrashReports = false
        #expect(!AppPreferences.sendsCrashReports(in: defaults))
        #expect(!AppPreferences(defaults: defaults).sendsCrashReports)
        #expect(defaults.leakedDomain == nil)
    }

    @Test func scrubbingRemovesPathsURLsAndEmails() {
        let scrub = CrashReportScrubber.scrub as (String) -> String
        #expect(scrub("can't open /Users/pat/Documents/Q3 plan.txt") == "can't open <path>")
        #expect(scrub("can't open /Users/pat/Documents/Pat's Q3 plan.txt") == "can't open <path>")
        #expect(scrub("missing \"/Volumes/Backup/photo.png\" here") == "missing \"<path>\" here")
        #expect(scrub("saved to ~/Desktop/notes.md") == "saved to <path>")
        #expect(scrub("loading https://example.com/a?q=secret") == "loading <url>")
        #expect(scrub("smb://server/share/Pat Q3.txt") == "<url>")
        #expect(scrub("file:///Users/pat/a.txt") == "<url>")
        #expect(scrub("sent by pat.lee@example.com today") == "sent by <email> today")
        // Cocoa quotes file names with curly quotes.
        #expect(scrub("The file “Q3 plan.txt” couldn’t be opened") == "The file “<name>” couldn’t be opened")
        #expect(scrub("“/Users/pat/Pat’s notes.txt” is locked") == "“<name>” is locked")
        #expect(scrub("wrote /private/var/folders/x1/T/draft.txt") == "wrote <path>")
        #expect(scrub("wrote /tmp/draft.txt") == "wrote <path>")
        // Cocoa's quotes in German, Polish, Swedish, and French.
        #expect(scrub("Die Datei „Q3 plan.txt“ fehlt") == "Die Datei “<name>” fehlt")
        #expect(scrub("Plik „Q3 plan.txt” jest") == "Plik “<name>” jest")
        #expect(scrub("Filen ”Q3 plan.txt” saknas") == "Filen “<name>” saknas")
        #expect(scrub("Le fichier « Q3 plan.txt » manque") == "Le fichier “<name>” manque")
    }

    @Test func onlyQACandidatesCanCrashOnPurpose() {
        #expect(CrashReportTest.isAllowed(version: "0.0.3-dev.issue258"))
        #expect(!CrashReportTest.isAllowed(version: "0.0.3-beta.16"))
    }

    @Test func aBinaryInAHomeFolderKeepsItsName() {
        #expect(CrashReportScrubber.scrubImagePath("/Users/pat/Downloads/Keybumps.app/Contents/MacOS/Keybumps") == "<path>/Keybumps")
        #expect(CrashReportScrubber.scrubImagePath("/Applications/Keybumps.app/Contents/MacOS/Keybumps") == "/Applications/Keybumps.app/Contents/MacOS/Keybumps")
    }

    @Test func scrubbingKeepsWhatDiagnosesACrash() {
        let scrub = CrashReportScrubber.scrub as (String) -> String
        for text in [
            "Fatal error: Index out of range",
            "/Applications/Keybumps.app/Contents/MacOS/Keybumps",
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds [0 .. 2]",
        ] {
            #expect(scrub(text) == text)
        }
    }

    @Test func aScrubbedEventKeepsOnlyWhatThePolicyAllows() throws {
        let event = Event()
        event.serverName = "Pat's MacBook Pro"
        event.extra = ["clipboard": "secret"]
        event.user = User(userId: "install-id")
        event.user?.email = "pat@example.com"
        event.message = SentryMessage(formatted: "opening /Users/pat/secret.txt")
        let exception = Exception(value: "bad URL https://example.com/private", type: "NSInvalidArgumentException")
        let frame = Frame()
        frame.package = "/Users/pat/Downloads/Keybumps.app/Contents/MacOS/Keybumps"
        frame.contextLine = "let password = \"hunter2\""
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]
        let meta = DebugMeta()
        meta.codeFile = "/Users/pat/Downloads/Keybumps.app/Contents/MacOS/Keybumps"
        event.debugMeta = [meta]
        event.breadcrumbs = [
            Breadcrumb(level: .info, category: "ui.click"),
            Breadcrumb(level: .info, category: "keybumps.dictation"),
        ]
        exception.mechanism = Mechanism(type: "nsexception")
        exception.mechanism?.data = ["crash_info_messages": ["can't read /Users/pat/notes.txt"]]
        event.context = [
            "os": ["name": "macOS"],
            "app": ["app_version": "1.0", "device_app_hash": "abc123"],
            "device": ["model": "Mac15,3", "locale": "ja_JP"],
            "culture": ["timezone": "Asia/Tokyo"],
            "plugins": ["on": ["timer"]],
        ]

        let scrubbed = CrashReportScrubber.scrub(event)

        #expect(scrubbed.serverName == nil)
        #expect(scrubbed.extra == nil)
        #expect(scrubbed.user?.userId == "install-id")
        #expect(scrubbed.user?.email == nil)
        #expect(scrubbed.message?.formatted == "opening <path>")
        let scrubbedException = try #require(scrubbed.exceptions?.first)
        #expect(scrubbedException.value == "bad URL <url>")
        #expect(scrubbedException.type == "NSInvalidArgumentException")
        #expect(scrubbedException.stacktrace?.frames.first?.package == "<path>/Keybumps")
        #expect(scrubbedException.mechanism?.data?["crash_info_messages"] as? [String] == ["can't read <path>"])
        #expect(scrubbedException.stacktrace?.frames.first?.contextLine == nil)
        #expect(scrubbed.debugMeta?.first?.codeFile == "<path>/Keybumps")
        #expect(scrubbed.breadcrumbs?.map(\.category) == ["keybumps.dictation"])
        #expect(Set(scrubbed.context.map { Array($0.keys) } ?? []) == ["os", "app", "device", "plugins"])
        #expect(scrubbed.context?["app"]?["device_app_hash"] == nil)
        #expect(scrubbed.context?["app"]?["app_version"] as? String == "1.0")
        #expect(scrubbed.context?["device"]?["locale"] == nil)
        #expect(scrubbed.context?["device"]?["model"] as? String == "Mac15,3")
    }
}
