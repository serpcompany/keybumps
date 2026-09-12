# SuperMac MVP — implementation handoff

## Mission

Build one native macOS application that replaces the owner's daily use of Shortcut Coach, Rectangle, Superwhisper, and Alfred with the selected workflows below. The product is **SuperMac**, bundle identifier `com.serp.supermac`.

Prioritize a usable integrated MVP over speculative platform work. Preserve working donor behavior, prove each real macOS integration from the signed app, and defer reversible polish until the owner can use the combined product.

## Authority and limits

When the owner gives this document to an implementation agent, that authorizes:

- creating a new local repository for SuperMac;
- copying or adapting selected source from the owner-controlled donor repositories;
- using Rectangle-derived source under its MIT license with attribution;
- building, signing for local development, launching, testing, and recording local evidence;
- making pragmatic, reversible implementation decisions needed to deliver the functional MVP.

It does not authorize:

- publishing a repository or release;
- charging customers or configuring a live checkout;
- uploading private artifacts, histories, transcripts, clipboard data, or recordings;
- deleting or modifying the existing apps, donor repositories, or their saved data;
- copying Superwhisper or Alfred source, assets, identity, private protocols, or services;
- claiming complete parity with any reference application.

Obtain fresh owner authorization before a public remote, public release, live payment configuration, production license service, or customer distribution.

## Start here

Read these before editing:

1. [`CONTEXT.md`](../../CONTEXT.md) — canonical product vocabulary.
2. [`docs/adr/0001-one-companion-with-enabled-capabilities.md`](../adr/0001-one-companion-with-enabled-capabilities.md) — one-app product shape.
3. [`docs/adr/0002-direct-local-only-commercial-product.md`](../adr/0002-direct-local-only-commercial-product.md) — distribution and privacy boundary.
4. [`docs/adr/0003-one-online-activation-then-offline-validation.md`](../adr/0003-one-online-activation-then-offline-validation.md) — licensing decision and deferred details.
5. [`docs/adr/0004-new-canonical-supermac-repository.md`](../adr/0004-new-canonical-supermac-repository.md) — new-repository decision.
6. [`docs/app-replica/scope.md`](../app-replica/scope.md) — frozen reference versions, exact Rectangle shortcuts, observed settings, and selected reference slices.

Treat the reference scope as authoritative when this PRD summarizes rather than repeats detailed mappings.

## Donor repositories

| Donor | Absolute path | Use |
| --- | --- | --- |
| Shortcut Coach | `/Users/devin/dev/repos/keyboard-shortcut-coach-mac-app` | App shell foundation, coaching detection, delivery, history, permission diagnostics, presentation channels |
| SERPy | `/Users/devin/dev/repos/serpy-clicky-mac-app` | Dictation state machine, local transcription, text insertion, permissions, recovery, status overlay |
| Window Manager | `/Users/devin/dev/repos/mac-window-manager-app` | Rectangle-derived window calculations, execution, global shortcuts, cycling, display movement, drag-to-snap |

The donor repositories remain intact. Record the donor repository and commit for every imported source group. The new app must build without runtime or checkout-path dependencies on the donors.

### Reference applications

- `/Applications/superwhisper.app` is the behavioral oracle for the selected voice-to-text journey.
- `/Applications/Rectangle.app` is the behavioral and configuration oracle for Window Management.
- `/Applications/Alfred 5.app` is the behavioral oracle for Quick Search and the Clipboard History invocation.

Use black-box observation only for Superwhisper and Alfred. Keep SuperMac branding and assets original.

## Product frame

SuperMac is one quiet, sellable Mac utility with:

- one Dock icon;
- one menu-bar item;
- one normal Settings window with a sidebar;
- one onboarding flow;
- one shared permission experience;
- one shared global-shortcut registry;
- independently controllable capabilities.

The capabilities are:

1. Quick Search
2. Clipboard History
3. Dictation
4. Window Management
5. Key Bumps

All begin enabled. Settings/Home is a readiness dashboard with truthful status and setup/open actions. Enable/disable controls live in each capability's own sidebar screen. Disabling a capability immediately stops the resources it actually owns, such as monitors, panels, recordings, and global shortcuts.

## Required user surfaces

### Settings

