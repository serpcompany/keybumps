# Keybumps product requirements

## Product boundary

Keybumps is one native macOS companion with six independently enabled capabilities:

1. Quick Search
2. Clipboard History
3. Dictation
4. Window Management
5. Keyboard Shortcutter
6. Screenshot Tools

The permanent bundle identifier is `com.serp.keybumps`. The supported baseline is Apple Silicon on macOS 14.2 or newer. User content and processing remain local: no account, sync, analytics backend, cloud transcription, hosted history, or uploaded search, clipboard, transcript, filename, recording, or coaching content.

This document is the source of truth for user-facing behavior and scope. `CONTEXT.md` owns terminology, `docs/architecture.md` owns module seams, `docs/development-workflow.md` owns verification and promotion, `docs/provenance/donor-ledger.md` owns imported-source history, and `docs/releases/sparkle-update-operations.md` owns release operations.

## Application shell

- Present one Dock icon, one menu-bar item, one reusable Settings window, one onboarding flow, and one Command Palette.
- Settings contains Setup, Quick Search, Clipboard History, Screenshot Tools, Dictation, Window Management, Keyboard Shortcutter, Permissions, and General destinations.
- Command-comma and the menu-bar Settings action recreate and raise Settings after its window has been closed.
- Clicking the Dock icon opens Quick Search.
- The menu-bar menu contains Toggle Keybumps, version/build information, Settings, Check for Updates, and Quit Keybumps.
- Each capability owns its detailed settings. Disabling one immediately stops its services and releases its shortcuts without erasing retained local history.
- Keybumps registers Launch at Login after fresh onboarding. Users manage the resulting item through macOS System Settings.

## First launch

The pre-commerce onboarding sequence is:

1. Welcome
2. Capability overview
3. Guided permission setup
4. Shortcut conflict resolution
5. Ready

The local product must state truthfully that purchasing and activation are not configured. Capabilities whose permissions are skipped remain enabled but show **Permission Required** with a recovery action. Unrelated capabilities remain usable.

Conflict resolution detects the supported reference apps when they are running and may offer to quit them without uninstalling them or changing their data. For a fresh user whose enabled Spotlight shortcut exactly matches the configured Quick Search binding, Keybumps attempts to release that exact system shortcut, retries registration through the shared shortcut coordinator, and blocks completion with manual Keyboard Shortcuts guidance if resolution fails. Custom and nonmatching shortcuts remain unchanged.

## Shared Command Palette

- Search, Clipboard, Dictation, Hotkeys (Keyboard Shortcutter history), and Screenshots are peer tabs selected by Command-1/2/3/4/5.
- The tab chrome shows only the shortcut and tab name.
- One dominant input filters the active tab; history inputs use the label **Search**.
- Arrow keys move selection, Return performs the primary action where one exists, and Escape closes the palette.
- Keyboard Shortcutter rows are informational: selection and Return never copy content or mutate history.
- History surfaces share the same native `Clear All` control and destructive confirmation behavior. Confirmation presentation must not trigger outside-click dismissal.

## Quick Search

User outcome: find and open local applications, files, and folders from any app.

- The default shortcut is Command-Space and is recordable, clearable, and restorable.
- Present a centered floating panel above the current application.
- Search indexed local applications, files, and folders and show name, icon, kind, and useful path context.
- Return opens or focuses the selected result; Command-Return reveals a file or folder in Finder.
- Escape and outside click dismiss the panel.
- Opening a result must not leave Keybumps as the active foreground app.
- Record only successfully opened results in a bounded, deduplicated local Recent Items list. Empty search shows that list.
- Individual deletion and confirmed Clear All are supported. Typing, highlighting, dismissing, revealing, and failed opens do not create recents.
- A separate local application-usage index records successful app launches only. Exact and prefix relevance remain stronger than frequency and recency.

Out of scope: web search, calculations, contacts, music control, arbitrary commands, plugins, workflows, and cloud search.

Acceptance requires physical shortcut invocation from another app; successful app, file, and folder opens; keyboard selection; reveal; cancellation; focus return; and relaunch persistence.

## Clipboard History

User outcome: recover and reuse the fifty most recent copied text or image items.

