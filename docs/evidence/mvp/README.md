# Functional MVP evidence

This directory records structural, non-private validation for the exact local build. Physical OS journeys remain explicitly distinct from deterministic tests.

## 2026-09-12 redundant native permission prompt removal

Owner runtime feedback showed Apple's `Device Control and Data Access` prompt appearing before SuperMac's custom Accessibility helper. Source tracing found the guided coordinator still invoked `AXIsProcessTrustedWithOptions(prompt: true)` for Accessibility and `CGRequestListenEventAccess()` for Input Monitoring, with two older detector/window entry points capable of invoking the same native requests. Accessibility and Input Monitoring recovery now uses only silent preflight APIs, the correct System Settings deep link, and the draggable SuperMac helper. Microphone and Speech Recognition retain their required native prompts. Focused routing tests passed, and a static search confirms no native Accessibility/Input Monitoring request calls remain. Fresh missing-permission runtime acceptance remains an owner step because resetting TCC state would alter system security settings.

## 2026-09-12 Rectangle-style settings and image Clipboard History

The owner supplied a current Rectangle Shortcuts Appshot and selected its compact two-column settings hierarchy as a bounded visual reference. SuperMac's Window Management screen now presents its own 30 supported actions in four exhaustive groups: primary positioning and sizing above a divider, fractional layouts below, with an original SwiftUI footprint diagram, working shortcut recorder, and clear control on every row. Signed-runtime inspection confirmed the two-column layout, assigned/unassigned states, status header, Restore Defaults, scrolling, and all 30 accessible action controls. Rectangle-only actions that SuperMac does not implement were not rendered as fake controls; exact pixel parity and the reference toolbar remain out of scope.

Clipboard History now captures PNG, JPEG, HEIC, GIF, and TIFF data up to 50 MB per item. Metadata stays in the bounded ten-entry JSON index while original image bytes are stored as separate local media files. The Clipboard palette shows a downsampled thumbnail, media label, and timestamp, and selecting the entry restores the original pasteboard type before pasting. Named-pasteboard tests proved capture, persisted reload, preview-file presence, exact byte restoration, media-file deletion, and backward-compatible loading of the earlier text-only JSON without reading or replacing the user's clipboard. The complete deterministic suite passed 104/104 and Debug and Release builds passed. Signed-runtime image-row acceptance remains pending until the owner copies a non-private image through the live app.

## 2026-09-12 Escape cancellation and menu Settings repair

Two owner-reported regressions were reproduced in the routing structure. The recording indicator advertised Escape cancellation, and `DefaultShortcut.cancelDictation` existed, but `AppModel` never registered it. SuperMac now registers bare Escape through the sole global shortcut coordinator only during Recording and Transcribing, routes it to `DictationService.cancel()`, and unregisters it before insertion, on idle/failure, and when Dictation is disabled. Deterministic coverage pins those phase boundaries, and a real Carbon registration test confirms macOS accepts the temporary unmodified Escape binding. Physical microphone cancellation remains owner acceptance.

The status item's Settings action previously posted a notification consumed by a listener inside the Settings window. Closing that window removed the listener, leaving the menu action inert. The status controller now retains a SwiftUI `openWindow` route configured while the initial scene is alive; the status menu's actual `NSMenuItem`, Dock reopen delegate, and Key Bumps menu panel use that persistent route. A regression invokes the real menu item and proves it reaches the retained opener. Closing the signed Debug window and reopening through the application route recreated Home; direct physical selection of the crowded status item remains owner acceptance. The complete deterministic suite passed 100/100, Debug and Release builds passed, and the Release bundle passed strict signing verification.

## 2026-09-12 Dictation and Clipboard History separation

