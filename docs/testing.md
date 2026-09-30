# Testing strategy

Decisions for how Keybumps is tested, researched against current sources on 2026-09-28. The evidence levels themselves (build, deterministic tests, UI tests, signed runtime, installed artifact, owner acceptance) are defined in [`development-workflow.md`](development-workflow.md); this document says which tools and runners produce each one.

## Levels and where they run

| Level | What it proves | Tooling | Where |
| --- | --- | --- | --- |
| Deterministic tests | Domain logic, state, adapter contracts, wiring snapshots, release scripts | Swift Testing (new) and XCTest (existing) in `KeybumpsTests` | Every PR that touches app code; locally before every hand-off; as the first gate of every release build |
| UI smoke tests | App launches; Settings, palette tabs, and editor open and respond | XCUITest in a `KeybumpsUITests` target, driven by launch arguments with faked permissions | Every PR that touches app code; as a gate of every release build; on demand |
| Signed runtime and installed artifact | Global hot keys, real permissions, cross-app paste/insertion, window movement, real screenshots | `scripts/build-qa-candidate.sh` plus a short manual checklist | Owner's Mac (agent first pass headless; screen only when handed over) |
| Owner acceptance | The scoped workflow works for the owner | Issue hit list | Owner's Mac |

No automated level substitutes for a higher one.

## Frameworks

- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`). This is Apple's current recommendation: WWDC26 "Migrate to Swift Testing" and the Xcode 27 release notes.
- **Existing XCTest tests stay.** Migrate a file only when you're already substantially changing it. Both frameworks share the `KeybumpsTests` target. As of Swift 6.4 / Xcode 27, each framework's assertions work inside the other.
- **XCTest remains required** for UI automation (XCUITest, the only first-party macOS UI automation), performance tests (`XCTMetric`), and code paths that raise Objective-C exceptions.
- Swift language mode stays 5.10 for now. Adopting Swift 6 (complete strict-concurrency checking first, test target before app) is separate work, not part of feature or refactor PRs.

## Wiring and characterization snapshots

- Structured snapshots, such as the capability wiring captured before the #53 refactor, are **hand-rolled Codable JSON fixtures** under `KeybumpsTests/Fixtures`: `JSONEncoder` with `.sortedKeys` and `.prettyPrinted`, compared as text, with the actual output attached (or printed as a diff) on mismatch.
- Re-recording happens only when `KEYBUMPS_RECORD_SNAPSHOTS=1` is set, and a re-record is a reviewed change in the PR.
- No snapshot dependency for now. If image snapshots are ever needed, `pointfreeco/swift-snapshot-testing` (actively maintained, Swift Testing support) is the preferred library; adopting it is a separate decision.

## Making the app testable

Permission-gated and system-level features are faked in automated tests, never granted.

- **Permissions:** CI runners have SIP enabled, so Accessibility and Input Monitoring grants live in a system TCC database that can't be written. Ad-hoc builds change signature every build, and an un-granted Microphone or Files & Folders request raises a blocking system dialog. So every permission check, audio capture, event tap, and folder access goes through an injectable seam. UI tests pass `-KBUITestPermissions granted|denied` to select fakes.
- **Entry points:** UI tests reach surfaces through launch arguments rather than global hot keys, e.g. `-KBOpenPalette <tab>`, `-KBOpenSettings <section>`, `-KBDisableHotKeys`, plus in-memory stores and a fresh defaults domain. Global hot-key routing is covered by unit tests (`GlobalShortcutCoordinator`) and the owner checklist.
- Every interactive control that tests touch gets an accessibility identifier. Animations are disabled under the test flag. The non-activating palette panel already returns `canBecomeKey = true`, which `typeText` needs.
- Tests never touch real user folders or the real pasteboard: inject readers, named pasteboards, and temporary directories, as the existing Screenshot Tools and Clipboard tests do. Release a named pasteboard (`releaseGlobally()`) when the test is done, because it otherwise stays in the pasteboard server until logout.
- Tests never create a real preferences domain. Pass `InMemoryDefaults()` wherever a `UserDefaults` is needed: cfprefsd writes a removed suite's plist back to `~/Library/Preferences` after the test deletes it. `InMemoryDefaultsTests` fails if any test file calls `UserDefaults(suiteName:)`.
- Keybumps.app hosts the unit tests. Debug builds, and so every test host, use the bundle identifier `com.serp.keybumps.debug`; Release and Developer ID QA builds keep `com.serp.keybumps`. The installed app can therefore keep running during tests without sharing preferences, permissions, or quit requests with the host (a quit sent to `com.serp.keybumps` once ended test runs midway). Scripts that quit Keybumps match the `/Applications` copy by path, never by process name. Under XCTest, Debug builds also run a bare `NSApplication` instead of the app (`KeybumpsMain`), so the host never registers hot keys, a status item, or real pasteboard monitoring.

### UI test launch arguments

`UITestLaunchConfiguration` parses these; `AppModel.forLaunch()` in `Keybumps/App/UITestComposition.swift` builds the UI test composition. UI test mode exists only in Debug builds and starts only with `-KBUITestPermissions`; Release builds ignore every flag and compile none of the fakes. The other flags are ignored without it, so a production launch is unchanged (covered by `UITestLaunchConfigurationTests`).

| Argument | Effect |
| --- | --- |
| `-KBUITestPermissions granted\|denied` | Enters UI test mode and fakes every permission check (Accessibility, Input Monitoring, Microphone, Speech, Screen Recording) as all granted or all denied. It also swaps in an inert pointer event tap, a fake screenshot-folder reader (denied throws access-denied), an inert Spotlight resolver, and inert symbolic-hotkey preferences so macOS screenshot shortcuts are never touched. Dictation refuses audio capture before the microphone opens and never activates another app or synthesizes ⌘V. The Screenshot Editor saves into the sandbox. Data goes to a disposable `$TMPDIR/KeybumpsUITests` root (wiped at each launch), preferences to a wiped `com.serp.keybumps.uitests` suite with onboarding marked complete, and every pasteboard read and write goes to a private named pasteboard (`NSPasteboard.keybumps`). SwiftUI animations are off at every hosting root (`uiTestAnimationsDisabled()`). |
| `-KBOpenPalette <tab>` | Opens the Command Palette once, at launch, on `search`, `clipboard`, `screenshots`, `dictation`, or `keyboardShortcutter` (shown even while the Hotkeys tab is hidden) |
| `-KBOpenSettings <section>` | Opens Settings on a `SettingsSection` case name (`search`, `clipboard`, `screenshotTools`, `dictation`, `windows`, `keyboardShortcutter`, `permissions`, `general`) |
| `-KBDisableHotKeys YES` | Registers shortcuts with an inert backend, so no Carbon hot keys are installed |
| `-KBLicenseState <state>` | Starts with a fixed license state: `active` (the default), `unlicensed`, or `revoked`. No Keychain or network access |
| `-KBUITestSeedClipboardImage YES` | Adds one generated PNG to the sandboxed Clipboard History |

Give boolean flags an explicit `YES`. In CI, adding AppKit arguments (`-NSAutomaticWindowAnimationsEnabled NO -ApplePersistenceIgnoreState YES`) after a bare flag stopped the main window from appearing, so the smoke suite doesn't pass them.

Accessibility identifiers used by the suite are `settings.sidebar.<section>`, `settings.detail.<section>`, `capability.toggle.<capability>`, `palette.tab.<tab>`, and the `commandPalette` and `screenshotEditor` windows.

## CI

- **Runner:** GitHub-hosted `macos-26` (arm64), pinning Xcode with `xcode-select`. Evaluate the `xcode-27` image labels separately before moving. macOS minutes cost about 10× Linux, so jobs set `timeout-minutes`.
- **When CI runs tests (owner decision, 2026-09-28):** on every pull request that touches app code (about 2 minutes of wall-clock time; the org's Enterprise plan includes 50,000 Actions minutes a month, and macOS counts 10×), and before every release build. No nightly schedule.
  - **Release gate:** `release.yml` (Release Keybumps, from release-please or run manually) calls `keybumps-unit-tests.yml` and `keybumps-ui-tests.yml` first. The build, notarization, and publish jobs need both to pass.
  - **On demand:** either workflow can also be run from Actions (`workflow_dispatch`).
  - **Unit job:** the full `KeybumpsTests` suite with `CODE_SIGNING_ALLOWED=NO`, output through `xcbeautify` (preinstalled), and `-resultBundlePath` with the `.xcresult` uploaded on failure.
  - **UI job:** the whole `KeybumpsUITests` target (today the 5 `SmokeUITests`), ad-hoc signed (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=NO`), with `-retry-tests-on-failure -test-iterations 3`. Use the command-line flag; the test-plan retry setting is unreliable in Xcode 26.x. The #70 spike proved this path on image `20260907.0351.1`, and it then passed three consecutive runs. The UI tests have their own `KeybumpsUITests` scheme, so a local `xcodebuild test -scheme Keybumps` never drives the screen.