- The default shortcut is Shift-Command-Space and is recordable, clearable, and restorable.
- Capture text and PNG, JPEG, HEIC, GIF, and TIFF changes while enabled.
- When an image file (PNG, JPEG, HEIC, GIF, TIFF) is copied in Finder, store the file's image and remember its location; never store the file icon Finder places on the pasteboard. Other copied files add nothing.
- Persist at most fifty items locally. Store image payloads as separate files capped at 50 MB each rather than embedding them in JSON.
- Collapse consecutive duplicates.
- Selecting an item restores it to the pasteboard and pastes into the focused destination when safe.
- Exclude the exact temporary pasteboard write used by automatic Dictation insertion or Dictation-history paste. A later user-originated copy of identical text remains eligible.
- Support visible image previews, individual deletion, and confirmed Clear All.
- Disabling Clipboard History stops monitoring without erasing retained items.
- Explain in Clipboard History settings that recent copied secrets may remain until removed or displaced, and that a full image history can use several gigabytes of local storage.

Out of scope: arbitrary copied files, audio/video media, cloud sync, accounts, permanent archives, and source classification.

Acceptance covers ordering, duplicate collapse, exact image restoration, fifty-item/media-file eviction, persistence, deletion, clearing, safe paste, and disabled monitoring in the exact signed build.

## Screenshot Tools

User outcome: screenshots taken with the standard macOS shortcuts are immediately available in Clipboard History for pasting and lightweight markup.

- Read the macOS screenshot location (`com.apple.screencapture` `location`, default Desktop) without writing system preferences, and follow changes to it.
- Add only new files macOS marks as screen captures (PNG, JPEG, HEIC, TIFF, GIF) to Clipboard History as screenshot items, after the file finishes writing. Existing files, other images, and other file types are ignored.
- Clipboard History keeps its own media copy and remembers the original file for later editing. Deleting a history item never deletes the original screenshot. Ingestion never writes the pasteboard.
- Screenshot items show the screenshot's name and a **Screenshot** label; Return pastes them like any image.
- Screenshot Tools requires Clipboard History. When Clipboard History is off, Screenshot Tools shows **Requires Clipboard History** with an action to enable it.
- If macOS denies access to the screenshot folder, show that state truthfully with a route to Privacy & Security › Files & Folders. A missing folder is reported and retried.
- Existing installs receive Screenshot Tools enabled once when it first ships; after that the owner's switch is respected. Disabling it stops watching without removing existing items.
- Never log screenshot filenames, paths, or image content.

### Screenshots tab

- Command-5 shows only screenshot items from Clipboard History, newest first, with thumbnails and the shared Search input. Copied images and copied image files stay in the Clipboard tab only.
- Return, or a click, opens the Screenshot Editor; Command-Return, or Command-click, restores the screenshot to the clipboard; Command-E also edits. The footer shows Edit and ⌘ Copy.
- Per-item delete and confirmed Clear All remove screenshot items from history only; files stay where macOS saved them.
- When Screenshot Tools is off, the tab says so. Screenshots share Clipboard History's 50-item limit, so heavy copying can displace older screenshots.

### Screenshot Editor

- Command-E on a highlighted image row, or Command-click on the row, opens the editor for any Clipboard History image while Screenshot Tools is enabled. Return and plain click keep restoring the item. Image rows show a Command-E hint.
- Tools: pixelate, solid redact block, arrow, free draw, and text, selectable with 1–5 (number row or keypad) or P, R, A, D, and T; each tool button shows its number. Tool keys are ignored while typing text. Arrow, draw, and text use a small fixed palette. Undo and redo cover each completed gesture.
- Done (Return) flattens at the image's own pixel density, copies PNG to the clipboard, and saves `<name> (edited).png` next to the original screenshot, numbering on collision. Copied images and unwritable folders save to the macOS screenshot location. Originals are never overwritten. Cancel or Escape discards.
- Redaction safety: exported pixels under pixelate or redact regions never contain original content. Pixelate uses a minimum block size and averages each block; any rendering failure fills the region opaquely instead of showing the original.
- While the editor is open it counts as unsaved work for update safety. Closing it returns focus to the previous app.
- Never log image content, text annotations, or filenames.