Source tracing confirmed that completed Dictation uses the system pasteboard as temporary transport before sending Command-V, which previously allowed the Clipboard monitor to ingest the transcript into its separate history. Clipboard History now suppresses the exact pasteboard change produced by automatic Dictation insertion and by Paste from the Dictation tab. The suppression is one-change scoped: an ordinary later copy of identical text is captured normally, and the explicit Copy action remains ordinary clipboard activity. A named-pasteboard regression proves both the exclusion and subsequent capture without touching the user's clipboard.

## 2026-09-12 history interaction repair

The dedicated Dictation History screen and both Command Palette history tabs now share one native bordered Clear History control. Clipboard and Dictation bulk deletion each presents content-specific destructive confirmation and Cancel. Owner testing then exposed that the palette treated its own alert taking key-window focus—and clicks inside that alert—as outside interaction, dismissing the palette. `CommandPaletteController` now tracks the confirmation lifecycle and suppresses both resign-key and local-click dismissal while it is presented. A focused regression covers that policy. In signed runtime, Clear History opened the Clipboard confirmation, Cancel returned to the still-open populated palette, and no history mutation occurred. The complete deterministic suite passed 101/101 and Debug and Release builds passed. Dictation cards also make the complete padded header a SwiftUI `Button` target, add hover feedback, and expose an accessibility hint. Runtime accordion hit-area acceptance remains pending because the current signed app had no non-private Dictation entry available for interaction.

## 2026-09-12 Key Bumps product naming

The owner selected **Key Bumps** as the SuperMac name for the capability previously presented as Shortcut Coaching. Current user-facing capability titles, sidebar and navigation labels, permission explanations, empty/history states, test and clear actions, presentation descriptions, and accessibility copy use Key Bumps or the singular key bump. Historical references to the old Shortcut Coach donor app remain unchanged where needed for provenance. Internal persisted identifiers and the existing history filename also remain stable so this branding change does not reset settings or local history. A deterministic naming regression pins the canonical capability, sidebar, and permission copy. The full suite passed 96/96, Debug and Release builds passed, and signed-runtime accessibility inspection confirmed Key Bumps on Home, in the sidebar, as the settings title, on its enable switch, and on its test, clear-history, and history-section controls. No private history content was retained as evidence.

## 2026-09-12 per-recording dictation archive

Read-only black-box inspection of Superwhisper 2.18.3 confirmed 9,939 timestamp recording directories, each containing `meta.json` and `output.wav`. Only metadata key/type structure and WAV technical properties were inspected; private transcript values were not copied into repository evidence.

SuperMac now independently stores each completed recording under `~/Documents/SuperMac/recordings/<timestamp>/` with original minimal metadata and a playable WAV. Storage tests proved paired file creation, newest-first reload without a 25-entry cap, collision-safe timestamp naming, exact-directory deletion, and the absence of a monolithic `dictation-history.json` index.

The exact signed Debug app produced a real timestamp directory containing both files. `afinfo` verified the candidate audio as a playable mono WAVE file; its current native capture format is 44.1 kHz Float32, a deliberate implementation difference from the inspected reference's 16 kHz Int16 file. The dedicated History screen displayed the saved transcript card, duration, language, audio progress, copy, Finder reveal, and delete controls. Runtime search reached its no-results state, local play changed to Pause with advancing progress, natural completion returned to Play, relaunch reloaded the entry, and Reveal opened the exact timestamp directory in Finder. The full deterministic suite passed 89/89 after implementation. Full owner acceptance and unrelated completion-manifest rows remain unresolved.

## 2026-09-12 long dictation boundary

Source inspection confirmed the earlier build had no intentional maximum recording duration but used one live `SFSpeechRecognitionTask`, accepted its first final result as the session result, and used a fixed five-second finalization fallback. SuperMac now records one continuous WAV and starts an on-device `SFSpeechURLRecognitionRequest` only after capture stops. The default duration limit is five minutes and persisted settings expose 10, 15, 30, and 60 minutes plus No Limit. The transcription timeout scales to twice the recorded duration with a two-minute minimum, preventing indefinite Transcribing state without making longer recording choices cosmetic; failed transcription preserves the audio archive with an explicit failure marker.

