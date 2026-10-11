import Foundation
import Testing
@testable import Keybumps

/// `apps/macos/scripts/smoke-screencast.sh` (#470), run under /bin/zsh as the orchestrator runs
/// it, against a fake installed app in a folder of the test's own. `open` and the AppleScript
/// runner are stand-ins on `PATH` that log their arguments: the smoke run is a process named as
/// the fake app's executable that waits, then writes a result, and the window helper is a process
/// that says it's ready and waits. Nothing here opens Keybumps or a window, or quits anything but
/// the test's own processes.
@Suite("Screencast: the QA smoke script")
struct ScreencastSmokeScriptTests {
    // MARK: The result's exit code

    @Test("A result gives exit 0 passed, 1 a capture failed, 2 no Screen Recording or no run, 3 incomplete or missing, as the app counts")
    func evaluate() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        func report(
            complete: Bool = true,
            passed: Bool = false,
            errorCategory: String? = nil,
            captureError: String? = nil
        ) -> ScreencastSmokeReport {
            var report = ScreencastSmokeReport(macOS: "15.6.1", displayCount: 1, modes: ScreencastSmokeMode.allCases)
            report.complete = complete
            report.passed = passed
            report.cleanedUp = complete
            report.errorCategory = errorCategory
            for index in report.captures.indices {
                report.captures[index].passed = passed
                report.captures[index].stage = passed ? .cleanedUp : .notStarted
            }
            if let captureError {
                report.captures[1].stage = .starting
                report.captures[1].errorCategory = captureError
            }
            return report
        }
        let cases: [(name: String, report: ScreencastSmokeReport, code: Int32)] = [
            ("passed", report(passed: true), 0),
            ("a capture failed", report(captureError: ScreencastFailure.captureFailed.rawValue), 1),
            ("a capture timed out", report(captureError: ScreencastSmokeFailure.timeout.rawValue), 1),
            ("permission denied", report(errorCategory: ScreencastSmokeFailure.permissionDenied.rawValue), 2),
            ("a capture refused Screen Recording", report(captureError: ScreencastFailure.screenRecordingDenied.rawValue), 2),
            ("unsupported macOS", report(errorCategory: ScreencastSmokeFailure.unsupportedMacOS.rawValue), 2),
            ("stopped mid-run (crash, hang, or timeout)", report(complete: false), 3),
        ]
        for (index, item) in cases.enumerated() {
            let file = bench.root.appendingPathComponent("result-\(index).json")
            try item.report.write(to: file)
            let run = try bench.run(["--evaluate", file.path])
            #expect(run.status == item.code, "\(item.name): \(run.output)")
            #expect(run.output.contains("screencast smoke test: exit \(item.code)\n"), "\(item.name): \(run.output)")
            if item.report.complete {
                #expect(item.report.exitCode == item.code, "the app's own code for \(item.name)")
            }
        }
        let missing = try bench.run(["--evaluate", bench.root.appendingPathComponent("missing.json").path])
        #expect(missing.status == 3 && missing.output.contains("no result"), "\(missing.output)")
        #expect(bench.calls.isEmpty, "evaluating opens and quits nothing")
    }

    // MARK: A whole run

    @Test("A run quits Keybumps, shows the helper's window, opens the smoke run with the helper's PID, reads its result, then stops the helper, cleans up, and reopens Keybumps")
    func passes() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let running = try bench.startRunningKeybumps()
        try FileManager.default.createDirectory(at: bench.captures, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: bench.captures.appendingPathComponent("video-1.mov"))
        let result = try bench.result(passed: true)

        let run = try bench.run([], result: result, runFor: 1)

        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("\"passed\" : true") && run.output.contains("screencast smoke test: exit 0\n"), "\(run.output)")
        #expect(kill(running, 0) != 0, "the running Keybumps was quit")
        let helper = try #require(bench.helperPID)
        let script = try #require(bench.helperParent)
        // The helper's lifetime (the start wait, the time limit, and two minutes), and the PID of
        // the script, its parent, which it watches.
        #expect(bench.calls == [
            "\(SmokeScriptBench.appleScript) -e tell application id \"\(SmokeScriptBench.bundleID)\" to quit",
            "\(SmokeScriptBench.appleScript) -l JavaScript - \(30 + 180 + 120) \(script)",
            "open -n \(bench.app.path) --args -\(ScreencastSmokeTest.launchOption) YES -\(ScreencastSmokeTest.windowProcessOption) \(helper)",
            "open \(bench.app.path)",
        ], "\(run.output)")
        #expect(bench.helperAsSmokeRunOpened == helper, "the helper's window was up when the smoke run opened")
        #expect(!bench.smokeLeftovers, "a leftover captures folder is deleted before the smoke run opens")
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("A smoke run that takes a while to appear is waited for, up to 30 seconds")
    func waitsForStart() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run([], result: try bench.result(passed: true), runFor: 0.5, extra: ["FAKE_START_DELAY": "1.5"])

        #expect(run.status == 0, "\(run.output)")
        #expect(!run.output.contains("didn't start"), "\(run.output)")
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("A smoke run that appears after the start wait gave up is still found and stopped before Keybumps is reopened")
    func stopsALateStart() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run([], result: nil, runFor: 30, extra: ["KEYBUMPS_SMOKE_START_WAIT": "1", "FAKE_START_DELAY": "2.5"])

        #expect(run.status == 3, "\(run.output)")
        #expect(run.output.contains("the smoke test didn't start"), "\(run.output)")
        #expect(bench.smokePID != nil)
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("A run that doesn't finish in time is stopped by its PID, exits 3, and still cleans up and reopens Keybumps")
    func timesOut() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run(["--timeout", "1"], result: nil, runFor: 30)

        #expect(run.status == 3, "\(run.output)")
        #expect(run.output.contains("didn't finish in 1s") && run.output.contains("screencast smoke test: exit 3\n"), "\(run.output)")
        #expect(bench.smokePID != nil && bench.helperPID != nil)
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("Ctrl-C or a closed terminal stops the smoke run and the helper, deletes what it saved, reopens Keybumps, and exits 130", arguments: [SIGINT, SIGHUP])
    func stopped(by signal: Int32) throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let process = try bench.start([], result: nil, runFor: 30)
        let started = Date()
        while Date().timeIntervalSince(started) < 10 {
            if let pid = bench.smokePID, kill(pid, 0) == 0, FileManager.default.fileExists(atPath: bench.captures.path) { break }
            usleep(50_000)
        }
        let pid = try #require(bench.smokePID)
        let helper = try #require(bench.helperPID)
        #expect(kill(pid, 0) == 0 && kill(helper, 0) == 0, "the smoke run and the helper are running")
        #expect(FileManager.default.fileExists(atPath: bench.captures.path), "the smoke run saved something")
        usleep(300_000)
        kill(process.processIdentifier, signal)
        process.waitUntilExit()

        #expect(process.terminationStatus == 130)
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("A smoke run that can't be opened exits 69, not a capture's 1, and the helper is stopped and Keybumps reopened")
    func openFails() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run([], result: nil, runFor: 1, extra: ["FAKE_OPEN_FAILS": "1"])

        #expect(run.status == 69, "\(run.output)")
        #expect(run.output.contains("couldn't open Keybumps"), "\(run.output)")
        #expect(bench.helperPID != nil)
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("A helper that can't show its window: the smoke run gets no window PID, so its window capture fails, and everything is still cleaned up")
    func helperFails() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        // What the app reports with no window PID: the window capture fails as noSmokeWindow.
        var report = ScreencastSmokeReport(macOS: "15.6.1", displayCount: 1, modes: ScreencastSmokeMode.allCases)
        report.complete = true
        report.cleanedUp = true
        for index in report.captures.indices {
            let window = report.captures[index].mode.target == .window
            report.captures[index].passed = !window
            report.captures[index].stage = window ? .opening : .cleanedUp
            report.captures[index].errorCategory = window ? ScreencastSmokeFailure.noSmokeWindow.rawValue : nil
        }
        let result = bench.root.appendingPathComponent("no-window.json")
        try report.write(to: result)

        let run = try bench.run([], result: result, runFor: 0.5, extra: ["FAKE_HELPER_FAILS": "1"])

        #expect(run.status == 1 && report.exitCode == 1, "\(run.output)")
        #expect(run.output.contains("couldn't show the smoke test's window"), "\(run.output)")
        #expect(bench.calls.contains("open -n \(bench.app.path) --args -\(ScreencastSmokeTest.launchOption) YES"), "no window PID: \(bench.calls)")
        bench.expectAllStoppedAndCleanedUp()
    }

    @Test("An installed app that isn't a QA candidate exits 67 and nothing is quit or opened")
    func refusesARelease() throws {
        let bench = try SmokeScriptBench(version: "0.0.3-beta.25")
        defer { bench.remove() }
        let run = try bench.run([], result: nil, runFor: 1)

        #expect(run.status == 67, "\(run.output)")
        #expect(bench.calls.isEmpty)
    }

    @Test("The script names the options and folders the app uses, sends no Apple event but Keybumps's quit, and never kills by name")
    func matchesApp() throws {
        let text = try String(contentsOf: SmokeScriptBench.script, encoding: .utf8)
        #expect(text.contains("option=\(ScreencastSmokeTest.launchOption)\n"))
        #expect(text.contains("window_option=\(ScreencastSmokeTest.windowProcessOption)\n"))
        #expect(text.contains("== \(ScreencastSmokeFailure.permissionDenied.rawValue) ]]"))
        #expect(text.contains("\"\(ScreencastFailure.screenRecordingDenied.rawValue)\""))
        #expect(text.contains("/\(ScreencastSmokeTest.capturesFolderName)\""))
        #expect(text.components(separatedBy: "tell application").count == 2, "only the quit")
        #expect(!text.contains("Finder") && !text.contains("System Events"))
        #expect(!text.contains("pkill") && !text.contains("killall"))
    }

    @Test("The helper's window joins every Space, full-screen ones included, and the helper watches the script's PID it's given from its first line")
    func helperWindow() throws {
        let text = try String(contentsOf: SmokeScriptBench.script, encoding: .utf8)
        #expect(text.contains("window.collectionBehavior = 1 | 256;"), "canJoinAllSpaces and fullScreenAuxiliary")
        #expect(text.contains(" $(( start_wait + timeout + 120 )) $$ "))
        let run = try #require(text.range(of: "function run(argv) {\n")).upperBound
        let lines = text[run...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Array(lines.prefix(3)) == [
            "const lifetime = Number(argv[0]) || 600;",
            "const script = Number(argv[1]);",
            "if ($.getppid() !== script) return;",
        ])
        #expect(text.components(separatedBy: "getppid()").count == 3, "only the first line's check and the loop's")
    }
}