Out of scope: Keybumps screen capture, Screen Recording permission, scrolling capture, OCR, recording, beautification, pinning, uploads, crop (deferred), shapes beyond arrow, numbered steps, highlighter, moving or restyling existing marks, and sharing.

Acceptance requires a physical Shift-Command-4 screenshot appearing in the Clipboard tab and pasting correctly, disabling and re-enabling ingestion, the Clipboard History dependency, relaunch persistence, and editing both a screenshot and a copied image with every tool, with an unreadable pasted redaction, in the exact signed build.

## Dictation

User outcome: record speech, transcribe it locally, and insert it at the original cursor.

- The default shortcut is Option-Space and is recordable, clearable, and restorable.
- First press starts recording; second press stops, transcribes the completed local WAV, and inserts the result.
- Escape is a temporary global cancellation shortcut during Recording and Transcribing. It is released before insertion and whenever Dictation becomes idle or disabled.
- Display an unmistakable, non-disruptive Recording or Transcribing indicator whenever audio capture or processing is active.
- Preserve destination focus as reliably as macOS permits.
- Add punctuation and capitalization without semantic rewriting.
- Default to a five-minute limit with 10, 15, 30, and 60-minute choices plus No Limit.
- Expose only languages genuinely supported by the selected local engine.
- Dictation remains useful offline after any required model installation.
- Record one continuous WAV before transcription so early recognition results cannot truncate a session.
- Write pending metadata when recording starts. Recover stale pending or playable audio-only recordings after process interruption; intentional Escape cancellation discards the pending recording.
- Preserve audio and an explicit failure state after transcription failure or timeout. Failed and interrupted entries can retry local transcription in place.
- Store each recording under `~/Documents/Keybumps/recordings/<timestamp>/` as `meta.json` plus `output.wav`.
- Dictation History supports search, playback, waveform progress, 0.5×–2× speed, paste, copy, Finder reveal, retry, individual deletion, and confirmed Clear All.
- Expanded completed cards support Apple's custom on-device `TranslationSession`, a supported target-language picker, and optional speech rendered to a temporary WAV through the shared audio transport.
- Changing or closing a translation deletes generated audio. Translation never changes the original transcript or enters durable history.
- The Command Palette and dedicated history screen use the same rich card behavior.

Required permissions are Microphone and Speech Recognition, plus Accessibility where focused-field insertion requires it.

Out of scope: automatic per-recording language detection, guide/assistant behavior, screen capture (Screenshot Tools only ingests macOS screenshots), AI rewriting, cloud transcription, meeting or system-audio recording, speaker identification, accounts, and uploaded history.

Acceptance requires successful insertion in a standard text editor and browser field plus cancellation, denied-permission recovery, offline operation, language switching, interruption recovery, retry, and failed-insertion recovery.

## Window Management

User outcome: move and resize windows with the configured shortcut profile and drag-to-snap.

- Preserve the defaults encoded by `WindowAction`; unassigned actions remain unassigned.
- Support the selected positioning, sizing, repeated-sizing, and next/previous-display behaviors.
- Support drag-to-snap and restore the prior frame when unsnapping.
- Use zero-pixel gaps for the default profile.
- Present every supported action exactly once in a two-column settings grid with a visual footprint, shortcut recorder, clear action, and Restore Defaults.
- Window calculations remain independently testable from Accessibility execution.

Out of scope: Rectangle Todo Mode, green-stoplight override, and Rectangle branding, updater, identity, credentials, or release infrastructure.

Acceptance requires every assigned shortcut against normal resizable windows, repeated-command behavior, cross-display movement where applicable, and physical verification of each supported drag region.

## Keyboard Shortcutter

User outcome: passively recognize supported manual actions and present the corresponding keyboard shortcut.

