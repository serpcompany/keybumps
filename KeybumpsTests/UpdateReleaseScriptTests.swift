import Foundation
import XCTest
@testable import Keybumps

final class UpdateReleaseScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPublicationDryRunAndFailClosedInputs() throws {
        let fixture = repositoryRoot.appendingPathComponent("KeybumpsTests/Fixtures/Updates")
        let verifier = repositoryRoot.appendingPathComponent("scripts/verify-update-publication.sh")
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
        let fixture = repositoryRoot.appendingPathComponent("KeybumpsTests/Fixtures/Updates")
        let server = Process()
        server.executableURL = repositoryRoot.appendingPathComponent("scripts/serve-update-fixture.sh")
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
        for _ in 0..<30 {
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

        let verifier = repositoryRoot.appendingPathComponent("scripts/verify-update-publication.sh")
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
        let validator = repositoryRoot.appendingPathComponent("scripts/validate-update-release.sh")
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

        let orchestrator = repositoryRoot.appendingPathComponent("scripts/build-update-release.sh")
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

        let urlHelper = repositoryRoot.appendingPathComponent("scripts/lib/update_url_validation.py")
        let normalizedParent = try run(
            URL(fileURLWithPath: "/usr/bin/python3"),
            [urlHelper.path, "parent", "https://updates.example.com/beta/nested/appcast.xml"]
        )
        XCTAssertEqual(normalizedParent.status, 0, normalizedParent.output)
        XCTAssertEqual(normalizedParent.output.trimmingCharacters(in: .whitespacesAndNewlines), "https://updates.example.com/beta/nested/")
    }

    func testLatestReleasePointerFollowsTheAppcastAndFailsClosed() throws {
        let pointer = repositoryRoot.appendingPathComponent("scripts/write-latest-release-pointer.sh")
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

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = cleanChildEnvironment
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
}
