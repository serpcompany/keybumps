# Functional MVP evidence

This directory records structural, non-private validation for the exact local build. Physical OS journeys remain explicitly distinct from deterministic tests.

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
- `DictationHistoryService` persists the latest 25 completed transcripts with language and timestamp. Dictation records a transcript before attempting insertion, so failed pastes remain visible in history and recovery.
- The final deterministic suite passed 76/76 tests, including tab order/default state and bounded Dictation History persistence.
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