- Detect the supported menu, Chrome, standard-window-control, and Finder-to-Trash actions.
- Persist one durable event per verified action with unread state and searchable history.
- Keep Command Palette history passive aside from explicit confirmed Clear All.
- Deliver through Native macOS Banner, Top-right Toast, Top-center Shelf, and separately configured Sound.
- Preview through the same production delivery adapters without writing a history event.
- Custom presentations share close, Escape, horizontal-trackpad-scroll, hover-pause, and dismissal behavior.
- Reflect native notification authorization truthfully in Settings and the Dock attention badge.
- Sanitize Accessibility evidence before persistence or test fixtures; retain only structural values required to recognize the action.

Required permissions are Accessibility and Input Monitoring. New application/action coverage is outside the MVP unless needed to repair an existing supported journey.

Acceptance requires physical supported actions in Finder and Chrome to create exactly one correct durable event and the selected presentation output. Synthetic previews are not detector acceptance.

## Shared platform requirements

### Shortcut ownership

`GlobalShortcutCoordinator` is the sole Carbon hot-key registrar. It reports collisions, avoids partial registration, suspends bindings while recording replacements, restores valid bindings afterward, moves duplicate assignments to one owner, and releases disabled capabilities. Dictation's temporary Escape registration uses the same coordinator.

### Permissions

One coordinator reports truthful state and recovery for all permissions. Keybumps guides users but never claims to silently grant macOS consent.

| Capability | Required permissions |
| --- | --- |
| Quick Search | None for ordinary indexed search |
| Clipboard History | None for ordinary pasteboard monitoring |
| Screenshot Tools | None; macOS may ask for Files & Folders access to the screenshot folder |
| Dictation | Microphone, Speech Recognition, conditional Accessibility |
| Window Management | Accessibility |
| Keyboard Shortcutter | Accessibility and Input Monitoring |

Accessibility and Input Monitoring use silent preflight, exact System Settings navigation, and the app-owned helper. Microphone and Speech Recognition use their required native prompts. Returning to Keybumps refreshes state and advances the guided flow when access is granted.

### Privacy and storage

- Use only Keybumps preference and storage domains; never import or manage another app's data.
- Keep all histories and processing local.
- Logs and committed fixtures contain structural state, timing, stage, error category, and recovery only.
- Never log or commit searches, filenames, clipboard values, transcripts, recordings, window/document titles, URLs, or coaching content.

## Commercial and release boundary

The functional product remains usable without fake purchasing or activation controls. Production commerce requires a separately approved provider and implementation. The intended model is a one-time purchase with one online activation followed by offline validation, without accounts, subscriptions, recurring content checks, or user-content transmission.

Customer distribution is a Developer ID-signed, hardened, notarized direct download rather than a Mac App Store lane. Sparkle configuration, signing, update safety, packaging, publication order, and installed N→N+1 acceptance are owned by `docs/releases/sparkle-update-operations.md`. Publication, commerce configuration, notarization, and distribution require fresh owner authorization.

## Functional acceptance

The functional MVP is accepted only when one stable installed Keybumps build demonstrates all six capabilities together:

- Command-Space opens Quick Search and successfully opens apps, files, and folders.
- Shift-Command-Space recalls and pastes bounded text and image history.
- Option-Space records, transcribes locally, inserts text, and supports Escape cancellation.
- Every configured Window Management shortcut and supported drag region works.
- Supported Finder and Chrome actions create correct Keyboard Shortcutter events.
- A macOS screenshot appears in Clipboard History and the ⌘5 Screenshots tab, pastes correctly, and opens in the Screenshot Editor, where redactions export unreadable.
- Capability switches stop and restart owned resources without duplicate shortcuts or monitors.
- Skipped permissions remain recoverable without disabling unrelated capabilities.
- Relaunch preserves intended preferences and histories.
- No user content leaves the Mac or appears in logs or committed fixtures.

Build, deterministic tests, UI tests, signed runtime, installed artifact, and owner acceptance are separate evidence levels defined by `docs/development-workflow.md`.

## Product non-goals

- Complete parity with any reference product
- Cloud processing, hosted history, accounts, sync, or analytics
- Web search, workflows, arbitrary commands, contacts, music control, or text expansion
- AI rewriting, meeting capture, system-audio recording, or speaker identification
- App Store distribution, Intel support, or pre-macOS-14.2 support
- Trials, subscriptions, license transfer, or multi-device plans in the functional MVP
