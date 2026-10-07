# Testing strategy

Decisions for how Keybumps is tested, researched against current sources on 2026-09-28. The evidence levels themselves (build, deterministic tests, UI tests, signed runtime, installed artifact, owner acceptance) are defined in [`development-workflow.md`](development-workflow.md); this document says which tools and runners produce each one.

## Levels and where they run

| Level | What it proves | Tooling | Where |
| --- | --- | --- | --- |
| Deterministic tests | Domain logic, state, adapter contracts, wiring snapshots, release scripts | Swift Testing (new) and XCTest (existing) in `KeybumpsTests` | Every PR that touches app code; locally before every hand-off; as the first gate of every release build |
| UI smoke tests | App launches; Settings, palette tabs, and editor open and respond | XCUITest in a `KeybumpsUITests` target, driven by launch arguments with faked permissions | Every PR that touches app code; as a gate of every release build; on demand |
| Signed runtime and installed artifact | Global hot keys, real permissions, cross-app paste/insertion, window movement, real screenshots | `apps/macos/scripts/build-qa-candidate.sh` plus a short manual checklist | Owner's Mac (agent first pass headless; screen only when handed over) |
| Owner acceptance | The scoped workflow works for the owner | Issue hit list | Owner's Mac |

No automated level substitutes for a higher one.

## Frameworks

- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`). This is Apple's current recommendation: WWDC26 "Migrate to Swift Testing" and the Xcode 27 release notes.
- **Existing XCTest tests stay.** Migrate a file only when you're already substantially changing it. Both frameworks share the `KeybumpsTests` target. As of Swift 6.4 / Xcode 27, each framework's assertions work inside the other.
- **XCTest remains required** for UI automation (XCUITest, the only first-party macOS UI automation), performance tests (`XCTMetric`), and code paths that raise Objective-C exceptions.
- Swift language mode stays 5.10 for now. Adopting Swift 6 (complete strict-concurrency checking first, test target before app) is separate work, not part of feature or refactor PRs.

## Wiring and characterization snapshots

- Structured snapshots, such as the capability wiring captured before the #53 refactor, are **hand-rolled Codable JSON fixtures** under `apps/macos/KeybumpsTests/Fixtures`: `JSONEncoder` with `.sortedKeys` and `.prettyPrinted`, compared as text, with the actual output attached (or printed as a diff) on mismatch.
- Re-recording happens only when `KEYBUMPS_RECORD_SNAPSHOTS=1` is set (`TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1` in `xcodebuild`'s environment, before the command), and a re-record is a reviewed change in the PR.
- No snapshot dependency for now. If image snapshots are ever needed, `pointfreeco/swift-snapshot-testing` (actively maintained, Swift Testing support) is the preferred library; adopting it is a separate decision.

## Making the app testable

Permission-gated and system-level features are faked in automated tests, never granted.

- **Permissions:** CI runners have SIP enabled, so Accessibility and Input Monitoring grants live in a system TCC database that can't be written. Ad-hoc builds change signature every build, and an un-granted Microphone or Files & Folders request raises a blocking system dialog. So every permission check, audio capture, event tap, and folder access goes through an injectable seam. UI tests pass `-KBUITestPermissions granted|denied` to select fakes. In the unit-test host, permission prompts, System Settings, and Dictation's paste step and system access are inert by default, and `PermissionPromptSourceTests` fails if a prompt API, keyboard-event posting, or a System Settings address appears outside its one allowed place. Dictation's microphone has no fake: tests start a session with `DictationService.beginSessionWithoutMicrophone(recording:)`, which does nothing outside the unit-test host.
- **Crash reports:** Sentry never starts in tests. Debug builds carry no destination, and `CrashReportingPolicy.destination` returns none in the unit-test host. `CrashReporterMachine` and the scrubber are pure, so their tests need no Sentry.
- **Entry points:** UI tests reach surfaces through launch arguments rather than global hot keys, e.g. `-KBOpenPalette <tab>`, `-KBOpenSettings <section>`, `-KBDisableHotKeys`, plus an on-disk sandbox wiped at each launch and a fresh defaults domain. Global hot-key routing is covered by unit tests (`GlobalShortcutCoordinator`) and the owner checklist.
- Every interactive control that tests touch gets an accessibility identifier. Animations are disabled under the test flag. The non-activating palette panel already returns `canBecomeKey = true`, which `typeText` needs.
- Tests never touch real user folders or the real pasteboard: inject readers, named pasteboards, and temporary directories, as the existing Screenshot Tools and Clipboard tests do. A test's `QuickSearchModel` gets supplied applications, its own `recentItems` and `applicationUsage` stores in a temporary folder, and `searchesFiles: false` (`QuickSearchModel.forTests(in:)`); `WiringHarness` passes `AppModel` one rooted in its folder. Under the unit-test host, Quick Search's defaults are isolated anyway: no app folder is listed, Spotlight never runs, and the stores default to `UnitTestHost.dataDirectory`, a per-run temporary folder, never the installed app's `recent-items.json` or `application-usage.json`. `QuickSearchTestIsolationTests` fails if that changes. Release a named pasteboard (`releaseGlobally()`) when the test is done, because it otherwise stays in the pasteboard server until logout.
- Unit tests and the UI-test composition keep sensitive snippets in `InMemorySnippetSecretStore` and paste with `InertTextPaster` (or a fake whose ⌘V is replaced), so no test touches the Keychain or posts ⌘V. Keyword expansion listens through `InertKeyTypingMonitor` there, so no test hears the keyboard.
- Tests never create a real preferences domain. Pass `InMemoryDefaults()` wherever a `UserDefaults` is needed: cfprefsd writes a removed suite's plist back to `~/Library/Preferences` after the test deletes it. `InMemoryDefaultsTests` fails if any test file calls `UserDefaults(suiteName:)`.
- A unit test can read a laid-out palette as VoiceOver does (`PaletteAccessibility` in `TranslateDetailTests`): SwiftUI builds its accessibility elements only while an assistive app asks, so the helper asks as one does (`AXEnhancedUserInterface`), and stops after. A palette laid out for testing never takes key focus (`refusesKeyForTesting`), so it can't take keystrokes typed in other apps. It also renders the laid-out palette to check the detail's hairlines in pixels, dark only, as below.
- Pixel checks of how a view is drawn (`PaletteFloatingSurfaceTests`) render an `NSHostingView` with `cacheDisplay` into a fixed-2x `NSBitmapImageRep`. The view sits in a borderless window that is never ordered in or made key, because `ImageRenderer` draws shapes itself and misses how Core Animation draws them in the app (a continuous capsule's layer border). They check dark mode only, where a pill's shadow barely changes the background; on a light background it's too strong for fixed thresholds. This isn't an image snapshot, so the snapshot-library decision above doesn't apply.
- Keybumps.app hosts the unit tests. Debug builds, and so every test host, use the bundle identifier `com.serp.keybumps.debug`; Release and Developer ID QA builds keep `com.serp.keybumps`. The installed app can therefore keep running during tests without sharing preferences, permissions, or quit requests with the host (a quit sent to `com.serp.keybumps` once ended test runs midway). Scripts that quit Keybumps match the `/Applications` copy by path, never by process name. Under XCTest, Debug builds also run a bare `NSApplication` instead of the app (`KeybumpsMain`), so the host never registers hot keys, a status item, or real pasteboard monitoring.
- Default locations are isolated under the unit-test host too, so a test that forgets to inject a store can't reach the owner's data (#191).
  - `UnitTestHost.isActive` is true only in a Debug build that XCTest loaded (`XCTestConfigurationFilePath` is set). Release builds, and so QA candidates, compile it as false, and a UI-test launch isn't a unit-test host.
  - Under that host, `ProductPaths.keybumps()` moves the owner's Application Support, Documents, and temporary folders into `UnitTestHost.dataDirectory`, a per-run temporary folder. So every default store stays in it: Dictation History, Clipboard History and its media, Shortcut Coach history, the Dictation recovery file, Dictation models, translated audio, and recent translations.
  - The UI-test sandbox (`ProductPaths.sandboxRoot`) still comes first.
  - A folder moves when it's the owner's folder or inside it, however it's spelled (a trailing slash, `/private/var`, a symlink). So a test's own rooted `FileManager` keeps only the folders it overrides with ones outside the owner's; its temporary folder, unless overridden, still moves.
  - `ScreenshotLocationResolver.system` reads no screenshot preference and uses a Desktop in the same folder.
  - `AppModel.defaultSymbolicHotKeyPreferences`, used by the Spotlight shortcut check and the Screenshot Tools takeover unless a composition injects preferences, is inert under that host, so no test can rewrite the owner's `com.apple.symbolichotkeys`.
  - `UnitTestDataIsolationTests` fails if a default goes back to the owner's folders. It checks the resolved paths with `#require` before building any store, so a regression stops the test before anything opens the owner's folders.
  - Tests still inject their own stores wherever the data matters to the test. The Whisper timing benchmark takes its model folder only from `KEYBUMPS_WHISPER_BENCHMARK_MODEL`, and the whisper.cpp one its model file from `KEYBUMPS_WHISPER_CPP_MODEL`. Pass them to the test host by setting `TEST_RUNNER_KEYBUMPS_WHISPER_BENCHMARK_MODEL=<folder>` or `TEST_RUNNER_KEYBUMPS_WHISPER_CPP_MODEL=<file>` (and `…_AUDIO` for a non-private WAV) in `xcodebuild`'s environment, before the command; after it they're build settings and don't reach the test host.