A signed runtime recording produced a 9.7-second WAV. Completed-file transcription contained both the synthetic beginning and ending markers, and the generated verification directory was then moved to Trash. Deterministic tests cover the five-minute default, persistence of longer and unlimited choices, completed-file transcription strategy, and failed-transcription audio preservation.

## 2026-09-12 multi-span dictation assembly

An owner-provided 24.9-second recording reproduced a truncation where the saved transcript contained only the final seven words even though the WAV retained speech throughout. Privacy-safe callback instrumentation showed that Apple's on-device recognizer emitted 68 updates across three separate timestamp spans; the last callback covered only the final span. SuperMac had been replacing its transcript candidate on every update, so the final span overwrote the opening and middle spans.

SuperMac now detects recognition-span resets, retains completed spans, and joins them in callback/audio order before validation, persistence, and insertion. The regression fixture models the observed short reset callbacks between three synthetic spans and asserts that all three survive; a companion fixture prevents ordinary partial-result revisions from being duplicated. Replaying the original WAV through the repaired signed Debug app retained 51 recognized words from 0.39 through 24.87 seconds while Apple's final callback still contained only seven words. No spoken text, transcript value, or recording identifier was written into repository evidence. The full deterministic suite passed 106/106 after the repair.

## 2026-09-12 interrupted recording recovery and playback speed

GitHub issue #4 defines the crash-recovery, manual transcription, and playback-speed slice. SuperMac now writes pending lifecycle metadata before audio capture begins, keeps live recording/retry identifiers in memory so an ordinary History refresh cannot misclassify them, and converts stale recording/transcribing metadata into an interrupted entry after a new process launches. It also reconstructs metadata for a legacy audio-only directory when its WAV is playable. Intentional cancellation still removes its pending directory.

Interrupted and failed entries appear in both shared history-card surfaces with a local Transcribe action; a retry marks the same item as transcribing and then updates that item to completed or failed without replacing its audio. The shared audio player exposes bounded 0.5×, 0.75×, 1×, 1.25×, 1.5×, and 2× controls and applies rate changes to active playback. Deterministic tests cover live-session suppression, relaunch recovery, legacy-orphan recovery, same-item completion, intentional cancellation, rate bounds, and the earlier multi-span repair. The full suite passed 109/109, the Release build passed, and its app bundle passed strict signature verification. Physical force-quit recovery, manual retry, and audible speed changes remain owner acceptance.

## 2026-09-12 accordion history cards

The owner clarified the selected Superwhisper History hierarchy with a screenshot: collapsed rows are transcript previews, while one selected row expands to combine the full transcript with its audio and actions. SuperMac now uses that accordion structure with original styling. The first entry expands on entry to History, selecting another card collapses the prior selection, and the expanded card shows a real WAV-derived waveform, play/pause, progress, duration, an Original label, copy, Finder reveal/info, and delete. Segmented and reprocessing controls remain absent because SuperMac does not implement those capabilities.

The accordion state regression passed, the full deterministic suite passed 93/93, and signed runtime accessibility inspection confirmed exactly one expanded card with the audio/control region while peer cards remained collapsed. Private transcript text was redacted from verification output and no reference data was modified.

## 2026-09-12 native transcript translation

SuperMac adds an original Translate action to each expanded transcript card using Apple's custom `TranslationSession` on macOS 15 and newer. SuperMac presents the supported target-language picker and inline translated output while Apple manages on-device language-model availability and downloads. The original transcript and `meta.json` remain unchanged. macOS 14 shows an unavailable action rather than a fake control.