- **Hygiene:**
  - `build-for-testing` then `test-without-building`
  - cache SPM packages (`-clonedSourcePackagesDirPath`, keyed on `Package.resolved`), not DerivedData
  - unit and UI tests in separate jobs; macOS UI tests don't run in parallel
- **Known risk:** hosted-runner UI automation has broken on past image updates ("UI testing failed to initialize", automation-mode timeouts). A red UI job gets investigated against the runner image version before the app is blamed. Proven reference: kiwix-apple passes macOS XCUITest on `macos-26` (with a real signing certificate). The ad-hoc signed path must be proven by a spike first.
- **Fallback if hosted UI tests stay flaky:** keep UI tests manual only, or add a self-hosted Apple Silicon runner with a logged-in session (owner decision: maintenance and security cost).

## Owner checklist (what automation can't prove)

For changes that touch capability wiring or system integration, the hand-off includes only these physical checks, about ten minutes:

1. Command-Space, Shift-Command-Space, and Option-Space from another app open or trigger the right surface.
2. A window shortcut and one drag-to-snap work on a normal app window.
3. Dictation inserts text into TextEdit; Escape cancels.
4. Shift-Command-2/3/4 capture from another app (Shift-Command-3 opens the editor), the shot appears in ⌘3, Done shows Copied to Clipboard at the notch and pastes into another app, and macOS's own Shift-Command-3/4 work again with Screenshot Tools off.
5. A Shortcut Coach action in Finder produces its notch notice; while Dictation is recording, the same action shows nothing in the notch but still appears in Shortcut Coach history.
6. A denied permission shows System Settings recovery.
7. Toggling a capability off and on in Settings stops and restores it.
8. Quit and relaunch keeps settings and histories.

## Sources

- Apple, WWDC26 "Migrate to Swift Testing" (June 2026); Xcode 27 release notes (Sept 2026); WWDC25 "Record, replay, and review" (June 2025)
- Swift.org: Swift 6.4 (2026-09-15) and 6.3 (2026-03-24) release notes; Swift 6 concurrency migration guide
- pointfreeco/swift-snapshot-testing releases (1.19.6, 2026-09-21)
- actions/runner-images: macOS 26 arm64 image README (20260907), `configure-machine.sh`, issues #11874, #5410, #7621, #13143, #8214; discussions #7792, #65667, #175498
- GitHub changelog: `macos-26` GA (2026-02-26); `xcode-27` image labels preview (2026-07-16)
- kiwix/kiwix-apple `.github/workflows/ci.yml` (macOS UI tests on `macos-26`)
