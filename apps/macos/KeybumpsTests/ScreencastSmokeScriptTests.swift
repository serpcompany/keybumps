import Foundation
import Testing
@testable import Keybumps

/// `apps/macos/scripts/smoke-screencast.sh` (#470), run under /bin/zsh as the orchestrator runs
/// it, against a fake installed app in a folder of the test's own. `open` and the AppleScript
/// runner are stand-ins on `PATH` that log their arguments, and the smoke run is a process named as the
/// fake app's executable that waits, then writes a result. Nothing here opens Keybumps, Finder, or
/// a window, or quits anything but the test's own processes.
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

    @Test("A run quits Keybumps, opens Finder on the QA folder and the smoke run, reads its result, then cleans up and reopens Keybumps")
    func passes() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let running = try bench.startRunningKeybumps()
        try FileManager.default.createDirectory(at: bench.captures, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: bench.captures.appendingPathComponent("video-1.mov"))
        var report = ScreencastSmokeReport(macOS: "15.6.1", displayCount: 1, modes: ScreencastSmokeMode.allCases)
        report.complete = true
        report.passed = true
        report.cleanedUp = true
        let result = bench.root.appendingPathComponent("passed.json")
        try report.write(to: result)

        let run = try bench.run([], result: result, runFor: 1)

        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("\"passed\" : true") && run.output.contains("screencast smoke test: exit 0\n"), "\(run.output)")
        #expect(kill(running, 0) != 0, "the running Keybumps was quit")
        #expect(bench.calls == [
            "\(SmokeScriptBench.appleScript) -e tell application id \"\(SmokeScriptBench.bundleID)\" to quit",
            "\(SmokeScriptBench.appleScript) - \(bench.qaFolderForFinder) count",
            "open \(bench.qaFolder.path)",
            "open -n \(bench.app.path) --args -\(ScreencastSmokeTest.launchOption) YES",
            "\(SmokeScriptBench.appleScript) - \(bench.qaFolderForFinder) close",
            "open \(bench.app.path)",
        ], "\(run.output)")
        #expect(!bench.smokeLeftovers, "a leftover captures folder is deleted before the smoke run opens")
        #expect(!FileManager.default.fileExists(atPath: bench.captures.path))
        #expect(bench.smokePID.map { kill($0, 0) != 0 } == true)
    }

    @Test("A run that doesn't finish in time is stopped by its PID, exits 3, and still cleans up and reopens Keybumps")
    func timesOut() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run(["--timeout", "1"], result: nil, runFor: 30)

        #expect(run.status == 3, "\(run.output)")
        #expect(run.output.contains("didn't finish in 1s") && run.output.contains("screencast smoke test: exit 3\n"), "\(run.output)")
        let pid = try #require(bench.smokePID)
        #expect(kill(pid, 0) != 0, "the smoke run was stopped")
        #expect(!FileManager.default.fileExists(atPath: bench.captures.path))
        #expect(bench.calls.suffix(2) == ["\(SmokeScriptBench.appleScript) - \(bench.qaFolderForFinder) close", "open \(bench.app.path)"])
    }

    @Test("Ctrl-C stops the smoke run, deletes what it saved, closes the Finder window, reopens Keybumps, and exits 130")
    func interrupted() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let process = try bench.start([], result: nil, runFor: 30)
        let started = Date()
        while Date().timeIntervalSince(started) < 10 {
            if let pid = bench.smokePID, kill(pid, 0) == 0, FileManager.default.fileExists(atPath: bench.captures.path) { break }
            usleep(50_000)
        }
        let pid = try #require(bench.smokePID)
        #expect(FileManager.default.fileExists(atPath: bench.captures.path), "the smoke run saved something")
        usleep(300_000)
        process.interrupt()
        process.waitUntilExit()

        #expect(process.terminationStatus == 130)
        #expect(kill(pid, 0) != 0, "the smoke run was stopped")
        #expect(!FileManager.default.fileExists(atPath: bench.captures.path), "its captures were deleted")
        #expect(bench.calls.suffix(2) == ["\(SmokeScriptBench.appleScript) - \(bench.qaFolderForFinder) close", "open \(bench.app.path)"])
    }

    @Test("A smoke run that can't be opened exits 69, not a capture's 1, and Keybumps is reopened")
    func openFails() throws {
        let bench = try SmokeScriptBench()
        defer { bench.remove() }
        let run = try bench.run([], result: nil, runFor: 1, extra: ["FAKE_OPEN_FAILS": "1"])

        #expect(run.status == 69, "\(run.output)")
        #expect(run.output.contains("couldn't open Keybumps"), "\(run.output)")
        #expect(bench.calls.last == "open \(bench.app.path)")
    }

    @Test("An installed app that isn't a QA candidate exits 67 and nothing is quit or opened")
    func refusesARelease() throws {
        let bench = try SmokeScriptBench(version: "0.0.3-beta.25")
        defer { bench.remove() }
        let run = try bench.run([], result: nil, runFor: 1)

        #expect(run.status == 67, "\(run.output)")
        #expect(bench.calls.isEmpty)
    }

    @Test("The script names the option and folders the app uses, and never kills by name")
    func matchesApp() throws {
        let text = try String(contentsOf: SmokeScriptBench.script, encoding: .utf8)
        #expect(text.contains("option=\(ScreencastSmokeTest.launchOption)\n"))
        #expect(text.contains("== \(ScreencastSmokeFailure.permissionDenied.rawValue) ]]"))
        #expect(text.contains("\"\(ScreencastFailure.screenRecordingDenied.rawValue)\""))
        #expect(text.contains("/\(ScreencastSmokeTest.capturesFolderName)\""))
        #expect(!text.contains("pkill") && !text.contains("killall"))
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
    var qaFolder: URL { home.appendingPathComponent("Library/Developer/Keybumps-QA") }
    /// The QA folder as the script hands it to Finder: symbolic links resolved, with a slash.
    var qaFolderForFinder: String {
        let resolved = realpath(qaFolder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return (resolved ?? qaFolder.path) + "/"
    }
    var temporary: URL { root.appendingPathComponent("T") }
    var captures: URL { temporary.appendingPathComponent(ScreencastSmokeTest.capturesFolderName) }
    private var bin: URL { root.appendingPathComponent("bin") }
    private var log: URL { root.appendingPathComponent("calls.log") }
    private var pidFile: URL { root.appendingPathComponent("smoke.pid") }
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

        // `open -n <app> --args …` starts the smoke run: a process named as the app's executable
        // that saves a capture, waits, then writes the result it was given (if any).
        try install("open", """
        #!/bin/zsh
        print -r -- "open $*" >> "$FAKE_LOG"
        if [[ "$1" == -n ]]; then
          [[ -z "${FAKE_OPEN_FAILS:-}" ]] || exit 1
          [[ ! -e "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)" ]] || print leftovers > "$FAKE_LEFTOVERS"
          mkdir -p "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)"
          print movie > "$KEYBUMPS_SMOKE_TEMPORARY/\(ScreencastSmokeTest.capturesFolderName)/video-1.mov"
          ( exec -a "$2/Contents/MacOS/Keybumps" /bin/zsh -c 'zmodload zsh/zselect; zselect -t $1; [[ -z "$2" ]] || cp "$2" "$3"' \\
              smoke "$FAKE_RUN_HUNDREDTHS" "${FAKE_RESULT:-}" "$FAKE_RESULT_DESTINATION" ) </dev/null >/dev/null 2>&1 &!
          print -r -- $! > "$FAKE_SMOKE_PID"
        fi
        """)
        // Asked about Finder's windows on the QA folder, there are none; asked to quit Keybumps,
        // it stops the test's stand-in.
        try install(Self.appleScript, """
        #!/bin/zsh
        print -r -- "\(Self.appleScript) $*" >> "$FAKE_LOG"
        if [[ "$1" == - ]]; then cat >/dev/null; print 0; exit 0; fi
        if [[ "$*" == *" to quit" && -f "$FAKE_RUNNING_PID" ]]; then kill "$(<"$FAKE_RUNNING_PID")" 2>/dev/null || true; fi
        """)
    }

    private func install(_ name: String, _ text: String) throws {
        let url = bin.appendingPathComponent(name)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Stops whatever still runs from the fake app (found by its executable, never by name), and
    /// deletes the folder.
    func remove() {
        let found = try? Self.runProcess(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", "^\(executable.path)"], environment: [:])
        for pid in (found?.output ?? "").split(separator: "\n").compactMap({ pid_t($0) }) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The stand-ins' calls, in order.
    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The smoke run the fake `open` started.
    var smokePID: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
