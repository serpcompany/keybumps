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

    @Test func theUnitTestHostNeverStartsReporting() {
        CrashReporter.setEnabled(true)
        #expect(!CrashReporter.isRunning)
    }

    @Test func eachBuildReportsToItsOwnEnvironment() {
        let production = "https://updates.keybumps.app/appcast.xml"
        let staging = "https://updates.keybumps.app/staging/appcast.xml"
        #expect(CrashReportingPolicy.environment(version: "0.0.3-beta.16", feedURL: production) == "production")
        #expect(CrashReportingPolicy.environment(version: "0.0.3-beta.16", feedURL: staging) == "staging")
        #expect(CrashReportingPolicy.environment(version: "0.0.3-dev.issue258", feedURL: production) == "qa")
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
        #expect(scrub("missing '/Volumes/Backup/photo.png' here") == "missing '<path>' here")
        #expect(scrub("saved to ~/Desktop/notes.md") == "saved to <path>")
        #expect(scrub("loading https://example.com/a?q=secret failed") == "loading <url> failed")
        #expect(scrub("file:///Users/pat/a.txt") == "<url>")
        #expect(scrub("sent by pat.lee@example.com today") == "sent by <email> today")
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
        event.context = ["os": ["name": "macOS"], "culture": ["timezone": "Asia/Tokyo"], "plugins": ["on": ["timer"]]]

        let scrubbed = CrashReportScrubber.scrub(event)

        #expect(scrubbed.serverName == nil)
        #expect(scrubbed.extra == nil)
        #expect(scrubbed.user?.userId == "install-id")
        #expect(scrubbed.user?.email == nil)
        #expect(scrubbed.message?.formatted == "opening <path>")
        let scrubbedException = try #require(scrubbed.exceptions?.first)
        #expect(scrubbedException.value == "bad URL <url>")
        #expect(scrubbedException.type == "NSInvalidArgumentException")
        #expect(scrubbedException.stacktrace?.frames.first?.package == "<path>")
        #expect(scrubbedException.stacktrace?.frames.first?.contextLine == nil)
        #expect(scrubbed.debugMeta?.first?.codeFile == "<path>")
        #expect(scrubbed.breadcrumbs?.map(\.category) == ["keybumps.dictation"])
        #expect(Set(scrubbed.context.map { Array($0.keys) } ?? []) == ["os", "plugins"])
    }
}