Runtime QA first rejected `translationPresentation` after its own privacy UI warned that selected content could be sent to Apple. That implementation was removed before commit. The replacement uses `TranslationSession`, which Apple documents as processing translation content on device. From the exact signed Debug app, the rich Command Palette Dictation card exposed Paste, Copy, Translate, info/reveal, delete, waveform, and playback controls. Translate opened the inline local panel, loaded compatible targets, and selected Japanese by default for an English recording. `LanguageAvailability` reported the English-to-Japanese pair as supported but not yet installed. No model download was accepted, so translated-output runtime acceptance remains pending; no transcript was replaced and private transcript text was redacted from verification output.

### Local translated-speech playback

The inline translation result now exposes Play Translation and Stop Audio. SuperMac selects an installed macOS speech voice by exact target locale when possible, then by base language, and stops synthesized speech when the target changes or the translation panel closes. The generated speech is played on demand and is not written into the per-recording archive. A deterministic regression covers exact-locale selection, base-language fallback, and the unavailable-voice result. Audible runtime acceptance remains pending because the translation model needed to produce the current target-language result was not installed during verification.

## 2026-09-12 SuperMac identity reset

The owner renamed the pre-release product to **SuperMac** and explicitly requested a fresh identity. The current signed artifact is `.derived/Build/Products/Debug/SuperMac.app` with bundle identifier `com.serp.supermac`. The repository, Xcode project, schemes, targets, module, executable, source/test roots, assets, and current documentation were subsequently normalized to the SuperMac name.

XcodeGen regeneration, all 85 deterministic tests, Debug build, and Release build passed after the rename. Strict deep code-sign verification passed for the Debug app with Team `847HR8U8D9`. The exact Debug artifact was launched and its running executable path was confirmed under `SuperMac.app`.

### Microphone prompt repair

Runtime reproduction showed the new SuperMac identity skipping the native microphone consent prompt and opening an unusable System Settings recovery screen because the hardened-runtime app lacked `com.apple.security.device.audio-input`. A signed-entitlement regression test failed before the repair and passed afterward. The exact rebuilt app then showed Apple's native `Allow “SuperMac.app” to access your microphone?` dialog without opening System Settings. The full deterministic suite passed 86/86, the Release build passed, and strict signature inspection confirmed the audio-input entitlement. The owner must still choose Allow and physically verify the subsequent Speech Recognition prompt and dictation session.

## 2026-09-12 local functional build

- Build: Xcode 27 generated and built the arm64 Debug app successfully.
- Identity: bundle identifier `com.serp.supermac`; display name `SuperMac`; strict deep code-sign verification passed with the owner's Apple Development identity.
- Deterministic tests: 70 tests passed, including donor Shortcut Coaching suites plus capability persistence, bounded clipboard retention, exact window-shortcut mapping, and selected window geometry.
- Initial UI runtime: the exact signed app launched, completed the original local onboarding, showed the nine-destination Settings sidebar, and persisted onboarding state across relaunch. The later readiness repair below supersedes that onboarding's development-license wording.
- Shortcut runtime: synthetic session keystrokes toggled the 680x502 Quick Search panel with Command-Space and the 620x462 Clipboard History panel with Shift-Command-Space. The Quick Search field accepted an Accessibility-driven query and returned Spotlight-indexed results. Result content was not retained because it contained private local filenames.
- Coaching delivery runtime: the signed app's Send Test action created a 360x73 top-right coaching toast and durable sample event.
- Permission-sensitive runtime still unproven here: physical microphone dictation/insertion, AX window movement and drag snap, physical Finder/Chrome coaching detection, login-session relaunch, and operation with all reference apps stopped.
- Installed artifact: not built or claimed; notarized packaging is Phase 7.

## Independent QA follow-up

An independent agent reviewed the initial MVP and found unsafe teardown/paste behavior plus incorrect drag-to-snap assumptions. The follow-up fixes cancel active Dictation when disabled, close disabled-capability panels, bind Escape through the shared shortcut coordinator, refuse blind pastes unless the captured destination becomes frontmost, preserve the last transcript for explicit recovery, require observed window movement before snapping, track restore frames per window, restore a snapped window's prior size when dragged away, and make Coaching Inbox/catalog content reachable.

