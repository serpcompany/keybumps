import Foundation
import Testing
@testable import Keybumps

/// The review panel's repository guess: what it reads at capture time (the app in front, and a
/// browser's domain reduced as Clipboard History's is), how it reads a typed repository, and how
/// it remembers the person's corrections. Nothing here reads the app in front or asks
/// Accessibility: the reader's parts are made up.
@MainActor
@Suite("Screencast: the repository guess")
struct ScreencastRepositoryGuessTests {
    let folder = TemporaryCapturesFolder()

    private func memory(_ name: String = "repositories.json") -> ScreencastRepositoryMemory {
        ScreencastRepositoryMemory(storageURL: folder.url.appendingPathComponent(name))
    }

    private static func repository(_ text: String) throws -> ScreencastRepository {
        try #require(ScreencastRepository(text))
    }

    // MARK: Typed repositories

    @Test("A repository is owner/name, or a github.com address of it or of anything in it")
    func parsesRepositories() {
        for text in [
            "serpcompany/keybumps", " serpcompany/keybumps/ ", "github.com/serpcompany/keybumps",
            "https://github.com/serpcompany/keybumps", "https://www.github.com/serpcompany/keybumps.git",
            "https://github.com/serpcompany/keybumps/issues/450?x=1#y", "HTTPS://GITHUB.COM/serpcompany/keybumps",
            "github.com/serpcompany/keybumps/pull/1",
        ] {
            #expect(ScreencastRepository(text) == ScreencastRepository("serpcompany/keybumps"), "\(text)")
            #expect(ScreencastRepository(text)?.description == "serpcompany/keybumps", "\(text)")
        }
        #expect(ScreencastRepository("a-b/c.d_e-f")?.description == "a-b/c.d_e-f")
    }

    @Test("Anything else isn't a repository")
    func rejectsOtherText() {
        for text in [
            "", "keybumps", "serpcompany/", "/keybumps", "a/b/c", "serp company/keybumps", "serpcompany/key bumps",
            "-serp/keybumps", "serp-/keybumps", "se--rp/keybumps", "serpcompany/.", "serpcompany/..",
            String(repeating: "a", count: 40) + "/keybumps", "serpcompany/" + String(repeating: "a", count: 101),
            "https://gitlab.com/serpcompany/keybumps", "https://github.com/serpcompany", "ftp://github.com/a/b",
            "sërp/keybumps",
        ] {
            #expect(ScreencastRepository(text) == nil, "\(text)")
        }
    }

    @Test("A repository is stored as its owner/name text")
    func codesAsText() throws {
        let data = try JSONEncoder().encode([Self.repository("serpcompany/keybumps")])
        #expect(String(decoding: data, as: UTF8.self) == #"["serpcompany\/keybumps"]"#)
        #expect(try JSONDecoder().decode([ScreencastRepository].self, from: data) == [Self.repository("serpcompany/keybumps")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([ScreencastRepository].self, from: Data(#"["nope"]"#.utf8)) }
    }

    // MARK: Domain reduction

    @Test("A browser's page is kept as its domain only, reduced as Clipboard History's source domain is")
    func reducesPageAddressesToDomains() async {
        let cases: [(String?, String?)] = [
            ("https://github.com/serpcompany/keybumps/issues/450?q=secret#frag", "github.com"),
            ("http://Docs.Example.COM./a/b", "docs.example.com"),
            ("https://user:pass@shop.example.co.uk:8443/cart", "shop.example.co.uk"),
            ("https://\u{0435}xample.com/login", "xn--xample-2of.com"),
            ("https://localhost:3000/", nil),
            ("http://127.0.0.1:8080/", nil),
            ("https://[::1]/", nil),
            ("https://intranet/", nil),
            ("https://myapp.test/", nil),
            ("https://printer.local/", nil),
            ("file:///Users/someone/Documents/secret.html", nil),
            ("about:blank", nil),
            ("", nil),
            (nil, nil),
        ]
        for (address, domain) in cases {
            let context = await ScreencastCaptureContextReader.context(
                front: Self.safari,
                ownProcessIdentifier: 1,
                isBrowser: { _ in true },
                accessibilityTrusted: { true },
                pageAddress: { _ in address }
            )
            #expect(context.domain == domain, "\(address ?? "nil")")
            #expect(context.domain == ClipboardSourceDomain.host(ofPageAddress: address), "the same rules as Clipboard History")
            let stored = String(decoding: (try? JSONEncoder().encode(context)) ?? Data(), as: UTF8.self)
            #expect(!stored.contains("secret") && !stored.contains("/issues") && !stored.contains("pass"), "only the domain is kept")
        }
    }

