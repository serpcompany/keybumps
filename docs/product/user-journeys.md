# SuperMac MVP user journeys

This is the acceptance ledger for the functional MVP described in [`mvp-prd.md`](mvp-prd.md). It documents what a person does, what the app must do, and how strongly that behavior has been verified.

## Verification vocabulary

- **Runtime verified** — directly observed in the exact signed local Debug app.
- **Automated** — deterministic tests verify state, routing, persistence, or geometry, but not the complete macOS interaction.
- **Owner check required** — completing the journey changes a macOS permission, reads private user content, records audio, moves another app's window, or requires a physical global shortcut. An agent must not report this as complete from code or tests alone.
- **Deferred** — intentionally outside the functional pre-commerce MVP.

Build success, tests, UI inspection, signed runtime, installed artifact, and owner acceptance are separate claims. The detailed run log lives in [`../evidence/mvp/README.md`](../evidence/mvp/README.md).

## Journey status

| ID | Journey | Current evidence | Remaining acceptance |
| --- | --- | --- | --- |
| UJ-01 | First launch and onboarding | Runtime verified for the signed local build; onboarding completion persistence is automated. | Fresh installed-artifact run remains deferred until packaging. |
| UJ-02 | Guided permission setup | Runtime verified for the ordered current-step UI and Accessibility helper; ordering, skipping, progress, URLs, drag payload, and accepted-drop dismissal are automated. | Owner must grant each permission and observe all four steps advance to completion. |
| UJ-03 | Home readiness and recovery | Runtime verified for truthful Ready/Setup Needed states and working navigation/open actions. | Recheck after all permissions are granted. |
| UJ-04 | Quick Search | Runtime verified for opening, focus, a real installed-app result, launch, and Escape dismissal; palette state is automated. | Physical `Command-Space`, file/folder open, Command-Return reveal, outside-click dismissal, and focus return need owner acceptance. |
| UJ-05 | Clipboard History | Signed runtime panel opening and bounded local-store behavior are verified; retention, duplicate collapse, and persistence are automated. | Private-content selection/paste, deletion, clearing, restart, and disabled monitoring need owner acceptance. |
| UJ-06 | Dictation and Dictation History | Language availability, per-recording metadata/audio persistence, reload ordering, deletion, cancellation/teardown paths, and recovery state have automated coverage. | English/Japanese speech, browser insertion, offline operation, failed-insertion recovery, and full History control acceptance still need owner verification. |
| UJ-07 | Window Management | Exact selected shortcut map, customization, persistence, representative geometry, drag guards, and restore behavior are automated; shortcut recording UI has signed-runtime evidence. | Every assigned shortcut, repeated sizing, multi-display movement, and every drag-to-snap/unsnap region need owner acceptance with Accessibility enabled. |
| UJ-08 | Shortcut Coaching | Detection rules, suppression, durable history, unread state, channel fan-out, previews, and presentation geometry are automated; a synthetic runtime event was observed. | Physical supported Finder and Chrome actions plus selected live presentation channels need owner acceptance with both permissions enabled. |
| UJ-09 | Shared Command Palette | Runtime verified for the Search surface and Escape; Search/Clipboard/Dictation tab order and reset behavior are automated. | Physical global routing and privacy-safe checks of Clipboard/Dictation selection and paste remain. |
| UJ-10 | Capability controls and settings | Enablement persistence, shortcut release, teardown, and major settings routes are automated or runtime inspected. | Owner should confirm the combined app remains understandable during normal daily use. |
| UJ-11 | Dock, menu bar, conflicts, and launch at login | Dock/sidebar shell and status-item contract are automated or runtime verified; conflict detection is implemented. | Login-session relaunch, crowded-menu-bar visibility, and quitting each reference app from onboarding need owner acceptance. |
| UJ-12 | Updates, licensing, and distribution | The local preview truthfully reports that updates are not configured and contains no fake activation. | Production licensing, update feed, notarization, packaging, installed artifact, and distribution are deferred. |

## UJ-01 — First launch and onboarding

Precondition: no completed-onboarding preference for `com.serp.supermac`.