After those changes, XcodeGen regeneration, Debug tests (70/70), the arm64 Release build, strict code-sign checks, `com.serp.supermac` identity, Team `847HR8U8D9`, and hardened runtime all passed again. Permission-sensitive physical workflows remain unproven as listed above.

A fresh post-fix Debug launch remained alive after Command-Space opened the 680x502 Quick Search panel, Command-Space dismissed it, Shift-Command-Space opened the 620x462 Clipboard History panel, and Escape dismissed that panel. Window dimensions were inspected without capturing result or clipboard content.

Screenshots in `runtime/` contain only SuperMac's onboarding and Home surfaces.

## 2026-09-12 readiness and permission repair

The original Home and Permissions screens were rejected during owner review because Home exposed raw capability switches without setup actions and the generic permission buttons appeared inert. A red-capable source audit reproduced both exact conditions before repair.

- Home is now a readiness dashboard. Each capability reports `Ready`, `Setup Needed`, or `Off` and provides a real `Open`, `Grant Permission`, `Settings`, or `Set Up` action. Enable/disable controls live in the individual capability screens.
- Permission state now distinguishes not-requested, required, denied, restricted, and granted where the public macOS APIs expose those states. Microphone and Speech Recognition use their native consent APIs. Accessibility and Input Monitoring invoke their native request APIs and open the matching Privacy & Security pane whenever macOS still requires user action.
- From the exact signed Debug app, Home's permission action navigated to Permissions. Accessibility recovery made System Settings frontmost on the Accessibility pane with SuperMac listed; Input Monitoring opened its exact pane and exposed macOS's Add control. No TCC switch was changed by the agent.
- Quick Search and Clipboard History opened real 680x502 and 620x462 panels from Home and dismissed with Escape while the app remained alive.
- Window shortcut controls now support recording, clearing with Delete, cancelling with Escape, persistence, duplicate reassignment, and restoring the selected Rectangle defaults. Signed runtime inspection confirmed other shortcut buttons suspend during recording and restore after Escape.
- Presentation previews bypass durable Coaching Inbox storage. Explicit test events still use the real delivery and history path.
- Dictation's language selector now lists every locale for which Apple's recognizer reports on-device support on the current Mac.
- Development-license and fake update actions are not presented. The local preview states that updates are not configured; the menu item is visibly disabled.
- XcodeGen regeneration passed. The final Debug test run passed 74/74 tests. Debug and arm64 Release builds passed. Both bundles passed strict deep code-sign verification with bundle identifier `com.serp.supermac`, Team `847HR8U8D9`, and hardened runtime.
- Final signed Debug artifact: `.derived/Build/Products/Debug/SuperMac.app`.
- `runtime/repaired-home.png` is a window-only capture of the final signed readiness dashboard; it contains no search, clipboard, transcript, or filename content.

Permission-sensitive owner steps remain: choose or add SuperMac in macOS Privacy & Security, respond to the Microphone and Speech Recognition prompts, then physically verify dictation/insertion, every selected window action and drag region, and Finder/Chrome coaching. These steps require the owner's consent and are not replaced by deterministic tests.

## 2026-09-12 unified Command Palette

The owner requested one Alfred/Raycast-inspired launcher surface with three tabs: Search by default, Clipboard History, and Dictation History. This is a bounded interaction and hierarchy reference, not a claim of reference-product parity.

