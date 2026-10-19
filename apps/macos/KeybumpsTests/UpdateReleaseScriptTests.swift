import Foundation
import Testing
import XCTest
@testable import Keybumps

/// The app folder (apps/macos: the Xcode project, tests, and scripts/) sits below the repository
/// root, where CHANGELOG.md, docs/, and the rest of the repository stay (#161, docs/adr/0003).
/// Each case copies scripts/ into a throwaway Git repository, with the app folder at the root or in
/// apps/macos, and runs a real script there. The orchestrator is always stopped at its
/// output-directory guard, before anything is built or signed.
@Suite("Release scripts in an app folder")
struct ReleaseScriptAppFolderTests {
    /// The app folder of this checkout: the parent of KeybumpsTests.
    private let checkoutAppFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    /// A throwaway Git repository under `work` with a copy of scripts/ in `appFolder`.
    private func makeRepository(appFolder: String) throws -> (work: URL, repository: URL, app: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("app-folder-\(UUID().uuidString)")
        let repository = work.appendingPathComponent("repository")
        let app = repository.appendingPathComponent(appFolder).standardized
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: checkoutAppFolder.appendingPathComponent("scripts"), to: app.appendingPathComponent("scripts"))
        let initialized = try runProcess(git, ["init", "--quiet", repository.path], from: work)
        try #require(initialized.status == 0, "\(initialized.output)")
        return (work, repository, app)
    }

    @Test("build-update-release.sh reads release notes from the repository root", arguments: [".", "apps/macos"])
    func releaseNotesComeFromTheRepositoryRoot(appFolder: String) throws {
        let (work, repository, app) = try makeRepository(appFolder: appFolder)
        defer { try? FileManager.default.removeItem(at: work) }
        let releaseNotes = repository.appendingPathComponent("docs/releases")
        try FileManager.default.createDirectory(at: releaseNotes, withIntermediateDirectories: true)
        try "# Keybumps 0.0.1-fixture\n".write(to: releaseNotes.appendingPathComponent("v0.0.1-fixture.md"), atomically: true, encoding: .utf8)

        // An existing output directory stops the orchestrator right after the release-notes check.
        // It runs from this checkout, which has no notes for these versions, so notes found through
        // the working directory instead of the script's repository would fail the first case.
        let output = work.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func prepareRelease(_ version: String) throws -> (status: Int32, output: String) {
            try runProcess(app.appendingPathComponent("scripts/build-update-release.sh"), [
                version, "2", "1", "https://updates.keybumps.app/appcast.xml", "public-key", "account",
                work.appendingPathComponent("tools").path, output.path
            ], from: checkoutAppFolder)
        }

        let found = try prepareRelease("0.0.1-fixture")
        #expect(found.status == 73, "\(found.output)")
        #expect(found.output.contains("refusing to overwrite output directory"), "\(found.output)")

        let missing = try prepareRelease("0.0.1-missing")
        #expect(missing.status == 66, "\(missing.output)")
        #expect(missing.output.contains("\(work.lastPathComponent)/repository/docs/releases/v0.0.1-missing.md"), "\(missing.output)")
    }

    @Test("check-legacy-branding.sh scans the whole repository and allows app files by app folder", arguments: [".", "apps/macos"])
    func brandingCheckScansTheWholeRepository(appFolder: String) throws {
        let (work, repository, app) = try makeRepository(appFolder: appFolder)
        defer { try? FileManager.default.removeItem(at: work) }
        // Legacy terms are joined at run time, so this file passes the real check.
        let (legacyVariable, legacyName) = ("SUPER" + "MAC_", "Key" + " Bumps")
        // The copied check-legacy-branding.sh and this project.yml contain legacy terms. Both are
        // on the allowlist relative to the app folder, so they pass only if its prefix matches.
        try "# Release builds refuse \(legacyVariable)* variables.\n".write(to: app.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        func check() throws -> (status: Int32, output: String) {
            let staged = try runProcess(git, ["-C", repository.path, "add", "--all"], from: work)
            try #require(staged.status == 0, "\(staged.output)")
            return try runProcess(app.appendingPathComponent("scripts/check-legacy-branding.sh"), [], from: checkoutAppFolder)
        }

        let allowed = try check()
        #expect(allowed.status == 0, "\(allowed.output)")
        #expect(allowed.output.contains("Legacy branding allowlist check passed."), "\(allowed.output)")

        // A file at the repository root, outside apps/macos, must still be scanned.
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "Formerly \(legacyName).\n".write(to: repository.appendingPathComponent("docs/notes.md"), atomically: true, encoding: .utf8)
        let flagged = try check()
        #expect(flagged.status == 1, "\(flagged.output)")
        #expect(flagged.output.contains("  docs/notes.md"), "\(flagged.output)")
    }
}