### UI test launch arguments

`UITestLaunchConfiguration` parses these; `AppModel.forLaunch()` in `apps/macos/Keybumps/App/UITestComposition.swift` builds the UI test composition. UI test mode exists only in Debug builds and starts only with `-KBUITestPermissions`; Release builds ignore every flag and don't compile the UI-test composition. (Inert seams such as `InertTextPaster` ship in every build, unused.) The other flags are ignored without it, so a production launch is unchanged (covered by `UITestLaunchConfigurationTests`).

| Argument | Effect |
| --- | --- |
| `-KBUITestPermissions granted\|denied` | Enters UI test mode and fakes every permission check (Accessibility, Input Monitoring, Microphone, Speech, Screen Recording) as all granted or all denied. It also swaps in an inert pointer event tap, a fake screenshot-folder reader (denied throws access-denied), an inert Spotlight resolver, and inert symbolic-hotkey preferences so macOS screenshot shortcuts are never touched. Dictation refuses audio capture before the microphone opens and never activates another app or synthesizes ⌘V. The Screenshot Editor saves into the sandbox. Data goes to a disposable `$TMPDIR/KeybumpsUITests` root (wiped at each launch), preferences to a wiped `com.serp.keybumps.uitests` suite with onboarding marked complete, and every pasteboard read and write goes to a private named pasteboard (`NSPasteboard.keybumps`). SwiftUI animations are off in the main window, the Command Palette, and the Screenshot Editor (`uiTestAnimationsDisabled()`). |
| `-KBOpenPalette <tab>` | Opens the Command Palette once, at launch, on `search`, `clipboard`, `screenshots`, `dictation`, `snippets`, `timers`, `emoji`, `translate`, or `keyboardShortcutter` (shown even while the Hotkeys tab is hidden) |
| `-KBOpenSettings <section>` | Opens Settings on a `SettingsSection` case name (`search`, `clipboard`, `screenshotTools`, `dictation`, `windows`, `keyboardShortcutter`, `snippets`, `timer`, `emojiPicker`, `translation`, `plugins`, `permissions`, `general`, `account`; a plugin's section opens that plugin's page) |
| `-KBCloseSettings YES` | With `-KBOpenPalette`, closes the Settings window before the palette opens, so a test can show that an action opens Settings (in UI test mode the window otherwise already exists at launch) |
| `-KBDisableHotKeys YES` | Registers shortcuts with an inert backend, so no Carbon hot keys are installed |
| `-KBLicenseState <state>` | Starts with a fixed license state: `active` (the default), `unlicensed`, or `revoked`. No Keychain or network access |
| `-KBUITestSeedClipboardImage YES` | Adds one generated PNG to the sandboxed Clipboard History |
| `-KBUITestSeedRecentKeybumps YES` | Adds the running app itself as the one sandboxed Quick Search Recent Item, which Quick Search must hide (the app under test isn't in `/Applications` for search to find) |
| `-KBUITestSeedSnippets YES` | Adds three made-up plain snippets to the sandboxed library, so a test can select several |

Give boolean flags an explicit `YES`. In CI, adding AppKit arguments (`-NSAutomaticWindowAnimationsEnabled NO -ApplePersistenceIgnoreState YES`) after a bare flag stopped the main window from appearing, so the smoke suite doesn't pass them.

Accessibility identifiers used by the suite are `settings.sidebar.<section>`, `settings.detail.<section>`, `capability.toggle.<capability>`, `palette.tab.<tab>`, `palette.settings` (the palette's Settings button), `quickSearch.command.<command>` (a Quick Search command row: `keybumpsSettings`, `plugins`, or a capability command's `Capability` ID such as `dictation`), `quickSearch.noRecentItems` (the empty search with no Recent Items to show), `palette.snippets.new` and `snippets.*` (the Snippets tab and editor), `palette.timers.new` and `palette.timers.row` (the Timers tab's rows), `settings.hero.byline` (a plugin page's byline), `plugin.<capability>.<key>` (a plugin's declared preference on its Settings page, such as `plugin.timer.ringsUntilStopped`; no test drives one yet), `settings.dictation.durationLimit` and `settings.dictation.language` (Dictation's dropdowns), `settings.visibleFrame` (UI-test mode only: the visible frame of the Settings window's screen as the app sees it, `minX,minY,width,height,primaryHeight` in AppKit coordinates; the #294 test checks the window against it. On CI it ends about 4pt inside the Dock's Accessibility frame, for a reason not yet known), `plugins.row.<section>` (a row of the Plugins page, which opens that plugin's page, whose switch is `capability.toggle.<capability>`), `plugins.browseWebsite` (its Browse on keybumps.app button, which no test drives because in UI-test mode it opens the browser), `timerAlarm.stop` and `timerAlarm.repeat` (the timer alarm's buttons), `shortcut.replacementPrompt`, `shortcut.replace`, and `shortcut.keep` (the question when a recorded shortcut is another action's, #334), `shortcut.moved.<owner>` (the note on the row that lost it, such as `shortcut.moved.window.upperLeft`), and, which no test drives yet because the Emoji Picker ships off and UI tests can't turn a plugin on at launch, `palette.emoji.cell`, `palette.emoji.row`, and `palette.emoji.selectedName` (the Emoji tab's grid, list, and highlighted emoji), and, as Translation ships off too, `palette.translate.empty`, `palette.translate.languages`, `palette.translate.targetMenu`, `palette.translate.swap`, `palette.translate.translation`, `palette.translate.failure`, `palette.translate.recent`, and `palette.translate.detail` with its `.translation`, `.source`, `.languages`, `.speechProblem`, `.copy`, `.paste`, `.readAloud`, and `.delete` (the Translate tab, a recent translation's row, and the highlighted one's detail, which `TranslateDetailTests` reads through accessibility), and `plugin.translation.clearRecent` (Translation's Clear Recent Translations); `capability.offBanner.requirement.<capability>` (a plugin page's "Requires macOS 15", which CI's macOS never shows); and the `commandPalette` and `screenshotEditor` windows.

## CI

- **Runner:** GitHub-hosted `macos-26` (arm64), pinning Xcode with `xcode-select`. Evaluate the `xcode-27` image labels separately before moving. macOS minutes cost about 10× Linux, so jobs set `timeout-minutes`.
- **When CI runs tests (owner decision, 2026-09-28):** on every pull request that touches app code (about 2 minutes of wall-clock time; the org's Enterprise plan includes 50,000 Actions minutes a month, and macOS counts 10×), and before every release build. No nightly schedule.
  - **App code** is `apps/macos/**`. Both workflows' `paths:` filters name that folder and the workflow file itself, and their steps run in it (`APP_DIR` in each workflow; `release.yml` has its own). The tests read only it and the release notes in `docs/releases/` (`UpdateVisibilityTests` parses every real file), so the unit-test filter names `docs/releases/v*.md` too.
  - **Release gate:** `release.yml` (Release Keybumps, from release-please or run manually) calls `keybumps-unit-tests.yml` and `keybumps-ui-tests.yml` first. The build, notarization, and publish jobs need both to pass.
  - **On demand:** either workflow can also be run from Actions (`workflow_dispatch`).
  - **Unit job:** the full `KeybumpsTests` suite with `CODE_SIGNING_ALLOWED=NO`, output through `xcbeautify` (preinstalled), and `-resultBundlePath` with the `.xcresult` uploaded on failure.
  - **UI job:** the whole `KeybumpsUITests` target (the `SmokeUITests`), ad-hoc signed (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=NO`), with `-retry-tests-on-failure -test-iterations 3`. Use the command-line flag; the test-plan retry setting is unreliable in Xcode 26.x. The #70 spike proved this path on image `20260907.0351.1`, and it then passed three consecutive runs. The UI tests have their own `KeybumpsUITests` scheme, so a local `xcodebuild test -scheme Keybumps` never drives the screen.
- **Hygiene:**
  - `build-for-testing` then `test-without-building`
  - cache SPM packages (`-clonedSourcePackagesDirPath`, keyed on `Package.resolved`), not DerivedData
  - unit and UI tests in separate jobs; macOS UI tests don't run in parallel
- **Known risk:** hosted-runner UI automation has broken on past image updates ("UI testing failed to initialize", automation-mode timeouts). A red UI job gets investigated against the runner image version before the app is blamed. Proven reference: kiwix-apple passes macOS XCUITest on `macos-26` (with a real signing certificate). The #70 spike proved the ad-hoc signed path.
- **Fallback if hosted UI tests stay flaky:** keep UI tests manual only, or add a self-hosted Apple Silicon runner with a logged-in session (owner decision: maintenance and security cost).

## Owner checklist (what automation can't prove)

For changes that touch capability wiring or system integration, the hand-off includes only these physical checks, about ten minutes:

1. Command-Space, Shift-Command-Space, and Option-Space from another app open or trigger the right surface.
2. A window shortcut and one drag-to-snap work on a normal app window.
3. Dictation inserts text into TextEdit; Escape cancels. With Keybumps's Accessibility turned off, the Dictation shortcut shows setup and no macOS alert appears.
4. Shift-Command-2/3/4 capture from another app (Shift-Command-3 opens the editor), the shot appears in ⌘3, Shift-Command-2/4 shots paste into another app right away (with Copy new screenshots to the clipboard on), two shots in a row paste the second, text copied while a Shift-Command-5 thumbnail is showing still pastes as that text, the editor's Save shows Copied to Clipboard at the notch and pastes into another app, and macOS's own Shift-Command-3/4 work again with Screenshot Tools off.
5. A Shortcut Coach action in Finder produces its notch notice; while Dictation is recording, the same action shows nothing in the notch but still appears in Shortcut Coach history.
6. A denied permission shows System Settings recovery.
7. Toggling a capability off and on in Settings stops and restores it.
8. Quit and relaunch keeps settings and histories.
9. On a QA candidate, `-KBTestCrash YES` (then relaunch, since the report is sent on the next launch) and `-KBTestFreeze YES` reach Sentry (`keybumps-mac`, environment `qa`); with Send crash reports off, nothing arrives. Report a Problem… sends a report that arrives with its details.

## Sources

- Apple, WWDC26 "Migrate to Swift Testing" (June 2026); Xcode 27 release notes (Sept 2026); WWDC25 "Record, replay, and review" (June 2025)
- Swift.org: Swift 6.4 (2026-09-15) and 6.3 (2026-03-24) release notes; Swift 6 concurrency migration guide
- pointfreeco/swift-snapshot-testing releases (1.19.6, 2026-09-21)
- actions/runner-images: macOS 26 arm64 image README (20260907), `configure-machine.sh`, issues #11874, #5410, #7621, #13143, #8214; discussions #7792, #65667, #175498
- GitHub changelog: `macos-26` GA (2026-02-26); `xcode-27` image labels preview (2026-07-16)
- kiwix/kiwix-apple `.github/workflows/ci.yml` (macOS UI tests on `macos-26`)