Use a native macOS sidebar with these conceptual destinations:

- Home
- Quick Search
- Clipboard History
- Dictation
- Window Management
- Key Bumps
- Permissions
- General
- About

Exact labels, order, and visual polish are reversible implementation details. The window must remain understandable without documentation.

Clicking the Dock icon opens Settings/Home. SuperMac registers Launch at Login during onboarding; it does not duplicate macOS Login Items controls inside General. Users change that behavior through System Settings.

### Menu bar

Keep the menu deliberately minimal:

- Settings…
- Check for Updates…
- Quit SuperMac

Settings must reopen and raise the main window even after the user has closed it; the menu action cannot depend on a listener owned only by that closed window.

Do not duplicate feature commands in this menu for MVP.

### First launch

The intended commercial order is:

1. Welcome
2. License activation
3. Capability overview
4. Guided permission setup
5. Conflict resolution
6. Ready

For the functional pre-commerce MVP, do not present a fake license or activation control. State plainly that purchasing and activation are not part of the local preview. Add the real activation step only after a production licensing provider is selected.

Capabilities remain enabled when a required permission is skipped, but show **Permission Required** and a recovery action. Quick Search and Clipboard History remain usable without unrelated permissions.

Detect running Alfred, Rectangle, and Superwhisper instances that own the selected shortcuts. Offer to quit those processes and explain how to disable their launch-at-login settings. Leave the apps installed and their configuration/data untouched.

## Capability requirements

### Shared Command Palette

Quick Search, Clipboard History, and Dictation History share one original SuperMac command palette inspired by Alfred's compact launcher and Raycast's dense keyboard-first hierarchy. Search is the default tab; Clipboard and Dictation are peer tabs. A single dominant input filters the active tab, arrow keys move selection, Return performs the primary action, Escape closes the palette, and Command-1/2/3 switch tabs.

Command-Space opens the palette on Search. Shift-Command-Space opens the same palette on Clipboard. The Dictation settings screen opens it on Dictation. Reference product names, assets, themes, proprietary interactions, and broader feature sets remain excluded.

### 1. Quick Search

User outcome: replace the owner's basic Alfred/Spotlight launcher workflow.

- Default global shortcut: `Command-Space`; user-recordable and clearable in Quick Search settings.
- Display a centered floating search panel above the current application.
- Search indexed local applications, files, and folders.
- Show useful name, icon, kind, and path context without overwhelming the result list.
- Arrow keys change selection.
- Return opens or focuses the selected result.
- Command-Return reveals a file or folder in Finder.
- Escape or clicking outside dismisses the panel.
- The panel must not leave SuperMac as the active foreground app after launching a result.

Out of scope: web searches, calculations, contacts, music control, Alfred workflows, arbitrary commands, plugins, and cloud search.

Completion criterion: from another app, `Command-Space` can find and open a known installed app, a known file, and a known folder; keyboard selection, reveal-in-Finder, cancellation, focus return, and relaunch persistence are directly observed.

### 2. Clipboard History

User outcome: recover and reuse the most recent copied text or image through the Clipboard tab of the shared Command Palette.

- Default global shortcut: `Shift-Command-Space`; user-recordable and clearable in Clipboard History settings.
- Capture text plus PNG, JPEG, HEIC, GIF, and TIFF clipboard changes while the capability is enabled.
- Persist only the ten most recent text or image items locally. Store image payloads as separate local media files capped at 50 MB each rather than embedding binary data in the history JSON.
- Collapse consecutive duplicates.
- Selecting an item restores it to the clipboard and pastes it into the focused destination when safe.
- Exclude SuperMac's automatic pasteboard writes for fresh Dictation insertion and Paste from Dictation History; those transcripts already belong to Dictation History. A later user-originated copy of the same text remains eligible for Clipboard History.
- Provide deletion and a native Clear History control that requires destructive confirmation before removing all items. Opening, cancelling, or confirming that alert must not dismiss the Command Palette.
- Disabling the capability stops monitoring but does not silently erase retained items.
- No arbitrary copied files, audio/video media, cloud sync, account, permanent archive, or elaborate source filtering in MVP.

The product owner deliberately chose the simplest bounded implementation. Document clearly that recent copied secrets may remain in the ten-item local history until removed or displaced.