- `CommandPaletteController` now owns one 760×520 borderless material panel for all three modes. The previous separate Quick Search and Clipboard panel controllers were removed.
- Search, Clipboard, and Dictation tabs are visible together and switch with clicks or Command-1/2/3. Switching preserves immediate text-input focus.
- Command-Space routes to Search in the application model; Shift-Command-Space routes to Clipboard. The Dictation settings screen opens the third tab.
- Search retained real local Spotlight-backed results. In signed runtime, typing `Safari` produced the installed Safari application result and Return opened Safari.
- Clipboard displayed the existing ten-item local store inside the unified palette. Its live content contained private user text, so no Clipboard screenshot was retained.
- This paragraph records the earlier monolithic transcript-only implementation. The later per-recording archive evidence below supersedes its persistence design.
- The earlier deterministic suite passed 76/76 tests, including tab order/default state and the then-current bounded Dictation History persistence.
- `scripts/build-and-run.sh` was corrected to launch the actual `SuperMac.app` product path.

Privacy-safe artifacts:

- `runtime/reference-alfred-empty.png` — installed Alfred 5.7.3 empty launcher reference.
- `runtime/command-palette-search.png` — SuperMac Search empty state with immediate input focus.
- `runtime/command-palette-search-result.png` — SuperMac real Safari result.
- `runtime/command-palette-dictation.png` — SuperMac Dictation History empty state.

The palette keeps SuperMac branding and differs deliberately from both references: three explicit peer tabs, local-only labeling, SuperMac iconography, and no proprietary Alfred/Raycast features. Direct global-hotkey routing was not re-exercised through Computer Use because targeted synthetic key input did not traverse the Carbon global-hotkey path; the application wiring and prior shortcut runtime evidence remain supporting evidence, not a fresh physical-hotkey claim.

## 2026-09-12 draggable permission helper

The owner supplied a HeyClicky 1.0.48 reference screenshot showing a low-friction Accessibility setup: System Settings opens to the correct list and a floating helper presents the signed app as a draggable row. SuperMac now implements that bounded interaction with original visuals and copy.

- Accessibility and Input Monitoring show `Add SuperMac…`; Microphone and Speech Recognition retain native `Request Access…` behavior.
- The signed Debug app opened Accessibility to the macOS `Device Control and Data Access` list and Input Monitoring to its exact app list.
- A separate 620×162 nonactivating panel remained visible after System Settings became frontmost. An initial runtime pass caught and fixed `NSPanel` hiding on app deactivation.
- The panel says `Drag SuperMac into the list above`, names the requested permission, provides `Open Again`, and presents the real app icon/name as one draggable row.
- `ApplicationBundleDragPayload` writes `Bundle.main.bundleURL` as a public file URL. A deterministic pasteboard test round-tripped the actual signed test-host bundle URL.
- A classification test proves only Accessibility and Input Monitoring use the drag helper.
- After owner review, the draggable row now contains only the app icon and name; the repeated inner drag instruction was removed.
- The helper now dismisses when AppKit reports an accepted drop and remains visible after a cancelled or rejected drag, so a failed attempt can be retried without reopening setup.
- Further owner review removed the remaining outer permission header and `Open Again` action. The helper is now one compact draggable card with a single instruction, a small close control, an open-hand cursor that closes when grabbed, hover highlighting, and a visible hand-drag affordance.
- The final deterministic suite passed 79/79 tests, including the accepted-versus-cancelled drop policy.

Evidence:

- Reference: `docs/app-replica/evidence/heyclicky-1.0.48/reference/permission-drag-helper.png`
- Candidate: `docs/app-replica/evidence/heyclicky-1.0.48/candidate/permission-drag-helper.png`

The agent did not drop the bundle or toggle either permission because that changes macOS security state. The user must perform that consent step; source tests, the AppKit completion callback, and panel visibility do not substitute for a successful human drag into System Settings.

## 2026-09-12 guided permission journey and journey ledger