    @Test("A local development site is kept as its host and port, for the guess only, and the Clipboard rules don't change")
    func keepsDevHostsForTheGuess() async {
        let cases: [(String, String?)] = [
            ("http://localhost:3000/admin?token=secret", "localhost:3000"),
            ("http://LOCALHOST/", "localhost"),
            ("http://app.localhost:5173/settings", "app.localhost:5173"),
            ("https://myapp.test/login#x", "myapp.test"),
            ("https://api.myapp.test:8443/", "api.myapp.test:8443"),
            ("http://127.0.0.1:8080/", "127.0.0.1:8080"),
            ("http://192.168.1.20:3000/", nil),
            ("https://printer.local/", nil),
            ("https://intranet/", nil),
            ("https://test/", nil),
            ("file:///Users/someone/site/index.html", nil),
            ("https://github.com/serpcompany/keybumps", nil),
        ]
        for (address, devHost) in cases {
            let context = await ScreencastCaptureContextReader.context(
                front: Self.safari, ownProcessIdentifier: 1,
                isBrowser: { _ in true }, accessibilityTrusted: { true },
                pageAddress: { _ in address }
            )
            #expect(context.devHost == devHost, "\(address)")
            if devHost != nil {
                #expect(context.domain == nil && ClipboardSourceDomain.host(ofPageAddress: address) == nil, "Clipboard still leaves it out")
            }
        }
        let github = await ScreencastCaptureContextReader.context(
            front: Self.safari, ownProcessIdentifier: 1, isBrowser: { _ in true }, accessibilityTrusted: { true },
            pageAddress: { _ in "https://github.com/" }
        )
        #expect(github.domain == "github.com" && github.devHost == nil)
    }

    @Test("A correction on a local development site is remembered for its host and port")
    func remembersDevHosts() throws {
        defer { folder.remove() }
        let site = try Self.repository("serpcompany/keybumps")
        let other = try Self.repository("serpcompany/serp")
        let memory = memory()
        memory.remember(site, for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", devHost: "localhost:3000"))
        memory.remember(other, for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome"))
        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", devHost: "localhost:3000"))
                == ScreencastRepositoryGuess(repository: site, source: .website("localhost:3000")))
        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", devHost: "localhost:4000"))?.repository
                == other, "another port is another app")
        #expect(memory.stored.websites == ["localhost:3000": site])
    }

    // MARK: The context at capture time