Completion criterion: copy more than ten distinct text/image values across ordinary applications; verify visible image previews, exact image paste restoration, ordering, duplicate collapse, ten-item/media-file eviction, persistence across app restart, deletion, clearing, and disabled monitoring from the exact signed build.

### 3. Dictation

User outcome: replace the owner's transparent Superwhisper voice-to-text workflow.

- Default global shortcut: `Option-Space` toggles recording; user-recordable and clearable in Dictation settings.
- Default maximum recording length: five minutes, with 10, 15, 30, and 60-minute choices plus No Limit in Dictation settings.
- First press starts recording.
- Second press stops recording, transcribes locally, and inserts at the current text cursor.
- The temporary pasteboard write used for automatic insertion is transport only and must not create a duplicate Clipboard History entry.
- Escape is registered as a temporary global cancellation key while Recording or Transcribing and cancels without inserting text. It is released before insertion and whenever Dictation becomes idle or disabled.
- Show a small non-disruptive floating indicator for Recording and Transcribing.
- Hide the indicator after successful insertion or cancellation.
- Preserve the destination's focus as reliably as macOS permits.
- Add punctuation and capitalization without semantic rewriting.
- Provide a Settings language selector populated only with languages genuinely supported by the chosen local engine.
- Automatic per-recording language detection is deferred.
- Dictation remains local and useful offline after any required model installation.
- Record the full continuous WAV first and transcribe the completed file so an early live-recognition final result cannot truncate a longer session.
- Write pending metadata when recording begins and preserve the continuously written WAV when the app/process is unexpectedly interrupted. On relaunch, recover pending recordings and legacy playable audio-only folders into Dictation History with an explicit interrupted state. Intentional Escape cancellation remains a discard action.
- Preserve the WAV in Dictation History with an explicit failure state when transcription fails or times out. Interrupted and failed entries provide a local Transcribe action that retries the completed audio file and updates the same history item.
- Retain SERPy's crash-safe last-dictation recovery behavior where practical.
- Persist every completed Dictation as `~/Documents/SuperMac/recordings/<timestamp>/meta.json` plus `output.wav` rather than rewriting a monolithic history file.
- Provide a searchable Dictation History screen with real local playback, duration/progress, 0.5× through 2× speed controls, copy, reveal in Finder, individual delete, and a native clear-all control that requires destructive confirmation.
- Add a Translate action to expanded transcript cards using Apple's custom on-device `TranslationSession`, with a supported target-language picker and system-managed language downloads. Render translated speech to a temporary local WAV and present it through the same waveform, play/pause, progress, duration, and speed controls as the original recording. Delete that temporary audio when the translation closes or changes; preserve the original transcript, do not add generated speech to Dictation History, and do not use the system presentation that may process content remotely.
- Keep transcript reuse available from the third Command Palette tab.
- Render the same rich accordion item in the Command Palette Dictation tab so completed and interrupted results can be reviewed, transcribed when needed, pasted, copied, played at an adjustable speed, translated, heard in the target language, revealed, or deleted without opening Settings. The entire padded accordion header is a button target with hover feedback rather than limiting expansion to its text.

Apple's on-device speech implementation in the SERPy donor is the starting candidate because the owner found it acceptable. Another local model is allowed only when measured accuracy, latency, offline behavior, cancellation, and resource cost are better. Model branding is not a requirement.

Required permissions are Microphone and Speech Recognition, plus Accessibility only where focused-field insertion needs it. Display an unmistakable recording indicator whenever audio is captured.

Out of scope: the SERPy guide, cursor companion, screen capture, AI rewriting, cloud transcription, meeting recording, system-audio recording, speaker identification, accounts, and uploaded history.

Completion criterion: in at least one standard text editor and one browser text field, start, speak, stop, and observe the transcript inserted at the original cursor; separately prove cancellation, denied-permission recovery, offline operation, language switching, failed insertion recovery, and no assistant/network dependency.

### 4. Window Management

User outcome: replace the owner's actual Rectangle configuration without learning new shortcuts.

