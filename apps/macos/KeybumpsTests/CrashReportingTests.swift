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
        let caches = options.cacheDirectoryPath
        CrashReporter.configure(options, dsn: dsn, environment: "qa", installID: "install-id", bundleID: "com.serp.keybumps")
        #expect(options.environment == "qa")
        // Keybumps' own folder and identifier, never the Caches folder every unsandboxed app shares.
        #expect(options.cacheDirectoryPath == caches + "/com.serp.keybumps/Sentry")
        let user = options.initialScope(Scope()).serialize()["user"] as? [String: Any]
        #expect(user?["id"] as? String == "install-id")
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
        // Keybumps' ID even on an event that reached Sentry with no user, so Sentry's own never goes.
        #expect(beforeSend(Event())?.user?.userId == "install-id")
        let beforeBreadcrumb = try #require(options.beforeBreadcrumb)
        #expect(beforeBreadcrumb(Breadcrumb(level: .info, category: "ui.click")) == nil)
    }

    @Test func sendingOnlyHasNoCrashHandlerAndItsOwnQueue() {
        let options = Options()
        let caches = options.cacheDirectoryPath
        CrashReporter.configureSendingOnly(options, dsn: dsn, environment: "qa", installID: "install-id", bundleID: "com.serp.keybumps")
        #expect(!options.enableCrashHandler)
        #expect(!options.enableAppHangTracking)
        #expect(options.cacheDirectoryPath == caches + "/com.serp.keybumps/Sentry/Problem reports")
        // Every other option is the same as for crash reports.
        #expect(!options.sendDefaultPii)
        #expect(!options.enableAutoSessionTracking)
        #expect(!options.enableAutoBreadcrumbTracking)
        #expect(options.beforeSend != nil)
        let user = options.initialScope(Scope()).serialize()["user"] as? [String: Any]
        #expect(user?["id"] as? String == "install-id")
    }

    @Test func theInstallIDIsCreatedOnceAndKept() {
        let defaults = InMemoryDefaults()
        let id = CrashReportingPolicy.installID(defaults: defaults)
        #expect(UUID(uuidString: id) != nil)
        #expect(CrashReportingPolicy.installID(defaults: defaults) == id)

        defaults.set("not a uuid", forKey: CrashReportingPolicy.installIDKey)
        #expect(CrashReportingPolicy.installID(defaults: defaults) != "not a uuid")
    }

    @Test func queuedReportsMoveToTheSamePlaceInAnotherFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Problem reports")
        let target = root.appendingPathComponent("Sentry")
        let queued = source.appendingPathComponent("io.sentry/abc123/envelopes")
        try FileManager.default.createDirectory(at: queued, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: queued.appendingPathComponent("1.envelope"))

        CrashReportingPolicy.moveQueuedReports(from: source.path, to: target.path)
        #expect(!CrashReportingPolicy.hasQueuedReports(in: source.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("io.sentry/abc123/envelopes/1.envelope").path))
    }

    @Test func emailAddressesInAnyScriptAreFound() {
        #expect(CrashReportScrubber.scrub("Write to o'brien@example.com or josé@example.es") == "Write to <email> or <email>")
        #expect(ProblemReport(description: "x", contactEmail: "josé@example.es", diagnostics: ProblemReportTests.sample).contact == "josé@example.es")
        #expect(ProblemReport(description: "x", contactEmail: "o'brien@example.com", diagnostics: ProblemReportTests.sample).canSend)
        // Scripts whose vowels are combining marks, and an accent pasted as a separate mark.
        #expect(CrashReportScrubber.scrub("राम@उदाहरण.भारत") == "<email>")
        #expect(CrashReportScrubber.scrub("jose\u{0301}@example.es") == "<email>")
    }

    @Test func urlsAndAddressesGluedToOtherTextAreStillFound() {
        #expect(CrashReportScrubber.scrub("Error 404https://example.com/x") == "Error 404<url>")
        #expect(CrashReportScrubber.scrub("1.https://example.com") == "1.<url>")
        #expect(CrashReportScrubber.scrub("-https://example.org") == "-<url>")
        #expect(CrashReportScrubber.scrub("(https://example.com)") == "(<url>")
        #expect(CrashReportScrubber.scrub("pat@example.com-jo@example.org") == "<email><email>")
    }

    @Test func longTextWithoutAnAddressScrubsQuickly() {
        let token = String(repeating: "a", count: 50_000)
        let paragraph = String(repeating: "漢", count: 50_000)
        let start = ContinuousClock.now
        #expect(CrashReportScrubber.scrubWritten(token) == token)
        #expect(CrashReportScrubber.scrubWritten(paragraph) == paragraph)
        // It runs on the main thread when Send is pressed; the old pattern took seconds here.
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aQueuedReportIsFoundInSentrysEnvelopesFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let envelopes = folder.appendingPathComponent("io.sentry/abc123/envelopes")
        try FileManager.default.createDirectory(at: envelopes, withIntermediateDirectories: true)
        #expect(!CrashReportingPolicy.hasQueuedReports(in: folder.path))

        try Data("{}".utf8).write(to: envelopes.appendingPathComponent("1.envelope"))
        #expect(CrashReportingPolicy.hasQueuedReports(in: folder.path))
        #expect(!CrashReportingPolicy.hasQueuedReports(in: folder.appendingPathComponent("missing").path))
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
        #expect(scrub("missing \"/Volumes/Backup/photo.png\" here") == "missing “<name>” here")
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
        // Slovenian, Traditional Chinese, Hebrew, and Arabic.
        #expect(scrub("Datoteka »Q3 plan.txt« manjka") == "Datoteka “<name>” manjka")
        #expect(scrub("檔案「Q3 plan.txt」無法打開") == "檔案“<name>”無法打開")
        #expect(scrub("הקובץ ״Q3 plan.txt״ חסר") == "הקובץ “<name>” חסר")
        #expect(scrub("الملف \"Q3 plan.txt\" مفقود") == "الملف “<name>” مفقود")
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

@MainActor
struct ProblemReportTests {
    static let sample = ProblemReportDiagnostics(
        appVersion: "Keybumps 0.0.3 (4022)",
        macOSVersion: "15.1 (Build 24B83)",
        macModel: "Mac15,9",
        chip: "Apple M3 Max",
        memoryGB: 128,
        pluginsOn: [],
        permissions: [],
        sendsCrashReports: true
    )
    private let diagnostics = ProblemReportDiagnostics(
        appVersion: "Keybumps 0.0.3 (4022)",
        macOSVersion: "15.1 (Build 24B83)",
        macModel: "Mac15,9",
        chip: "Apple M3 Max",
        memoryGB: 128,
        pluginsOn: ["Dictation", "Timer"],
        permissions: [("Accessibility", "Granted"), ("Microphone", "Denied")],
        sendsCrashReports: false
    )

    @Test func thePersonSeesEveryDetailThatIsAttached() {
        #expect(diagnostics.lines == [
            "Keybumps 0.0.3 (4022)",
            "macOS 15.1 (Build 24B83)",
            "Mac15,9 · Apple M3 Max · 128 GB",
            "Plugins on: Dictation, Timer",
            "Permissions: Accessibility granted, Microphone denied",
            "Crash reports: off",
        ])
    }

    @Test func aReportNeedsADescription() {
        #expect(!ProblemReport(description: "  \n", contactEmail: "", diagnostics: diagnostics).canSend)
        #expect(ProblemReport(description: "Dropdowns don't open", contactEmail: "", diagnostics: diagnostics).canSend)
    }

    @Test func aReportIsAnEventThatKeepsTheContactOnlyWhenGiven() throws {
        let event = ProblemReport(description: " Dropdowns don't open \n", contactEmail: " pat@example.com ", diagnostics: diagnostics).event()
        #expect(event.level == .info)
        #expect(event.message?.formatted == "Dropdowns don't open")
        #expect(event.tags == ["report": "problem"])
        #expect(event.context?["report"]?["contact"] as? String == "pat@example.com")
        #expect(event.context?["report"]?["crash_reports"] as? String == "off")
        #expect(event.context?["permissions"]?["Microphone"] as? String == "Denied")
        // Everything the window showed, chip and memory included, which Sentry doesn't send itself.
        #expect(event.context?["report"]?["details"] as? [String] == diagnostics.lines)

        let anonymous = ProblemReport(description: "x", contactEmail: "", diagnostics: diagnostics).event()
        #expect(anonymous.context?["report"]?["contact"] == nil)
    }

    @Test func aReportIsScrubbedButKeepsItsContactAndPermissions() {
        let event = ProblemReport(
            description: "Opening https://example.com/x fails\nSo does /Users/pat/Q3 plan.txt",
            contactEmail: "pat@example.com",
            diagnostics: diagnostics
        ).event()
        let scrubbed = CrashReportScrubber.scrub(event)
        // A link or path runs to the end of its line.
        #expect(scrubbed.message?.formatted == "Opening <url>\nSo does <path>")
        #expect(scrubbed.context?["report"]?["contact"] as? String == "pat@example.com")
        #expect(scrubbed.context?["permissions"]?["Accessibility"] as? String == "Granted")
    }

    @Test func quotedWordsInAReportStayButQuotedNamesInACrashGo() {
        let written = "The “Language” menu doesn't open in /Users/pat/Notes"
        let report = ProblemReport(description: written, contactEmail: "", diagnostics: diagnostics).event()
        #expect(CrashReportScrubber.scrub(report).message?.formatted == "The “Language” menu doesn't open in <path>")

        let crash = Event(level: .error)
        crash.message = SentryMessage(formatted: written)
        #expect(CrashReportScrubber.scrub(crash).message?.formatted == "The “<name>” menu doesn't open in <path>")
    }

    @Test func onlyAnEmailAddressIsKeptAsTheContact() {
        let pasted = ProblemReport(description: "x", contactEmail: "see https://example.com/x", diagnostics: diagnostics)
        #expect(pasted.contact == nil)
        #expect(!pasted.contactIsValid)
        #expect(!pasted.canSend)
        #expect(pasted.event().context?["report"]?["contact"] == nil)

        #expect(ProblemReport(description: "x", contactEmail: "  ", diagnostics: diagnostics).canSend)
        #expect(ProblemReport(description: "x", contactEmail: " pat@example.com ", diagnostics: diagnostics).contact == "pat@example.com")
    }

    @Test func aBuildWithNoDestinationCantSendReports() {
        #expect(!CrashReporter.canSendProblemReports)
        #expect(!CrashReporter.send(ProblemReport(description: "x", contactEmail: "", diagnostics: diagnostics), plugins: []))
    }
}