/// Runs a script or tool from `directory` with this process's environment, minus the DYLD_ and
/// XCTest variables of the test host, and returns its exit status and combined output.
private func runProcess(
    _ executable: URL,
    _ arguments: [String],
    from directory: URL,
    environment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = cleanChildEnvironment.merging(environment) { $1 }
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private var cleanChildEnvironment: [String: String] {
    ProcessInfo.processInfo.environment.filter {
        !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest")
    }
}

/// A fake wrangler (for KEYBUMPS_WRANGLER) whose R2 bucket is the folder `bucket`: `put` uploads
/// and logs each key to `log` (and its metadata to `log.meta`), and `get --pipe` reads an object
/// back, failing when it is missing, as the release scripts read from R2. With FAKE_R2_READ_ERROR
/// set, every read fails the way an authentication error does.
private func writeFakeWrangler(to file: URL, bucket: URL, log: URL) throws {
    try """
    #!/bin/zsh
    set -euo pipefail
    if [[ "$1 $2 $3" == "r2 object get" ]]; then
      [[ -z "${FAKE_R2_READ_ERROR:-}" ]] || { print -u2 "Authentication error [code: 10000]"; exit 1; }
      object="\(bucket.path)/${4#keybumps-updates/}"
      [[ -f "$object" ]] || { print -u2 "The specified key does not exist."; exit 1; }
      cat "$object"
      exit 0
    fi
    [[ "$1 $2 $3" == "r2 object put" ]] || exit 9
    key=${4#keybumps-updates/}
    shift 4
    while (( $# )); do
      case $1 in --file) file=$2; shift 2 ;; --content-type|--cache-control) print -r -- "$key $1=$2" >> "\(log.path).meta"; shift 2 ;; --remote) shift ;; *) exit 8 ;; esac
    done
    mkdir -p "\(bucket.path)/${key:h}"
    cp "$file" "\(bucket.path)/$key"
    print -r -- "$key" >> "\(log.path)"
    """.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
}

final class UpdateReleaseScriptTests: XCTestCase {
    private var appFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPublicationDryRunAndFailClosedInputs() throws {
        let fixture = appFolder.appendingPathComponent("KeybumpsTests/Fixtures/Updates")
        let verifier = appFolder.appendingPathComponent("scripts/verify-update-publication.sh")
        let success = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--dry-run"
        ])
        XCTAssertEqual(success.status, 0, success.output)
        XCTAssertTrue(success.output.contains("Phase 1"))
        XCTAssertTrue(success.output.contains("Phase 2"))

        let invalid = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://example.com/appcast.xml",
            "--dry-run"
        ])
        XCTAssertNotEqual(invalid.status, 0)
    }

    func testFixtureServerAndLiveByteVerification() async throws {
        let fixture = appFolder.appendingPathComponent("KeybumpsTests/Fixtures/Updates")
        let server = Process()
        server.executableURL = appFolder.appendingPathComponent("scripts/serve-update-fixture.sh")
        server.arguments = [fixture.path, "18765"]
        server.environment = cleanChildEnvironment
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        var becameReady = false
        // Up to 15 seconds: the first /usr/bin/python3 launch on a CI runner can take several.
        for _ in 0..<150 {
            guard server.isRunning else { break }
            let health = try run(
                URL(fileURLWithPath: "/usr/bin/curl"),
                ["--fail", "--silent", "http://127.0.0.1:18765/appcast.xml"]
            )
            if health.status == 0 {
                becameReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !becameReady, !server.isRunning {
            XCTFail("Fixture server exited before becoming ready")
        }
        XCTAssertTrue(becameReady)

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServedUpdaterFixture-\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.serp.keybumps.served-fixture",
                "CFBundlePackageType": "BNDL",
                "SUPublicEDKey": "fixture-public-key"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))
        let configuration = try XCTUnwrap(SparkleUpdateConfiguration.from(
            bundle: bundle,
            environment: ["KEYBUMPS_UPDATE_FIXTURE_FEED_URL": "http://127.0.0.1:18765/appcast.xml"]
        ))
        let (servedFeed, response) = try await URLSession.shared.data(from: configuration.feedURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(XMLParser(data: servedFeed).parse(), "The served fixture must be parseable XML")

        let verifier = appFolder.appendingPathComponent("scripts/verify-update-publication.sh")
        let verified = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--verify-live"
        ])
        XCTAssertEqual(verified.status, 0, verified.output)

        let mismatched = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.md").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--verify-live"
        ])
        XCTAssertNotEqual(mismatched.status, 0)
        XCTAssertTrue(mismatched.output.contains("archive bytes differ"))
    }

    func testReleaseValidationAndOrchestrationFailClosedBeforeArtifacts() throws {
        let validator = appFolder.appendingPathComponent("scripts/validate-update-release.sh")
        let common = ["/tmp/missing.app", "/tmp/missing.zip", "/tmp/missing.xml", "/tmp/missing.md"]
        for maliciousFixtureURL in [
            "https://example.com/appcast.xml",
            "https://user:password@localhost/appcast.xml",
            "https://localhost/appcast.xml#fragment",
            "http://localhost:bad/appcast.xml",
            "http://local host/appcast.xml"
        ] {
            let result = try run(validator, common + [
                maliciousFixtureURL, maliciousFixtureURL, "1", "2", "0.0.2", "/tmp/tools", "fixture", "--skip-apple-trust-for-fixture"
            ])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("loopback feeds only"))
        }

        let reusedBuild = try run(validator, common + [
            "https://updates.keybumps.app/appcast.xml", "https://updates.keybumps.app/staging/appcast.xml", "2", "2", "0.0.2", "/tmp/tools", "production"
        ])
        XCTAssertNotEqual(reusedBuild.status, 0)
        XCTAssertTrue(reusedBuild.output.contains("greater than"))

        let orchestrator = appFolder.appendingPathComponent("scripts/build-update-release.sh")
        let invalidBuild = try run(orchestrator, [
            "0.0.2", "2", "2", "https://updates.example.com/appcast.xml", "public", "key", "/tmp/tools", "/tmp/output"
        ])
        XCTAssertNotEqual(invalidBuild.status, 0)
        XCTAssertTrue(invalidBuild.output.contains("greater than"))

        let wrongReleaseOrigin = try run(orchestrator, [
            "0.0.2", "2", "1", "https://updates.example.com/appcast.xml", "public", "key", "/tmp/tools", "/tmp/output"
        ])
        XCTAssertNotEqual(wrongReleaseOrigin.status, 0)
        XCTAssertTrue(wrongReleaseOrigin.output.contains("updates.keybumps.app"))

        for maliciousProductionURL in [
            "https:///appcast.xml",
            "https://user:password@example.com/appcast.xml",
            "https://example.com/appcast.xml#fragment",
            "https://example.com:99999/appcast.xml",
            "https://example .com/appcast.xml"
        ] {
            let result = try run(orchestrator, [
                "0.0.2", "2", "1", maliciousProductionURL, "public", "key", "/tmp/tools", "/tmp/output"
            ])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("credential-free"))
        }

        let urlHelper = appFolder.appendingPathComponent("scripts/lib/update_url_validation.py")
        let normalizedParent = try run(
            URL(fileURLWithPath: "/usr/bin/python3"),
            [urlHelper.path, "parent", "https://updates.example.com/beta/nested/appcast.xml"]
        )
        XCTAssertEqual(normalizedParent.status, 0, normalizedParent.output)
        XCTAssertEqual(normalizedParent.output.trimmingCharacters(in: .whitespacesAndNewlines), "https://updates.example.com/beta/nested/")
    }

    func testLatestReleasePointerFollowsTheAppcastAndFailsClosed() throws {
        let pointer = appFolder.appendingPathComponent("scripts/write-latest-release-pointer.sh")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("latest-pointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let digest = String(repeating: "ab", count: 32)
        let checksum = work.appendingPathComponent("Keybumps-0.0.3-beta.4.dmg.sha256")
        try "\(digest)  Keybumps-0.0.3-beta.4.dmg\n".write(to: checksum, atomically: true, encoding: .utf8)

        func appcast(url: String, build: Int = 4008, version: String = "0.0.3-beta.4") throws -> URL {
            let file = work.appendingPathComponent("appcast-\(UUID().uuidString).xml")
            try """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <enclosure url="\(url)" length="1" type="application/octet-stream" sparkle:edSignature="x"/></item>
            </channel></rss>
            """.write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        let output = work.appendingPathComponent("latest.json")
        let production = try run(pointer, [
            try appcast(url: "https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.zip").path,
            "4008", "0.0.3-beta.4", checksum.path, output.path
        ])
        XCTAssertEqual(production.status, 0, production.output)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "0.0.3-beta.4")
        XCTAssertEqual(json["build"] as? Int, 4008)
        XCTAssertEqual(json["dmgURL"] as? String, "https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg")
        XCTAssertEqual(json["sha256"] as? String, digest)

        let rootLayout = try run(pointer, [
            try appcast(url: "https://updates.keybumps.app/Keybumps-0.0.3-beta.4.zip").path,
            "4008", "0.0.3-beta.4", checksum.path, output.path
        ])
        XCTAssertEqual(rootLayout.status, 0, rootLayout.output)
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(rootJSON["dmgURL"] as? String, "https://updates.keybumps.app/Keybumps-0.0.3-beta.4.dmg", "the DMG sits beside the archive")

        let failures: [(String, [String])] = [
            ("foreign origin", [try appcast(url: "https://example.com/Keybumps-0.0.3-beta.4.zip").path, "4008", "0.0.3-beta.4", checksum.path]),
            ("plain HTTP", [try appcast(url: "http://updates.keybumps.app/Keybumps-0.0.3-beta.4.zip").path, "4008", "0.0.3-beta.4", checksum.path]),
            ("version mismatch", [try appcast(url: "https://updates.keybumps.app/a.zip").path, "4008", "0.0.3-beta.5", checksum.path]),
            ("build missing", [try appcast(url: "https://updates.keybumps.app/a.zip").path, "4009", "0.0.3-beta.4", checksum.path])
        ]
        for (name, arguments) in failures {
            let result = try run(pointer, arguments + [work.appendingPathComponent("\(name).json").path])
            XCTAssertNotEqual(result.status, 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("\(name).json").path), name)
        }

        let badChecksum = work.appendingPathComponent("bad.sha256")
        try "not-a-digest  x.dmg\n".write(to: badChecksum, atomically: true, encoding: .utf8)
        let bad = try run(pointer, [try appcast(url: "https://updates.keybumps.app/a.zip").path, "4008", "0.0.3-beta.4", badChecksum.path, work.appendingPathComponent("bad.json").path])
        XCTAssertNotEqual(bad.status, 0)
    }

    /// A release of 0.0.3-beta.4 (4008) prepared for publication in a temporary folder, as
    /// build-update-release.sh leaves it, with a fake R2 bucket to publish it to.
    private struct PreparedRelease {
        static let version = "0.0.3-beta.4", build = 4008
        let work: URL
        var output: URL { work.appendingPathComponent("release") }
        var assets: URL { output.appendingPathComponent("publication/assets") }
        var last: URL { output.appendingPathComponent("publication/publish-last") }
        var bucketRoot: URL { work.appendingPathComponent("r2") }
        var log: URL { work.appendingPathComponent("uploads.log") }
        var wrangler: URL { work.appendingPathComponent("fake-wrangler") }
        var environment: [String: String] { ["KEYBUMPS_WRANGLER": wrangler.path] }
        var uploads: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func writeAppcast(
            _ url: String = "https://updates.keybumps.app/releases/\(build)/Keybumps-\(version).zip",
            releaseDate: String? = "2026-09-29T04:20:34Z"
        ) throws {
            let date = releaseDate.map { "<keybumps:releaseDate>\($0)</keybumps:releaseDate>" } ?? ""
            try """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:keybumps="https://keybumps.app/xml-namespaces/appcast"><channel>
            <item><sparkle:version>\(Self.build)</sparkle:version>\(date)<sparkle:shortVersionString>\(Self.version)</sparkle:shortVersionString>
            <enclosure url="\(url)" length="7" type="application/octet-stream" sparkle:edSignature="x"/></item>
            </channel></rss>
            """.write(to: last.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
        }
    }

    private func makePreparedRelease() throws -> PreparedRelease {
        let release = PreparedRelease(work: FileManager.default.temporaryDirectory.appendingPathComponent("publish-\(UUID().uuidString)"))
        for directory in [release.assets, release.last, release.bucketRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let version = PreparedRelease.version, build = PreparedRelease.build
        for (name, body) in [("zip", "archive"), ("zip.sha256", "sum"), ("md", "# notes"), ("dmg", "disk image"), ("dmg.sha256", "sum")] {
            try Data(body.utf8).write(to: release.assets.appendingPathComponent("Keybumps-\(version).\(name)"))
        }
        try release.writeAppcast()
        try """
        {"version": "\(version)", "build": \(build), "dmgURL": "https://updates.keybumps.app/releases/\(build)/Keybumps-\(version).dmg", "sha256": "\(String(repeating: "ab", count: 32))"}
        """.write(to: release.last.appendingPathComponent("latest.json"), atomically: true, encoding: .utf8)
        try writeFakeWrangler(to: release.wrangler, bucket: release.bucketRoot, log: release.log)
        return release
    }

    func testPublishReleaseUploadsAssetsBeforePointersAndNeverOverwrites() throws {
        let publisher = appFolder.appendingPathComponent("scripts/publish-release.sh")
        let release = try makePreparedRelease()
        defer { try? FileManager.default.removeItem(at: release.work) }
        let version = PreparedRelease.version, build = PreparedRelease.build
        let output = release.output, last = release.last, bucketRoot = release.bucketRoot, log = release.log
        let environment = release.environment

        let dryRun = try run(publisher, [output.path, "production"], environment: environment)
        XCTAssertEqual(dryRun.status, 0, dryRun.output)
        XCTAssertTrue(dryRun.output.contains("Dry run only"))
        XCTAssertTrue(dryRun.output.contains("releases/4008/Keybumps-0.0.3-beta.4.dmg"))
        XCTAssertTrue(dryRun.output.contains("releases.json adds 0.0.3-beta.4 (4008), released 2026-09-29T04:20:34Z"), dryRun.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "a dry run uploads nothing")

        let published = try run(publisher, [output.path, "production", "--publish"], environment: environment)
        XCTAssertEqual(published.status, 0, published.output)
        let keys = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(keys.suffix(3)), ["appcast.xml", "latest.json", "releases.json"], "pointers are published last, then the release index")
        XCTAssertEqual(Set(keys.dropLast(3)), Set(["zip", "zip.sha256", "md", "dmg", "dmg.sha256"].map { "releases/4008/Keybumps-0.0.3-beta.4.\($0)" }))
        let metadata = try String(contentsOf: URL(fileURLWithPath: log.path + ".meta"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("releases/4008/Keybumps-0.0.3-beta.4.dmg --content-type=application/x-apple-diskimage"))
        XCTAssertTrue(metadata.contains("releases/4008/Keybumps-0.0.3-beta.4.zip --cache-control=public, max-age=31536000, immutable"))
        XCTAssertTrue(metadata.contains("appcast.xml --cache-control=public, max-age=60, must-revalidate"))
        XCTAssertTrue(metadata.contains("latest.json --content-type=application/json; charset=utf-8"))
        XCTAssertTrue(metadata.contains("releases.json --cache-control=public, max-age=60, must-revalidate"))
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bucketRoot.appendingPathComponent("releases.json"))) as? [[String: Any]])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.first?["version"] as? String, version)
        XCTAssertEqual(index.first?["build"] as? Int, build)
        XCTAssertEqual(index.first?["url"] as? String, "https://updates.keybumps.app/releases/4008/Keybumps-0.0.3-beta.4.dmg")
        XCTAssertEqual(index.first?["releasedAt"] as? String, "2026-09-29T04:20:34Z", "the release date the appcast item carries")

        var failingReads = environment
        failingReads["FAKE_R2_READ_ERROR"] = "1"
        let uploadsBeforeReadError = try String(contentsOf: log, encoding: .utf8)
        let unreadable = try run(publisher, [output.path, "production", "--publish"], environment: failingReads)
        XCTAssertNotEqual(unreadable.status, 0, "a read error must not be treated as a missing object")
        XCTAssertTrue(unreadable.output.contains("could not read"), unreadable.output)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), uploadsBeforeReadError, "nothing is uploaded after a read error")

        let rerun = try run(publisher, [output.path, "production", "--publish"], environment: environment)
        XCTAssertEqual(rerun.status, 0, rerun.output)
        XCTAssertTrue(rerun.output.contains("already published releases/4008/Keybumps-0.0.3-beta.4.zip"))
        XCTAssertTrue(rerun.output.contains("already listed: 0.0.3-beta.4 (4008)"), rerun.output)
        let indexAfterRerun = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bucketRoot.appendingPathComponent("releases.json"))) as? [[String: Any]])
        XCTAssertEqual(indexAfterRerun.count, 1, "a re-run lists the release once")

        try Data("different".utf8).write(to: bucketRoot.appendingPathComponent("releases/4008/Keybumps-0.0.3-beta.4.dmg"))
        let overwrite = try run(publisher, [output.path, "production", "--publish"], environment: environment)
        XCTAssertNotEqual(overwrite.status, 0)
        XCTAssertTrue(overwrite.output.contains("refusing to overwrite immutable releases/4008/Keybumps-0.0.3-beta.4.dmg"))

        let staging = try run(publisher, [output.path, "staging"], environment: environment)
        XCTAssertTrue(staging.output.contains("staging/appcast.xml"), staging.output)
        XCTAssertFalse(staging.output.contains("latest.json"), "only production moves the latest-release pointer")
        XCTAssertFalse(staging.output.contains("releases.json"), "only production adds to the release index")

        XCTAssertNotEqual(try run(publisher, [output.path, "beta"], environment: environment).status, 0)
        try release.writeAppcast("https://updates.keybumps.app/Keybumps-\(version).zip")
        let wrongLayout = try run(publisher, [output.path, "production"], environment: environment)
        XCTAssertNotEqual(wrongLayout.status, 0)
        XCTAssertTrue(wrongLayout.output.contains("releases/4008"))
        try release.writeAppcast(releaseDate: nil)
        let undated = try run(publisher, [output.path, "production"], environment: environment)
        XCTAssertNotEqual(undated.status, 0, "the release index needs the appcast item's release date")
        XCTAssertTrue(undated.output.contains("no release date"), undated.output)
        XCTAssertEqual(try run(publisher, [output.path, "staging"], environment: environment).status, 0, "staging has no release index")
        try FileManager.default.removeItem(at: last.appendingPathComponent("latest.json"))
        try release.writeAppcast()
        XCTAssertNotEqual(try run(publisher, [output.path, "production"], environment: environment).status, 0, "production needs latest.json")
        XCTAssertEqual(try run(publisher, [output.path, "staging"], environment: environment).status, 0)
    }

    /// Phase 3, the release index, runs after the pointers: when it fails, the release is already
    /// live and the index is left as it was. A production dry run with --check-index finds the same
    /// problem before approval, uploading nothing.
    func testReleaseIndexFailureLeavesTheReleaseLiveAndTheIndexUnchanged() throws {
        let publisher = appFolder.appendingPathComponent("scripts/publish-release.sh")
        let release = try makePreparedRelease()
        defer { try? FileManager.default.removeItem(at: release.work) }
        let liveIndex = release.bucketRoot.appendingPathComponent("releases.json")
        let invalid = Data(#"[{"version": "#.utf8)
        try invalid.write(to: liveIndex)

        let check = try run(publisher, [release.output.path, "production", "--check-index"], environment: release.environment)
        XCTAssertNotEqual(check.status, 0, "a live index the release can't merge into fails the check: \(check.output)")
        XCTAssertTrue(check.output.contains("release index:"), check.output)
        XCTAssertEqual(release.uploads, [], "a check uploads nothing")
        XCTAssertNotEqual(try run(publisher, [release.output.path, "staging", "--check-index"], environment: release.environment).status, 0, "staging has no release index")

        let published = try run(publisher, [release.output.path, "production", "--publish"], environment: release.environment)
        XCTAssertNotEqual(published.status, 0, "phase 3 fails on a live index it can't merge into: \(published.output)")
        XCTAssertTrue(published.output.contains("Publishing phase 3"), published.output)
        XCTAssertEqual(Array(release.uploads.suffix(2)), ["appcast.xml", "latest.json"], "the pointers are published before phase 3")
        XCTAssertFalse(release.uploads.contains("releases.json"))
        for pointer in ["appcast.xml", "latest.json"] {
            XCTAssertEqual(
                try Data(contentsOf: release.bucketRoot.appendingPathComponent(pointer)),
                try Data(contentsOf: release.last.appendingPathComponent(pointer)),
                "\(pointer) is live"
            )
        }
        XCTAssertEqual(try Data(contentsOf: liveIndex), invalid, "the live index is left as it was")

        // Once the live index is fixed, the check passes and reads it, still uploading nothing.
        try Data(#"[{"version": "0.0.3-beta.3", "build": 4007, "url": "https://updates.keybumps.app/releases/4007/Keybumps-0.0.3-beta.3.dmg", "releasedAt": "2026-09-19T10:00:00Z"}]"#.utf8).write(to: liveIndex)
        let uploadsBeforeCheck = release.uploads
        let fixed = try run(publisher, [release.output.path, "production", "--check-index"], environment: release.environment)
        XCTAssertEqual(fixed.status, 0, fixed.output)
        XCTAssertTrue(fixed.output.contains("added: 0.0.3-beta.4 (4008)"), fixed.output)
        XCTAssertTrue(fixed.output.contains("2 releases in all, newest 0.0.3-beta.4 (4008)"), fixed.output)
        XCTAssertEqual(release.uploads, uploadsBeforeCheck, "a check uploads nothing")

        var failingReads = release.environment
        failingReads["FAKE_R2_READ_ERROR"] = "1"
        let unreadable = try run(publisher, [release.output.path, "production", "--check-index"], environment: failingReads)
        XCTAssertNotEqual(unreadable.status, 0, "an unreadable live index fails the check")
        XCTAssertTrue(unreadable.output.contains("could not read releases.json"), unreadable.output)
    }

    func testReleaseNotesComeFromTheChangelogWithoutLinks() throws {
        let writer = appFolder.appendingPathComponent("scripts/write-release-notes.sh")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let changelog = work.appendingPathComponent("CHANGELOG.md")
        try """
        # Changelog

        ## [0.0.3-beta.4](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.3...v0.0.3-beta.4) (2026-09-28)

        ### Features

        * add a Screenshots tab ([88f94da](https://github.com/serpcompany/keybumps/commit/88f94da)), closes [#59](https://github.com/serpcompany/keybumps/issues/59)
        * **editor:** number keys select tools ([#62](https://github.com/serpcompany/keybumps/issues/62)) ([3ce4272](https://github.com/serpcompany/keybumps/commit/3ce4272))

        ### Fixes

        * recover denied Microphone access ([2764245](https://github.com/serpcompany/keybumps/commit/2764245))

        ## [0.0.3-beta.3](https://github.com/serpcompany/keybumps/compare/x) (2026-09-19)

        * older entry
        """.write(to: changelog, atomically: true, encoding: .utf8)

        let output = work.appendingPathComponent("v0.0.3-beta.4.md")
        let result = try run(writer, [changelog.path, "0.0.3-beta.4", output.path])
        XCTAssertEqual(result.status, 0, result.output)
        let notes = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(notes.hasPrefix("# Keybumps 0.0.3-beta.4\n"))
        XCTAssertTrue(notes.contains("- add a Screenshots tab\n"))
        XCTAssertTrue(notes.contains("- **editor:** number keys select tools\n"))
        XCTAssertTrue(notes.contains("### Fixes"))
        XCTAssertFalse(notes.contains("http"), "no commit, PR, or compare links reach users")
        XCTAssertFalse(notes.contains("older entry"), "only the requested version's section")

        let handWritten = work.appendingPathComponent("v0.0.3-beta.3.md")
        try "# Keybumps 0.0.3-beta.3\n\nHand-written.\n".write(to: handWritten, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(writer, [changelog.path, "0.0.3-beta.3", handWritten.path]).status, 0)
        XCTAssertEqual(try String(contentsOf: handWritten, encoding: .utf8), "# Keybumps 0.0.3-beta.3\n\nHand-written.\n", "hand-written notes win")

        let missing = try run(writer, [changelog.path, "0.0.3-beta.9", work.appendingPathComponent("missing.md").path])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertNotEqual(try run(writer, [changelog.path, "latest", work.appendingPathComponent("bad.md").path]).status, 0)
    }

    private func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        try runProcess(executable, arguments, from: appFolder, environment: environment)
    }
}