/// A folder holding a fake installed Keybumps (an Info.plist only), the QA folder under a fake
/// home, a temporary folder, and stand-ins for `open` and the AppleScript runner.
private final class SmokeScriptBench {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/smoke-screencast.sh")
    static let bundleID = "com.serp.keybumps.smoke-script-test"
    /// The AppleScript runner's name, joined so the prompt scan (`PermissionPromptSourceTests`)
    /// doesn't take this stand-in for a real call.
    static let appleScript = "osa" + "script"

    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var app: URL { root.appendingPathComponent("Keybumps.app") }
    var executable: URL { app.appendingPathComponent("Contents/MacOS/Keybumps") }
    /// The window helper's process name, which only the stand-in helper has.
    var helperName: String { root.appendingPathComponent("window-helper").path }
    var temporary: URL { root.appendingPathComponent("T") }
    var captures: URL { temporary.appendingPathComponent(ScreencastSmokeTest.capturesFolderName) }
    private var bin: URL { root.appendingPathComponent("bin") }
    private var log: URL { root.appendingPathComponent("calls.log") }
    private var pidFile: URL { root.appendingPathComponent("smoke.pid") }
    private var helperPIDFile: URL { root.appendingPathComponent("helper.pid") }
    private var helperSeenFile: URL { root.appendingPathComponent("helper-seen") }
    private var helperParentFile: URL { root.appendingPathComponent("helper-parent") }
    private var leftoversFile: URL { root.appendingPathComponent("leftovers") }