1. Launch SuperMac.
2. Read the local-preview welcome; no fake license control is shown.
3. Review the five enabled capabilities.
4. Complete or skip the guided permission sequence.
5. Review running Alfred, Rectangle, and Superwhisper conflicts; optionally quit the running process without uninstalling it or deleting its data.
6. Finish onboarding.
7. The Settings window opens to Home and subsequent launches do not repeat onboarding.

Expected recovery: a skipped permission keeps the related feature enabled but marks it Setup Needed and exposes a real recovery action.

## UJ-02 — Guided permission setup

The required order is Accessibility, Input Monitoring, Microphone, then Speech Recognition. Permissions already granted—or needed only by disabled capabilities—are skipped.

1. The walkthrough shows one missing permission and `completed of total` progress.
2. Accessibility or Input Monitoring opens the exact System Settings list and shows the compact draggable SuperMac card.
3. The drag card dismisses only after an accepted drop; a cancelled drag remains retryable.
4. The user enables SuperMac in macOS and returns to the app.
5. App activation refreshes the real permission state and automatically presents the next missing step.
6. Microphone and Speech Recognition use their native consent prompts. Denied permissions route to the matching System Settings pane.
7. Completion reads: `All permissions needed by your enabled features are ready.`

The Permissions screen keeps `Review individual permissions` collapsed by default so guided setup is primary while individual recovery remains available.

## UJ-03 — Home readiness and recovery

1. Open Home from the Dock, menu bar Settings item, or sidebar.
2. Each capability reports Ready, Setup Needed, or Off from actual capability and permission state.
3. Quick Search and Clipboard open directly when ready.
4. A feature's Grant Permission action begins that feature's permission sequence immediately without navigating away from Home.
5. Ready Dictation, Window Management, and Shortcut Coaching route to their settings.
6. Off features route to their capability screen, where they can be enabled.

## UJ-04 — Quick Search

1. Press the configured Quick Search shortcut (`Command-Space` by default), or choose Open Quick Search from Home/Quick Search settings.
2. Search opens on the Search tab with immediate input focus.
3. Type an app, local file, or folder name.
4. Use arrow keys to select a result.
5. Press Return to open it, or Command-Return to reveal it in Finder.
6. Press Escape or click outside to dismiss without opening.

Disabling Quick Search closes its panel and releases its configured shortcut.

## UJ-05 — Clipboard History

1. Copy text in ordinary applications while Clipboard History is enabled.
2. Press the configured Clipboard History shortcut (`Shift-Command-Space` by default), or open Clipboard History from Home/settings.
3. The shared palette opens on Clipboard with the newest item first and at most ten items.
4. Filter the local history, select an item, and paste it into the previously focused destination when safe.
5. Delete an item or clear all history from settings.
6. Disable Clipboard History to stop monitoring and release its shortcut without silently erasing retained items.

Clipboard content stays local. Recent copied secrets remain until removed or displaced, so committed screenshots and logs must not contain item text.

## UJ-06 — Dictation and Dictation History

1. Choose an available on-device recognition language in Dictation settings.
2. Place the cursor in another app and press the configured Dictation shortcut (`Option-Space` by default).
3. A visible Recording indicator appears while audio is captured.
4. Recording automatically stops at the selected duration limit—five minutes by default—or the user presses the configured Dictation shortcut again to stop sooner.
5. SuperMac transcribes the completed local WAV and inserts the result at the original cursor; pressing Escape cancels without insertion.
6. The transcript and captured audio are saved under `~/Documents/SuperMac/recordings/<timestamp>/` as `meta.json` and `output.wav` before insertion is attempted. A failed transcription retains its audio with an explicit failure state.
7. If insertion fails, recover the last transcript from Dictation settings.
8. Open Dictation History—or the Command Palette's Dictation tab—to search transcript cards, expand the selected result, play/pause the original recording, paste or copy text, translate through the on-device target-language picker, play/stop the translated text with an installed target-language voice, reveal the recording folder, or delete recordings. Translation and translated speech leave the original transcript unchanged; translated speech is not saved as another recording.

Disabling Dictation cancels an active session and releases its shortcuts.