/// ADR 0011: the release script adds the release date to the build's appcast item, which the app
/// checks against the license's update year, and signs the feed again.
@Suite("Appcast release date")
struct AppcastReleaseDateTests {
    private let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/stamp-appcast-release-date.sh")

    /// A folder with a signed-looking appcast for build 4033, and a `sign_update` that records its
    /// arguments and signs by appending a signature comment, as Sparkle's does.
    private func makeFixture() throws -> (work: URL, appcast: URL, tools: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("release-date-\(UUID().uuidString)")
        let tools = work.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let signUpdate = tools.appendingPathComponent("sign_update")
        try """
        #!/bin/zsh
        print -r -- "$@" >> "${0:h}/calls"
        print '<!-- sparkle-signatures:\nedSignature: test\nlength: 1\n-->' >> "${@[-1]}"
        """.write(to: signUpdate, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signUpdate.path)
        let appcast = work.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0" standalone="yes"?><!-- sparkle-sign-warning:
        IMPORTANT: This file was signed by Sparkle.
        --><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <item>
                    <title>0.0.3-beta.28</title>
                    <sparkle:version>4033</sparkle:version>
                    <sparkle:shortVersionString>0.0.3-beta.28</sparkle:shortVersionString>
                    <enclosure url="https://updates.keybumps.app/releases/4033/Keybumps-0.0.3-beta.28.zip" length="1" type="application/octet-stream" sparkle:edSignature="x"></enclosure>
                </item>
            </channel>
        </rss><!-- sparkle-signatures:
        edSignature: old
        length: 1
        -->
        """.write(to: appcast, atomically: true, encoding: .utf8)
        return (work, appcast, tools)
    }

    private func stamp(_ arguments: [String], in work: URL) throws -> (status: Int32, output: String) {
        try runProcess(script, arguments, from: work, environment: ["KEYBUMPS_SPARKLE_KEY_FILE": "/fixture/key"])
    }

    @Test("The build's item gets the release date in Keybumps's namespace, and the feed is signed again")
    func stampsAndSigns() throws {
        let (work, appcast, tools) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: work) }

        let result = try stamp([appcast.path, "4033", "2026-10-19T12:00:00Z", tools.path], in: work)
        #expect(result.status == 0, "\(result.output)")
        let feed = try String(contentsOf: appcast, encoding: .utf8)
        #expect(feed.contains(#"<rss xmlns:keybumps="https://keybumps.app/xml-namespaces/appcast" "#))
        #expect(feed.contains("<sparkle:version>4033</sparkle:version>\n            <keybumps:releaseDate>2026-10-19T12:00:00Z</keybumps:releaseDate>"))
        #expect(UpdateCandidate.releaseDateKey == "keybumps:releaseDate", "The name Sparkle gives the element")
        let calls = try String(contentsOf: tools.appendingPathComponent("calls"), encoding: .utf8)
        // The script resolves the path, which may add /private to a temporary folder.
        #expect(calls.hasPrefix("--ed-key-file /fixture/key /") && calls.hasSuffix("/\(work.lastPathComponent)/appcast.xml\n"), "\(calls)")

        // What validate-update-release.sh reads back.
        let read = try runProcess(URL(fileURLWithPath: "/usr/bin/xmllint"), [
            "--xpath", "string(//*[local-name()='item'][1]/*[local-name()='releaseDate'])", appcast.path
        ], from: work)
        #expect(read.output.trimmingCharacters(in: .whitespacesAndNewlines) == "2026-10-19T12:00:00Z")

        let again = try stamp([appcast.path, "4033", "2026-10-19T12:00:00Z", tools.path], in: work)
        #expect(again.status == 70)
        #expect(again.output.contains("already carries a release date"))
    }

    @Test("A date that isn't a UTC time, or no item for the build, changes nothing", arguments: [
        ["4033", "2026-10-19"], ["4033", "2026-10-19T12:00:00+02:00"], ["4034", "2026-10-19T12:00:00Z"],
    ])
    func failsClosed(arguments: [String]) throws {
        let (work, appcast, tools) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: work) }
        let before = try Data(contentsOf: appcast)
        let result = try stamp([appcast.path] + arguments + [tools.path], in: work)
        #expect(result.status != 0, "\(result.output)")
        #expect(try Data(contentsOf: appcast) == before)
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("calls").path))
    }
}

/// ADR 0011: validate-update-release.sh fails when the app's release date and its appcast item's
/// differ. Fixture mode skips Apple's checks, so a fixture reaches the date check.
@Suite("Release validation of the release date")
struct ReleaseDateValidationTests {
    private let validator = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/validate-update-release.sh")
    private let feed = "http://127.0.0.1:8765/appcast.xml"

    private func validate(appDate: String?, appcastDate: String?) throws -> (status: Int32, output: String) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("release-date-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let tools = work.appendingPathComponent("tools")
        let contents = work.appendingPathComponent("Keybumps.app/Contents")
        for folder in [tools, contents.appendingPathComponent("Resources"), contents.appendingPathComponent("MacOS")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let publicKey = String(repeating: "A", count: 43) + "="
        for (name, script) in [("generate_keys", "print 'Public key: \(publicKey)'"), ("sign_update", "exit 0")] {
            let tool = tools.appendingPathComponent(name)
            try "#!/bin/zsh\n\(script)\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.serp.keybumps", "CFBundleVersion": "4033", "CFBundleShortVersionString": "0.0.3-beta.28",
            "SUFeedURL": feed, "SUPublicEDKey": publicKey, "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        ]
        info["KBBuildReleaseDate"] = appDate
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try "# Notes\n".write(to: contents.appendingPathComponent("Resources/WhatsNew.md"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/Keybumps").path)
        let archive = work.appendingPathComponent("Keybumps-0.0.3-beta.28.zip")
        try Data("archive".utf8).write(to: archive)
        // SHA-256 of "archive".
        try "0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3  Keybumps-0.0.3-beta.28.zip\n".write(to: work.appendingPathComponent("Keybumps-0.0.3-beta.28.zip.sha256"), atomically: true, encoding: .utf8)
        let notes = work.appendingPathComponent("Keybumps-0.0.3-beta.28.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        let appcast = work.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:keybumps="https://keybumps.app/xml-namespaces/appcast" version="2.0"><channel><item>
        <sparkle:version>4033</sparkle:version>\(appcastDate.map { "<keybumps:releaseDate>\($0)</keybumps:releaseDate>" } ?? "")
        <sparkle:shortVersionString>0.0.3-beta.28</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
        <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
        <sparkle:releaseNotesLink sparkle:edSignature="x" sparkle:length="8">http://127.0.0.1:8765/Keybumps-0.0.3-beta.28.md</sparkle:releaseNotesLink>
        <enclosure url="http://127.0.0.1:8765/Keybumps-0.0.3-beta.28.zip" length="7" type="application/octet-stream" sparkle:edSignature="x"></enclosure>
        </item></channel></rss><!-- sparkle-signatures:
        edSignature: x
        length: 1
        -->
        """.write(to: appcast, atomically: true, encoding: .utf8)
        return try runProcess(validator, [
            contents.deletingLastPathComponent().path, archive.path, appcast.path, notes.path, feed, feed,
            "4032", "4033", "0.0.3-beta.28", tools.path, "fixture", "--skip-apple-trust-for-fixture",
        ], from: work)
    }