- Use every assigned shortcut in the canonical table in [`docs/app-replica/scope.md`](../app-replica/scope.md).
- Preserve unassigned actions as unassigned; do not invent additional defaults.
- Support the selected positioning and sizing actions.
- Preserve repeated sizing behavior.
- Preserve next/previous-display behavior.
- Include Rectangle-style drag-to-snap.
- Restore the prior window size when unsnapping.
- Preserve zero-pixel gaps for the starting profile.
- Present configurable shortcuts in a Rectangle-inspired two-column settings grid with a visual footprint for each action, the shortcut recorder, and a clear control. Every supported action appears exactly once; unsupported Rectangle-only actions remain absent.

Explicitly excluded from MVP:

- Rectangle Todo Mode;
- the green-stoplight maximize override;
- Rectangle branding, updater, signing identity, appcast, credentials, and release infrastructure.

Use Window Manager's independently identified MIT-licensed fork as the code donor. Preserve the Rectangle MIT license and accurate upstream attribution in the new repository and distributed product.

Completion criterion: exercise every assigned shortcut against normal resizable windows, verify the resulting frame on one display and across displays where applicable, prove repeated-command behavior, and physically verify each selected drag-to-snap region. Unit tests for calculations support but do not replace installed runtime proof.

### 5. Key Bumps

User outcome: provide the old Shortcut Coach foundation inside SuperMac under the Key Bumps name.

Bring across the current full-product behavior:

- supported manual-action detection;
- durable key-bump history and unread state;
- presentation-channel selection and previews;
- Key Bumps history;
- app-presence behavior;
- permissions and diagnostics;
- current supported action catalog.

Required system permissions remain Accessibility and Input Monitoring. Direct distribution enables these permissions but does not increase detection coverage by itself. New application/action recognition is post-MVP work unless required to repair an existing supported journey.

Use the existing Shortcut Coach architecture and verification documents as the contract:

- [`docs/architecture.md`](../architecture.md)
- [`docs/product/feature-inventory.md`](feature-inventory.md)
- [`docs/verification.md`](../verification.md)

Completion criterion: from the exact signed SuperMac build, a physical supported manual action in Finder and a supported action in Chrome each produce one correct durable key bump and the selected presentation output. Synthetic previews do not satisfy detector acceptance.

## Shared system requirements

### Global shortcut ownership

One coordinator owns registration, collision detection, recording, suspension, and release of all global shortcuts. Feature modules request bindings; they do not each assume exclusive control of the event system.

The coordinator must:

- report collisions clearly;
- avoid partially registered shortcut states;
- suspend active bindings while recording a replacement shortcut;
- restore valid bindings afterward;
- release a capability's bindings when it is disabled;
- handle session resign/activation without duplicate registrations.

Every global shortcut exposed by a capability settings screen must be recordable and explicitly clearable. Quick Search, Clipboard History, and Dictation also provide a per-action Restore Default control. Reassigning a key combination moves it from its previous SuperMac action rather than leaving an ambiguous internal collision.

Pressing the Dictation shortcut without Microphone or Speech Recognition access first shows an app-owned explanation with a Set Up Dictation action. It must not throw the user into System Settings without context. The explicit setup action starts the guided permission flow; denied permissions open the exact macOS pane with a visible instruction card. Other startup failures show a transient error indicator and remain visible in Dictation settings.

### Permissions

One permission coordinator reports capability requirements and current state. The guided setup should make macOS's Security & Privacy steps as direct as public APIs allow, using clear drag/open guidance and deep links where appropriate. The app may guide users but must not claim to bypass or silently grant macOS-controlled consent.

Accessibility and Input Monitoring use only the HeyClicky-inspired bounded setup journey recorded in `docs/app-replica/scope.md`: silently preflight current status, open the exact System Settings list, keep a nonactivating helper visible above it, and let the user drag the signed SuperMac app bundle into the list. SuperMac must not also invoke the native Accessibility `AXIsProcessTrustedWithOptions(prompt: true)` or `CGRequestListenEventAccess()` dialogs for those permissions. Microphone and Speech Recognition use their required native consent prompts. Every path refreshes truthful permission state after the user returns.

Required permissions by capability:

| Capability | Permissions |
| --- | --- |
| Quick Search | None for ordinary indexed search |
| Clipboard History | None for ordinary pasteboard monitoring |
| Dictation | Microphone, Speech Recognition, and conditional Accessibility for insertion |
| Window Management | Accessibility |
| Key Bumps | Accessibility and Input Monitoring |