    init(version: String = "0.0.3-dev.issue470") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-script-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        for folder in [home, executable.deletingLastPathComponent(), temporary, bin] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let info: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": Self.bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        // `open -n <app> --args …` starts the smoke run (after `FAKE_START_DELAY` seconds): a
        // process named as the app's executable that saves a capture, waits, then writes the
        // result it was given (if any). It notes the window PID it was given if that's running.
        try install("open", """
        #!/bin/zsh
        print -r -- "open $*" >> "$FAKE_LOG"
        if [[ "$1" == -n ]]; then
          [[ -z "${FAKE_OPEN_FAILS:-}" ]] || exit 1
          [[ ! -e "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)" ]] || print leftovers > "$FAKE_LEFTOVERS"
          mkdir -p "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)"
          print movie > "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)/video-1.mov"
          if [[ "${argv[-2]}" == -\(ScreencastSmokeTest.windowProcessOption) ]] && kill -0 "${argv[-1]}" 2>/dev/null; then
            print -r -- "${argv[-1]}" > "$FAKE_HELPER_SEEN"
          fi
          ( [[ -z "${FAKE_START_DELAY:-}" ]] || sleep "$FAKE_START_DELAY"
            exec -a "$2/Contents/MacOS/Keybumps" /bin/zsh -c 'zmodload zsh/zselect; zselect -t $1; [[ -z "$2" ]] || cp "$2" "$3"' \\
              smoke "$FAKE_RUN_HUNDREDTHS" "${FAKE_RESULT:-}" "$FAKE_RESULT_DESTINATION" ) </dev/null >/dev/null 2>&1 &!
          print -r -- $! > "$FAKE_SMOKE_PID"
        fi
        """)
        // Run with JavaScript, it's the window helper: it says it's ready and waits, or fails
        // with `FAKE_HELPER_FAILS`. Asked to quit Keybumps, it stops the test's stand-in.
        try install(Self.appleScript, """
        #!/bin/zsh
        print -r -- "\(Self.appleScript) $*" >> "$FAKE_LOG"
        if [[ "$1" == -l ]]; then
          cat >/dev/null
          print -r -- $$ > "$FAKE_HELPER_PID"
          print -r -- $PPID > "$FAKE_HELPER_PARENT"
          [[ -z "${FAKE_HELPER_FAILS:-}" ]] || exit 1
          print ready
          exec -a "$FAKE_HELPER_NAME" /bin/zsh -c 'zmodload zsh/zselect; zselect -t 3000'
        fi
        if [[ "$*" == *" to quit" && -f "$FAKE_RUNNING_PID" ]]; then kill "$(<"$FAKE_RUNNING_PID")" 2>/dev/null || true; fi
        """)
    }

    private func install(_ name: String, _ text: String) throws {
        let url = bin.appendingPathComponent(name)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Stops whatever still runs from the fake app or the stand-in helper (found by their paths in
    /// this folder, never by name), and deletes the folder.
    func remove() {
        for pattern in [executable.path, helperName] {
            let found = try? Self.runProcess(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", "^\(pattern)"], environment: [:])
            for pid in (found?.output ?? "").split(separator: "\n").compactMap({ pid_t($0) }) {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A complete result that passed or failed, to hand the smoke run.
    func result(passed: Bool) throws -> URL {
        var report = ScreencastSmokeReport(macOS: "15.6.1", displayCount: 1, modes: ScreencastSmokeMode.allCases)
        report.complete = true
        report.passed = passed
        report.cleanedUp = true
        let url = root.appendingPathComponent("result-\(passed).json")
        try report.write(to: url)
        return url
    }

    /// After the script exits: the smoke run and the helper aren't running, the captures and the
    /// script's own files are gone, and Keybumps was reopened last.
    func expectAllStoppedAndCleanedUp(sourceLocation: SourceLocation = #_sourceLocation) {
        if let smokePID { #expect(kill(smokePID, 0) != 0, "the smoke run was stopped", sourceLocation: sourceLocation) }
        if let helperPID { #expect(kill(helperPID, 0) != 0, "the helper was stopped", sourceLocation: sourceLocation) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        #expect(left.isEmpty, "left in the temporary folder: \(left)", sourceLocation: sourceLocation)
        #expect(calls.last == "open \(app.path)", "Keybumps was reopened: \(calls)", sourceLocation: sourceLocation)
    }

    /// The stand-ins' calls, in order.
    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The smoke run the fake `open` started.
    var smokePID: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The stand-in helper's PID, once it started.
    var helperPID: pid_t? {
        (try? String(contentsOf: helperPIDFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The stand-in helper's parent: the script, when it ran the helper itself.
    var helperParent: pid_t? {
        (try? String(contentsOf: helperParentFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The window PID the smoke run was opened with, if that process was running then.
    var helperAsSmokeRunOpened: pid_t? {
        (try? String(contentsOf: helperSeenFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether the smoke run found an earlier run's captures folder as it started.
    var smokeLeftovers: Bool { FileManager.default.fileExists(atPath: leftoversFile.path) }

    /// A Keybumps already running from the fake app, for the script to quit; returns its PID.
    func startRunningKeybumps() throws -> pid_t {
        let started = try Self.runProcess(URL(fileURLWithPath: "/bin/zsh"), [
            "-c", "( exec -a \"$1\" /bin/zsh -c 'zmodload zsh/zselect; zselect -t 3000' ) </dev/null >/dev/null 2>&1 &! print -r -- $!",
            "running", executable.path,
        ], environment: [:])
        let pid = try #require(pid_t(started.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        try "\(pid)".write(to: root.appendingPathComponent("running.pid"), atomically: true, encoding: .utf8)
        return pid
    }

    private func environment(result: URL?, runFor seconds: Double, extra: [String: String]) -> [String: String] {
        [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "KEYBUMPS_SMOKE_APP": app.path,
            "KEYBUMPS_SMOKE_TEMPORARY": temporary.path,
            "FAKE_LOG": log.path,
            "FAKE_SMOKE_PID": pidFile.path,
            "FAKE_HELPER_PID": helperPIDFile.path,
            "FAKE_HELPER_SEEN": helperSeenFile.path,
            "FAKE_HELPER_PARENT": helperParentFile.path,
            "FAKE_HELPER_NAME": helperName,
            "FAKE_LEFTOVERS": leftoversFile.path,
            "FAKE_RUNNING_PID": root.appendingPathComponent("running.pid").path,
            "FAKE_RESULT": result?.path ?? "",
            "FAKE_RESULT_DESTINATION": ScreencastSmokeTest.resultURL(home: home).path,
            "FAKE_RUN_HUNDREDTHS": String(Int(seconds * 100)),
        ].merging(extra) { $1 }
    }

    func run(_ arguments: [String], result: URL? = nil, runFor seconds: Double = 1, extra: [String: String] = [:]) throws -> (status: Int32, output: String) {
        try Self.runProcess(Self.script, arguments, environment: environment(result: result, runFor: seconds, extra: extra))
    }

    /// Starts the script without waiting for it; its output is discarded.
    func start(_ arguments: [String], result: URL?, runFor seconds: Double) throws -> Process {
        let process = Self.process(Self.script, arguments, environment: environment(result: result, runFor: seconds, extra: [:]))
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func process(_ executable: URL, _ arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        // Under /bin/zsh, as the orchestrator runs it, whatever its first line says.
        process.executableURL = executable == script ? URL(fileURLWithPath: "/bin/zsh") : executable
        process.arguments = executable == script ? [script.path] + arguments : arguments
        process.environment = environment.isEmpty ? ["PATH": "/usr/bin:/bin"] : environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private static func runProcess(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = process(executable, arguments, environment: environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