    @Test("A release date the appcast doesn't match, or a missing one, fails validation", arguments: [
        ("2026-10-19T12:00:00Z", "2026-10-19T12:00:01Z"),
        ("2026-10-19T12:00:00Z", nil),
        (nil, "2026-10-19T12:00:00Z"),
        ("2026-10-19", "2026-10-19"),
    ] as [(String?, String?)])
    func mismatch(appDate: String?, appcastDate: String?) throws {
        let result = try validate(appDate: appDate, appcastDate: appcastDate)
        #expect(result.status == 70, "\(result.output)")
        #expect(result.output.contains("release date"), "\(result.output)")
    }

    @Test("Matching dates, or none in a fixture, pass the date check", arguments: [
        ("2026-10-19T12:00:00Z", "2026-10-19T12:00:00Z"), (nil, nil),
    ] as [(String?, String?)])
    func matching(appDate: String?, appcastDate: String?) throws {
        let result = try validate(appDate: appDate, appcastDate: appcastDate)
        #expect(!result.output.contains("release date"), "\(result.output)")
        // The asset-prefix check after the date's takes only HTTPS feeds, so a loopback fixture stops there.
        #expect(result.output.contains("production URL must use HTTPS"), "Reached a later check: \(result.output)")
    }
}

/// #565: releases.json, the release index on the production release origin, from which the website
/// links each release's DMG. Entries are only added or replaced, never dropped, newest first, and
/// nothing is uploaded when the live index can't be read or disagrees with what's being added.
@Suite("Release index")
struct ReleaseIndexTests {
    private let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")