If Dictation permissions are missing, pressing the shortcut first shows a SuperMac setup card explaining what is missing. Choosing Set Up Dictation starts the guided Microphone → Speech Recognition flow. A denied permission opens the matching System Settings page with a persistent card identifying the exact switch to enable. Microphone and Speech Recognition do not support adding or dragging an app into their lists; macOS adds SuperMac only after the native consent request. If another startup error occurs, a temporary on-screen error explains the failure.

## UJ-07 — Window Management

1. Grant Accessibility and keep Window Management enabled.
2. Use each assigned shortcut from [`../app-replica/scope.md`](../app-replica/scope.md); unassigned actions remain inactive.
3. Confirm the frontmost resizable window reaches the requested half, third, sixth, fourth, three-fourths, center, maximize, resize, restore, or display position.
4. Repeat sizing commands where the selected behavior cycles.
5. Drag a window into each selected snap region, then drag it away and confirm its previous frame is restored.
6. Record, clear, cancel, or restore shortcuts in Window Management settings.

Disabling Window Management stops drag monitoring and releases every owned window shortcut.

## UJ-08 — Shortcut Coaching

1. Grant Accessibility and Input Monitoring and keep Shortcut Coaching enabled.
2. Perform a supported manual action in Finder or Chrome.
3. The detector emits exactly one event only after the action's required postcondition is observed.
4. The event is written once to the Coaching Inbox and unread count.
5. Selected presentation channels deliver their transient output independently.
6. Review and mark events read; preview channels without creating durable history; clear history when desired.

Ambiguous, stale, modified, unsafe, or unverified gestures must produce no coaching event. Disabling Shortcut Coaching stops monitoring.

## UJ-09 — Shared Command Palette

1. Search is the default tab; Clipboard and Dictation are visible peer tabs.
2. Click tabs or press Command-1/2/3 to switch.
3. Switching clears the prior filter, resets selection, and keeps text-input focus.
4. Arrow keys move selection, Return performs the tab's primary action, and Escape dismisses.
5. The footer truthfully identifies local-only behavior.

## UJ-10 — Capability controls and settings

1. Use the native sidebar to reach Home, Quick Search, Clipboard History, Dictation, Window Management, Shortcut Coaching, Permissions, General, and About.
2. Use the toolbar Back button or Command-[ to return through previously visited Settings screens.
3. Enable or disable each capability only from its own screen.
4. Disabling immediately tears down its active panel, monitor, recording, drag behavior, or shortcuts as applicable.
5. Re-enabling restores valid registrations without duplicates.
6. Window shortcuts, dictation language, presentation channels, app presence, and local histories persist according to their documented scope.
7. Quick Search, Clipboard History, Dictation, and every Window Management action provide Record and Clear controls. The three capability entry shortcuts also provide Restore Default.

## UJ-11 — Dock, menu bar, conflicts, and launch at login

1. The app is visible in the Dock and application switcher by default.
2. The menu-bar item contains Settings, the disabled local-preview update item, and Quit SuperMac.
3. Closing Settings leaves the companion running; clicking the Dock icon or Settings reopens the window.
4. Launch at Login can be enabled or disabled from General, with macOS approval status shown truthfully.
5. Onboarding detects running Alfred, Rectangle, and Superwhisper and may quit their processes without uninstalling or changing their data.

## UJ-12 — Deferred commercial journey

The eventual commercial sequence inserts license activation after Welcome, then adds a signed update feed, Developer ID distribution, notarization, and a website download. None of those controls may be simulated in the functional local preview.

## Owner acceptance run

Run this only from the intended installed, signed artifact after granting the requested macOS permissions:

1. Complete UJ-01 and UJ-02 from a clean first launch.
2. Stop Alfred, Rectangle, and Superwhisper, then confirm SuperMac owns the three global entry shortcuts without collisions.
3. Complete the physical acceptance items in UJ-04 through UJ-08, using non-sensitive test text.
4. Disable and re-enable every capability, confirming resource teardown and restoration.
5. Relaunch the Mac login session and confirm menu-bar, Dock, settings, histories, preferences, and shortcuts recover correctly.
6. Record pass/fail evidence without filenames, clipboard values, transcripts, or private coaching content.