/// Every order of events CrashReporter can see, without Sentry.
struct CrashReporterMachineTests {
    @Test func aReportSentWithReportsOffStartsSentryJustToSendIt() {
        var machine = CrashReporterMachine()
        #expect(machine.send() == [.startSendingOnly, .capture, .flush])
        #expect(machine.mode == .sendingOnly)
        #expect(machine.flushed() == [.close])
        #expect(machine.mode == .off)
    }

    @Test func turningReportsOnDuringASendWaitsForItToFinish() {
        var machine = CrashReporterMachine()
        _ = machine.send()
        #expect(machine.turnOn() == [])
        #expect(machine.flushed() == [.close, .startReporting])
        #expect(machine.mode == .reporting)
    }

    @Test func turningReportsOnThenOffDuringASendNeverStartsThem() {
        var machine = CrashReporterMachine()
        _ = machine.send()
        _ = machine.turnOn()
        #expect(machine.turnOff() == [])
        #expect(machine.flushed() == [.close])
        #expect(machine.mode == .off)
    }

    @Test func twoReportsInFlightCloseSentryOnceAfterTheLast() {
        var machine = CrashReporterMachine()
        _ = machine.send()
        #expect(machine.send() == [.capture, .flush])
        #expect(machine.flushed() == [])
        #expect(machine.flushed() == [.close])
    }

    @Test func aReportSentWithReportsOnNeverClosesSentry() {
        var machine = CrashReporterMachine()
        #expect(machine.turnOn() == [.startReporting])
        #expect(machine.send() == [.capture])
        #expect(machine.mode == .reporting)
        #expect(machine.turnOff() == [.close])
    }

    @Test func anUndeliveredReportGoesAtLaunchBeforeReportingStarts() {
        var machine = CrashReporterMachine()
        #expect(machine.drain() == [.startSendingOnly, .flush])
        #expect(machine.turnOn() == [])
        #expect(machine.flushed() == [.close, .startReporting])
    }

    @Test func turningReportsOffWhenTheyAreOffDoesNothing() {
        var machine = CrashReporterMachine()
        #expect(machine.turnOff() == [])
        #expect(machine.mode == .off)
    }
}