- The onboarding permission step and the persistent Permissions screen now present one missing required permission at a time with completed/total progress.
- The order is Accessibility, Input Monitoring, Microphone, then Speech Recognition. Already-granted permissions and permissions used only by disabled capabilities are skipped.
- Returning to SuperMac refreshes the public macOS permission APIs; the walkthrough then advances to the next missing permission without requiring the user to find it in a list.
- The full individual-permission recovery list remains available behind a collapsed disclosure.
- The exact signed Debug app showed `1 of 4 complete` with Accessibility as the current step on this Mac, while correctly recognizing Input Monitoring as already granted. Home opened the Search tab with immediate input focus, and Escape returned to Home.
- Permission ordering, skip behavior, progress, settings URLs, native-versus-drag recovery classification, drag payload, and accepted-drop dismissal have deterministic coverage.
- The complete deterministic suite passed 80/80 tests; Debug and arm64 Release builds passed and both bundles satisfied strict deep code-sign verification.
- The canonical flow and acceptance ledger is [`docs/product/user-journeys.md`](../../product/user-journeys.md).

No permission was granted, revoked, or toggled during this verification. The four-step completion journey remains an owner acceptance item.

## 2026-09-12 Settings navigation and direct permission entry

- Settings now keeps a bounded in-window navigation history. The toolbar Back button and Command-[ return to the previously visited sidebar destination without adding a navigation loop.
- Signed-runtime inspection navigated Home → Dictation → Back and returned to Home; the Back button was disabled when no earlier destination remained.
- Home's Grant Permission actions no longer navigate to the Permissions screen. They resolve to a capability-specific sequence: Dictation requests Microphone then Speech Recognition, Window Management requests Accessibility, and Shortcut Coaching requests Accessibility then Input Monitoring.
- Permission sequencing continues when the app refreshes its public macOS permission state. No permission was toggled during this check.
- The complete deterministic suite passed 82/82 tests after these changes; the arm64 Release build passed.

## 2026-09-12 Dictation hotkey and editable shortcut repair

- A red regression reproduced the apparent no-op: missing Dictation permissions routed into `DictationService`, which entered a failed phase while `DictationIndicatorController` deliberately hid failed phases.
- The Dictation shortcut now shows an app-owned setup explanation when Microphone or Speech Recognition is missing. Its explicit Set Up Dictation action starts the capability-specific permission walkthrough; once permissions are available, the same shortcut toggles recording as before.
- Non-permission Dictation startup failures now show an orange error indicator for five seconds instead of disappearing silently.
- Quick Search, Clipboard History, and Dictation settings each expose Record, Clear, and Restore Default. Every Window Management action exposes Record and Clear alongside the existing Restore Defaults action.
- Capability shortcut bindings persist locally. Reassigning a combination removes it from any previous capability or window action before all active registrations are rebuilt.
- Signed-runtime inspection confirmed the controls on all four shortcut-owning settings areas. Dictation recording mode disabled Clear, and Escape cancelled recording and restored the shortcut without changing the saved binding.
- The complete deterministic suite passed 84/84 tests, including the original red Dictation routing regression and capability shortcut default, clear, persistence, and reassignment coverage. Debug and arm64 Release builds passed.

## 2026-09-12 Dictation permission-context repair

- Owner runtime feedback caught a remaining confusing branch: a denied Microphone or Speech Recognition permission could open System Settings with no SuperMac explanation.
- A red regression now requires every System Settings recovery branch to select a visible assistant: the draggable app card for Accessibility/Input Monitoring and a `Turn on … for SuperMac` switch card for Microphone/Speech Recognition.
- Dictation's hotkey no longer opens System Settings by itself when setup is incomplete. It first shows a SuperMac card listing the missing permissions and requires an explicit Set Up Dictation action before continuing.
- Switch guidance is created before macOS takes focus so it remains visible above the correct Privacy & Security pane.
- Permission helpers now share the same card anatomy: the real SuperMac icon, `SuperMac` title, one instruction line, matching metrics/background, trailing action affordance, and close control. Accessibility/Input Monitoring say `Drag this card into the app list above`; Microphone/Speech say `Turn on the … switch in the list above.` because those macOS panes have no Add button and do not accept app-bundle drops.