    static let safari = ScreencastCaptureContextReader.FrontApp(processIdentifier: 42, bundleIdentifier: "com.apple.Safari", name: "Safari")
    static let textEdit = ScreencastCaptureContextReader.FrontApp(processIdentifier: 43, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    @Test("The context is the app in front and, for a browser while Accessibility is allowed, its page's domain")
    func readsTheAppAndTheBrowsersDomain() async {
        var asked: [pid_t] = []
        let context = await ScreencastCaptureContextReader.context(
            front: Self.safari,
            ownProcessIdentifier: 1,
            isBrowser: { $0 == "com.apple.Safari" },
            accessibilityTrusted: { true },
            pageAddress: { asked.append($0); return "https://github.com/serpcompany/keybumps" }
        )
        #expect(context == ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "github.com"))
        #expect(asked == [42])
    }

    @Test("Another app, or a browser without Accessibility, gives the app alone, and its windows aren't read")
    func noPageWithoutABrowserAndAccessibility() async {
        var asked = 0
        let notABrowser = await ScreencastCaptureContextReader.context(
            front: Self.textEdit, ownProcessIdentifier: 1,
            isBrowser: { $0 == "com.apple.Safari" }, accessibilityTrusted: { true },
            pageAddress: { _ in asked += 1; return "https://example.com/" }
        )
        #expect(notABrowser == ScreencastCaptureContext(appBundleIdentifier: "com.apple.TextEdit", appName: "TextEdit"))

        var trustChecks = 0
        let untrusted = await ScreencastCaptureContextReader.context(
            front: Self.safari, ownProcessIdentifier: 1,
            isBrowser: { _ in true }, accessibilityTrusted: { trustChecks += 1; return false },
            pageAddress: { _ in asked += 1; return "https://example.com/" }
        )
        #expect(untrusted == ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari"))
        #expect(trustChecks == 1, "it checks, and never asks")
        #expect(asked == 0)
    }

    @Test("Keybumps itself in front, or no app at all, gives no context")
    func noContextForKeybumps() async {
        var asked = 0
        for front in [Self.safari, nil] {
            let context = await ScreencastCaptureContextReader.context(
                front: front, ownProcessIdentifier: 42,
                isBrowser: { _ in true }, accessibilityTrusted: { true },
                pageAddress: { _ in asked += 1; return "https://example.com/" }
            )
            #expect(context == .none)
        }
        #expect(asked == 0)
    }

    @Test("Under the unit-test host the reader reads nothing")
    func unitTestHostReaderIsInert() async {
        #expect(UnitTestHost.isActive)
        #expect(await ScreencastCaptureContextReader.current.read() == .none)
    }

    // MARK: Remembered corrections

    @Test("With nothing remembered there's no guess")
    func noGuessAtFirst() {
        defer { folder.remove() }
        let memory = memory()
        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", domain: "github.com")) == nil)
        #expect(memory.guess(for: .none) == nil)
    }

    @Test("A correction is remembered for the website, else the app, and guessed next time, after a relaunch too")
    func remembersCorrections() throws {
        defer { folder.remove() }
        let keybumps = try Self.repository("serpcompany/keybumps")
        let serp = try Self.repository("serpcompany/serp")
        let memory = memory()
        memory.remember(keybumps, for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", domain: "keybumps.app"))
        memory.remember(serp, for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode"))

        let relaunched = self.memory()
        #expect(relaunched.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", domain: "keybumps.app"))
                == ScreencastRepositoryGuess(repository: keybumps, source: .website("keybumps.app")))
        #expect(relaunched.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.dt.Xcode"))
                == ScreencastRepositoryGuess(repository: serp, source: .app("com.apple.dt.Xcode")))
        #expect(relaunched.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", domain: "example.com")) == nil,
                "a correction on a website isn't the browser's")
        #expect(relaunched.stored.apps["com.apple.Safari"] == nil)
    }

    @Test("A website wins over its app, and a site's subdomains guess the site's repository")
    func websiteWinsOverApp() throws {
        defer { folder.remove() }
        let site = try Self.repository("serpcompany/keybumps")
        let browser = try Self.repository("serpcompany/browser-notes")
        let memory = memory()
        memory.remember(browser, for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome"))
        memory.remember(site, for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", domain: "keybumps.app"))

        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", domain: "staging.keybumps.app"))
                == ScreencastRepositoryGuess(repository: site, source: .website("keybumps.app")))
        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", domain: "news.example.com"))
                == ScreencastRepositoryGuess(repository: browser, source: .app("com.google.Chrome")))
        #expect(memory.guess(for: ScreencastCaptureContext(appBundleIdentifier: "com.google.Chrome", domain: "app"))?.source
                == .app("com.google.Chrome"), "a top-level name alone is never a site")
    }

    @Test("A later correction replaces the earlier one; a context with no app or website is remembered nowhere")
    func correctionsReplace() throws {
        defer { folder.remove() }
        let first = try Self.repository("serpcompany/one")
        let second = try Self.repository("serpcompany/two")
        let context = ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", domain: "keybumps.app")
        let memory = memory()
        memory.remember(first, for: context)
        memory.remember(second, for: context)
        #expect(memory.guess(for: context)?.repository == second)
        memory.remember(first, for: .none)
        #expect(memory.stored == ScreencastRepositoryMemory.Stored(websites: ["keybumps.app": second]))
    }

    @Test("The memory file is the person's alone, and one that can't be read starts the memory over")
    func storageFile() throws {
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent("repositories.json")
        memory().remember(try Self.repository("serpcompany/keybumps"), for: ScreencastCaptureContext(domain: "keybumps.app"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"keybumps.app\" : \"serpcompany/keybumps\""))

        try Data("not json".utf8).write(to: url)
        #expect(memory().stored == ScreencastRepositoryMemory.Stored())
    }

    @Test("Its default file is in Application Support through ProductPaths, so this run's own folder")
    func defaultLocation() {
        #expect(ScreencastRepositoryMemory.defaultStorageURL
                == ProductPaths.keybumps().applicationSupport.appendingPathComponent("screencast-repositories.json"))
        #expect(ScreencastRepositoryMemory.defaultStorageURL.path.hasPrefix(UnitTestHost.dataDirectory.path))
    }
}