### Privacy and storage

- User content and processing remain local.
- No account, sync, analytics backend, application server, cloud transcription, or hosted history.
- No clipboard, dictated text, search terms, Key Bumps history, or filenames in telemetry or committed evidence.
- Start all histories clean; do not import historical user content from donor/reference apps.
- Use distinct SuperMac storage paths and preference domains.
- Keep logs structural: state, duration, stage, error category, and recovery—not private content.

### App identity

- Display name: SuperMac
- Bundle identifier: `com.serp.supermac`
- Target: Apple Silicon, macOS 14.2 or newer
- Distribution: Developer ID signing, hardened runtime, notarized direct download
- Mac App Store: no product or release lane

Stabilize bundle identifier, signing team, executable name, and installed path before permission-sensitive acceptance. Do not repeatedly churn the identity used by TCC.

## Licensing and updates

Commercial release requirements are real but must not block the functional integration loop.

### License

- One-time purchase; no trial.
- License activation occurs before permission onboarding.
- One online activation binds the purchase to one Mac.
- Later launches validate signed proof offline indefinitely.
- No recurring checks or user account.
- Transfer, deactivation, multi-device use, reinstall recovery, and provider selection are deferred.
- License traffic must never include user content or usage analytics.

Before production implementation, compare current reputable licensing/payment options against ADR 0005. Choose a standard mechanism and record the decision; do not invent custom cryptography or silently turn licensing into a general backend.

### Updates

- Check for signed updates whenever the app launches.
- Download available updates in the background.
- Present Restart to Update when ready.
- Otherwise install on the next normal quit.
- Never interrupt recording, transcription, insertion, window actions, or unsaved user work.
- Keep Check for Updates in the minimal menu-bar menu.

Select and document an owned update feed and signing mechanism before treating updates as production-ready. Do not reuse Rectangle's appcast or signing material.

## Recommended architecture

Use one native macOS Xcode project with a thin composition/lifecycle target and independently testable feature boundaries. A sensible dependency direction is:

```text
SuperMacApp
    ├── SharedCore
    ├── SharedMac
    ├── SharedUI
    ├── QuickSearchFeature
    ├── ClipboardFeature
    ├── DictationFeature
    ├── WindowManagementFeature
    └── KeyBumpsFeature
```

The exact targets/packages are implementation discretion. Preserve these ownership rules:

- the app shell owns lifecycle and composition;
- SharedCore owns capability identity, settings contracts, and state independent of AppKit;
- SharedMac owns permissions, global-shortcut coordination, launch-at-login, activation policy, and platform adapters;
- each feature owns its domain behavior and detailed settings;
- no feature creates a second app delegate, status item, Settings scene, updater, license system, or launch-at-login controller;
- dictation never depends on guide/assistant code;
- Key Bumps detection never owns presentation history;
- Window Management calculations remain independently testable from Accessibility execution.

Prefer extracting coherent donor modules over mechanically copying entire application targets.

## Execution sequence

### Phase 0 — Freeze and scaffold

1. Record exact donor commits and working-tree state.
2. Create the new local repository and its `AGENTS.md`, `CONTEXT.md`, ADRs, provenance record, and GitHub-Issue-ready task breakdown.
3. Create a selected-slice completion manifest before implementation; do not create a complete-parity manifest for all reference-app features.
4. Establish the stable app identity and a repeatable build/run script.
5. Capture baseline reference evidence needed for the selected journeys.

Completion criterion: a fresh clone can build and launch a signed empty SuperMac shell under the permanent bundle identity, and every imported source group has a recorded donor/license disposition.

### Phase 1 — Shared shell

Build Settings/Home, capability switches, minimal menu, Dock behavior, launch at login, shared shortcut registry, permission coordinator, and development adapters for licensing/updating.

Completion criterion: the shell relaunches with stable settings, capabilities correctly acquire/release placeholder bindings, and permission states remain truthful.

### Phase 2 — Quick Search and Clipboard History

Deliver the two lowest-permission daily workflows first.

Completion criterion: both capability-level completion criteria pass from the signed app without Alfred running.

### Phase 3 — Dictation

Import and narrow the SERPy dictation path. Keep guide code absent.