    private struct Entry: Codable, Equatable {
        let version: String
        let build: Int
        let url: String
        let releasedAt: String

        init(_ version: String, _ build: Int, _ releasedAt: String = "2026-10-22T09:30:00Z") {
            self.version = version
            self.build = build
            self.url = "https://updates.keybumps.app/releases/\(build)/Keybumps-\(version).dmg"
            self.releasedAt = releasedAt
        }
    }

    /// A temporary folder holding a fake R2 bucket, its wrangler, and its upload log.
    private struct Bucket {
        let work: URL
        var root: URL { work.appendingPathComponent("r2") }
        var log: URL { work.appendingPathComponent("uploads.log") }
        var wrangler: URL { work.appendingPathComponent("fake-wrangler") }
        var index: URL { root.appendingPathComponent("releases.json") }
        var uploads: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private func makeBucket(live: [Entry]? = nil) throws -> Bucket {
        let bucket = Bucket(work: FileManager.default.temporaryDirectory.appendingPathComponent("release-index-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: bucket.root, withIntermediateDirectories: true)
        try writeFakeWrangler(to: bucket.wrangler, bucket: bucket.root, log: bucket.log)
        if let live { try write(live, to: bucket.index) }
        return bucket
    }

    private func write(_ entries: [Entry], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: file)
    }

    private func read(_ file: URL) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }

    /// Runs publish-release-index.sh with `additions` against the fake bucket: `--publish`,
    /// `--check-live`, or with no mode, a dry run.
    private func publish(
        _ additions: [Entry], to bucket: Bucket, mode: String? = "--publish", environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let file = bucket.work.appendingPathComponent("additions-\(UUID().uuidString).json")
        try write(additions, to: file)
        return try runProcess(
            scripts.appendingPathComponent("publish-release-index.sh"), [file.path] + (mode.map { [$0] } ?? []),
            from: bucket.work, environment: environment.merging(["KEYBUMPS_WRANGLER": bucket.wrangler.path]) { $1 }
        )
    }

    @Test("The committed backfill lists beta.2 to beta.28 newest first, with beta.6's production build")
    func backfill() throws {
        let backfill = scripts.appendingPathComponent("release-index-backfill.json")
        let check = try runProcess(URL(fileURLWithPath: "/usr/bin/python3"), [
            scripts.appendingPathComponent("lib/release_index.py").path, "check", backfill.path
        ], from: scripts)
        #expect(check.status == 0, "\(check.output)")
        let entries = try read(backfill)
        #expect(entries.map(\.version) == (2...28).reversed().map { "0.0.3-beta.\($0)" }, "No DMG was ever published for beta.1")
        #expect(entries.first?.build == 4033)
        #expect(entries.last?.build == 4006)
        #expect(entries.first(where: { $0.version == "0.0.3-beta.6" })?.build == 4011, "4011 replaced 4010 in production")
        #expect(entries.allSatisfy { $0 == Entry($0.version, $0.build, $0.releasedAt) }, "Each URL is its release's DMG")
    }

    @Test("A dry run checks the additions and reads or uploads nothing")
    func dryRun() throws {
        let bucket = try makeBucket()
        defer { try? FileManager.default.removeItem(at: bucket.work) }
        let result = try publish([Entry("0.0.3-beta.29", 4034)], to: bucket, mode: nil, environment: ["FAKE_R2_READ_ERROR": "1"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("added: 0.0.3-beta.29 (4034)"))
        #expect(result.output.contains("Dry run only"))
        #expect(bucket.uploads.isEmpty)
    }

    @Test("Without a live index, publishing starts a list; later releases join it newest first, once each")
    func grows() throws {
        let bucket = try makeBucket()
        defer { try? FileManager.default.removeItem(at: bucket.work) }

        let first = try publish([Entry("0.0.3-beta.28", 4033, "2026-10-19T15:21:01Z")], to: bucket)
        #expect(first.status == 0, "\(first.output)")
        #expect(first.output.contains("no live releases.json yet"))
        let second = try publish([Entry("0.0.3-beta.29", 4034)], to: bucket)
        #expect(second.status == 0, "\(second.output)")
        let again = try publish([Entry("0.0.3-beta.29", 4034)], to: bucket)
        #expect(again.status == 0, "\(again.output)")
        #expect(again.output.contains("already listed: 0.0.3-beta.29 (4034)"))

        #expect(try read(bucket.index) == [Entry("0.0.3-beta.29", 4034), Entry("0.0.3-beta.28", 4033, "2026-10-19T15:21:01Z")])
        #expect(bucket.uploads == ["releases.json", "releases.json", "releases.json"])
        let metadata = try String(contentsOf: URL(fileURLWithPath: bucket.log.path + ".meta"), encoding: .utf8)
        #expect(metadata.contains("releases.json --content-type=application/json; charset=utf-8"))
        #expect(metadata.contains("releases.json --cache-control=public, max-age=60, must-revalidate"))
    }

    @Test("A version published again under a higher build replaces its entry")
    func republished() throws {
        let bucket = try makeBucket(live: [Entry("0.0.3-beta.7", 4012), Entry("0.0.3-beta.6", 4010)])
        defer { try? FileManager.default.removeItem(at: bucket.work) }
        let result = try publish([Entry("0.0.3-beta.6", 4011)], to: bucket)
        #expect(result.status == 0, "\(result.output)")
        #expect(try read(bucket.index) == [Entry("0.0.3-beta.7", 4012), Entry("0.0.3-beta.6", 4011)])
    }

    @Test("A live index that can't be read or disagrees with the additions stops before any upload", arguments: [
        "build listed under another version", "build listed with another date", "lower build for a listed version",
        "read error", "live index not JSON", "live index out of order",
    ])
    func stops(problem: String) throws {
        let live = [Entry("0.0.3-beta.28", 4033), Entry("0.0.3-beta.27", 4032)]
        let bucket = try makeBucket(live: live)
        defer { try? FileManager.default.removeItem(at: bucket.work) }
        var additions = [Entry("0.0.3-beta.29", 4034)]
        var environment: [String: String] = [:]
        switch problem {
        case "build listed under another version": additions = [Entry("0.0.3-beta.30", 4033)]
        case "build listed with another date": additions = [Entry("0.0.3-beta.28", 4033, "2026-10-19T00:00:00Z")]
        case "lower build for a listed version": additions = [Entry("0.0.3-beta.28", 4031)]
        case "read error": environment["FAKE_R2_READ_ERROR"] = "1"
        case "live index not JSON": try Data(#"[{"version": "#.utf8).write(to: bucket.index)
        default: try write(live.reversed(), to: bucket.index)
        }
        let before = try Data(contentsOf: bucket.index)

        let check = try publish(additions, to: bucket, mode: "--check-live", environment: environment)
        #expect(check.status != 0, "The check finds it before a release is approved: \(check.output)")
        let result = try publish(additions, to: bucket, environment: environment)
        #expect(result.status != 0, "\(result.output)")
        #expect(bucket.uploads.isEmpty, "\(result.output)")
        #expect(try Data(contentsOf: bucket.index) == before)
    }

    @Test("Checking against the live index merges into it and uploads nothing")
    func checkLive() throws {
        let live = [Entry("0.0.3-beta.28", 4033)]
        let bucket = try makeBucket(live: live)
        defer { try? FileManager.default.removeItem(at: bucket.work) }
        let result = try publish([Entry("0.0.3-beta.29", 4034)], to: bucket, mode: "--check-live")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("added: 0.0.3-beta.29 (4034)"))
        #expect(result.output.contains("2 releases in all, newest 0.0.3-beta.29 (4034)"))
        #expect(result.output.contains("Checked only"))
        #expect(bucket.uploads.isEmpty)
        #expect(try read(bucket.index) == live)
    }

    @Test("An entry that isn't a release's DMG with a UTC time fails even a dry run", arguments: [
        #"[{"version": "0.0.3-beta.29", "build": 4034, "url": "https://example.com/Keybumps.dmg", "releasedAt": "2026-10-22T09:30:00Z"}]"#,
        #"[{"version": "0.0.3-beta.29", "build": 4034, "url": "https://updates.keybumps.app/releases/4034/Keybumps-0.0.3-beta.29.dmg", "releasedAt": "2026-10-22"}]"#,
        #"[{"version": "0.0.3-beta.29", "build": 4034, "url": "https://updates.keybumps.app/releases/4034/Keybumps-0.0.3-beta.29.dmg", "releasedAt": "2026-02-30T09:30:00Z"}]"#,
        #"[{"version": "0.0.3-beta.29", "build": "4034", "url": "https://updates.keybumps.app/releases/4034/Keybumps-0.0.3-beta.29.dmg", "releasedAt": "2026-10-22T09:30:00Z"}]"#,
        #"[{"version": "0.0.3-beta.29", "build": 4034, "url": "https://updates.keybumps.app/releases/4034/Keybumps-0.0.3-beta.29.dmg"}]"#,
        #"{"version": "0.0.3-beta.29", "build": 4034, "url": "https://updates.keybumps.app/releases/4034/Keybumps-0.0.3-beta.29.dmg", "releasedAt": "2026-10-22T09:30:00Z"}"#,
    ])
    func rejectsBadEntries(additions: String) throws {
        let bucket = try makeBucket()
        defer { try? FileManager.default.removeItem(at: bucket.work) }
        let file = bucket.work.appendingPathComponent("additions.json")
        try Data(additions.utf8).write(to: file)
        let result = try runProcess(
            scripts.appendingPathComponent("publish-release-index.sh"), [file.path],
            from: bucket.work, environment: ["KEYBUMPS_WRANGLER": bucket.wrangler.path]
        )
        #expect(result.status == 65, "\(result.output)")
        #expect(result.output.contains("release index:"), "\(result.output)")
    }
}