Completion criterion: the full dictation completion criterion passes without Superwhisper running.

### Phase 4 — Window Management

Extract selected Rectangle behavior from the Window Manager donor and integrate it behind shared shortcut/permission ownership.

Completion criterion: the complete assigned shortcut profile and drag-to-snap acceptance pass without Rectangle running.

### Phase 5 — Key Bumps

Move the old Shortcut Coach feature into the shared shell as Key Bumps without broadening coverage.

Completion criterion: current Finder and Chrome physical-action journeys pass without the old Shortcut Coach running.

### Phase 6 — Integrated replacement proof

1. Run all capabilities together.
2. Exercise shortcut conflicts and capability disable/enable cycles.
3. Restart the Mac or login session and verify launch-at-login recovery.
4. Prove each primary workflow with Alfred, Rectangle, Superwhisper, and Shortcut Coach stopped.
5. Preserve screenshots, logs, test results, and short screen recordings that contain no private content.

Completion criterion: the owner can perform all five selected daily workflows using only SuperMac, while the old apps remain available but inactive for rollback.

### Phase 7 — Commercial release gates

Only after Phase 6:

- select and implement production licensing;
- select and implement signed updates;
- finish original branding and website disclosure;
- archive, export, notarize, staple, package, and verify the installed artifact;
- obtain explicit owner approval before any public upload or sale.

Completion criterion: the exact packaged artifact passes license activation, offline relaunch, update, clean-install permissions, all integrated journeys, identity checks, and notarization verification.

## Verification contract

Report these layers separately:

1. **Build** — compilation and signing succeeded.
2. **Deterministic tests** — domain/state/calculation tests passed.
3. **UI tests** — visible navigation and deterministic UI states passed.
4. **Signed runtime** — macOS permissions, shortcuts, windows, microphone, clipboard, and search were exercised from the stable signed bundle.
5. **Installed artifact** — the packaged/notarized app completed the journey outside Xcode.
6. **Owner acceptance** — the owner used the combined app as a replacement.

Never promote a lower layer as proof of a higher one. In particular:

- a build is not proof of window movement or dictation;
- a synthetic transcript is not proof of microphone capture;
- unit-tested window calculations are not proof of Accessibility execution;
- presentation previews are not proof of physical Key Bumps detection;
- a launched `.app` is not proof of the installed/notarized artifact;
- one successful workflow is not complete reference-app parity.

## MVP non-goals

- Superwhisper guide or AI rewriting
- automatic dictation language detection
- Alfred workflows, web search, calculations, contacts, or music control
- text snippets or automatic text expansion
- Rectangle Todo Mode or green-button override
- complete Keylume, Superwhisper, Rectangle, or Alfred parity
- accounts, sync, analytics, cloud processing, or hosted user history
- App Store distribution
- Intel or pre-macOS-14.2 support
- license transfer, subscriptions, trials, or multi-device plans
- public release during the functional integration phases

## Definition of functional MVP

The functional MVP is complete when one stable signed SuperMac build, with the four old apps stopped, directly proves all of the following:

- `Command-Space` finds and opens apps, files, and folders.
- `Shift-Command-Space` recalls the bounded persistent text clipboard history.
- `Option-Space` records, transcribes locally, and inserts dictated text; Escape cancels.
- every assigned Rectangle shortcut and selected drag-to-snap behavior works.
- current supported Finder and Chrome actions generate correct key bumps.
- Home switches stop and restart each capability without duplicate hotkeys or monitors.
- skipped permissions remain recoverable and do not disable unrelated capabilities.
- quitting/relaunching preserves intended preferences and histories.
- no user content is sent over the network or written into logs/evidence.

Licensing, updating, website checkout, and notarized customer packaging are commercial-release gates after this functional MVP, not excuses to postpone proving the combined product.

## Fresh-agent first action

Do not begin by moving source. First inspect the current state and commits of all three donor repositories, confirm no overlapping user changes would be overwritten, and translate the phases above into a bounded issue sequence for the new repository. Record the repository location, donor commit ledger, module boundaries, and first functional acceptance slice, then proceed using the recommended defaults. Return to the owner only when a choice would materially change product scope, privacy, licensing obligations, external publication, cost, or another authorization boundary.
