# Selected reference behavior for SuperMac

> Frozen planning evidence copied into the canonical implementation repository. The planning-only authorization paragraph below was superseded when the owner explicitly authorized local implementation from the MVP PRD; its limits on public release, reference-app modification, and parity claims remain in force.

## Authorization and boundary

The owner authorized read-only inspection of the installed Superwhisper, Rectangle, and Alfred apps to define selected SuperMac workflows. These apps are behavioral references, not identities to reproduce. This planning session authorizes documentation only and does not authorize implementation, modification of any reference app, public release, or a claim of complete parity.

SuperMac will use its own name, artwork, identifiers, signing, settings, and release infrastructure. Superwhisper and Alfred code, assets, private protocols, services, accounts, and paid capabilities are excluded. Rectangle-derived source may be used only under its MIT license with accurate attribution; Rectangle identity, signing, update infrastructure, and credentials remain excluded.

## Frozen reference applications

| Reference | Installed path | Version | Bundle identifier | Executable SHA-256 | Architecture | Minimum macOS |
| --- | --- | --- | --- | --- | --- | --- |
| Superwhisper | `/Applications/superwhisper.app` | 2.18.3 | `com.superduper.superwhisper` | `6e6c36b4d410f854889e025c5e97f1fe59632677f410896956fe6d238dfcaf2a` | arm64 and x86_64 | 14.0 |
| Rectangle | `/Applications/Rectangle.app` | 0.98 (104) | `com.knollsoft.Rectangle` | `6049540f3467cc190415b52af152795d41f83ef6c70447a0e162c42079ec633a` | arm64 and x86_64 | 10.15 |
| Alfred | `/Applications/Alfred 5.app` | 5.7.3 (2320) | `com.runningwithcrayons.Alfred` | `edc2df877ea5141ed1663b0850dc2057035ca1485969bf2ea19249c536ddedca` | arm64 and x86_64 | 10.14 |
| HeyClicky | `/Applications/HeyClicky.app` | 1.0.48 (57) | `com.humansongs.clicky` | `c1a0863d44da3dda37bac5651809ff9ace3450518eab629f0544da1cb2035b01` | arm64 and x86_64 | 14.2 |

The observations below were captured on 2026-09-12 in the owner's current signed-in macOS environment. Private content was not opened or copied.

## Superwhisper reference slice

Only the owner's ordinary voice-to-text workflow is in scope as a behavioral reference:

1. Press `Option-Space` to start recording.
2. Speak for an arbitrary period.
3. Press `Option-Space` again to stop.
4. Transcribe using the selected language and paste at the current text cursor.

Observed configuration:

- Mode: Voice to text
- Language: English
- Voice model: Whisper Medium
- Auto paste: On
- Autocapitalize Insert: On
- Recording shortcut: `Option-Space`

Automatic per-recording language detection, rewriting modes, cloud services, file transcription, system-audio recording, speaker identification, vocabulary tooling, statistics, and the remainder of Superwhisper are outside this reference slice unless later selected explicitly.

### Per-recording history and storage slice

On 2026-09-12, the owner added Superwhisper's local per-recording archive and History presentation to the selected slice. Read-only inspection used Superwhisper 2.18.3 at `/Applications/superwhisper.app`; private transcript and prompt values were not copied or displayed.

Observed storage behavior:

- The reference root is `~/Documents/superwhisper/recordings`.
- Each completed recording has a Unix-timestamp directory.
- Every observed recording directory contains `meta.json` and `output.wav`; 9,939 matching pairs were present.
- The inspected WAV was mono, 16 kHz, signed 16-bit PCM. SuperMac guarantees a standard playable local WAV but does not claim identical encoding until differential audio-format verification passes.
- Reference metadata includes timing, duration, selected language/model/mode, transcript/result fields, segments, device, and optional processing context. SuperMac stores only fields it actually produces and never fabricates reference model, mode, prompt, speaker, translation, or system-audio metadata.

SuperMac's original product path is `~/Documents/SuperMac/recordings/<unix-timestamp>/`, with one `meta.json` and one `output.wav` for every successfully transcribed recording. Metadata contains the stable recording ID, capture date, duration, selected language, transcript, audio filename, and SuperMac version. Existing reference files remain untouched and are never imported automatically.

The selected History surface uses original SuperMac styling while adopting the observed hierarchy: collapsed cards show a two-line transcript preview; selecting one expands it and collapses the previous selection; the expanded card shows the full transcript, a compact playable audio strip with a waveform and duration, an Original label, copy, reveal/info, and delete controls. Search, expansion, play/pause, copy, reveal, individual deletion, clear-all, reload persistence, and missing-audio handling must be real. The waveform is derived from SuperMac's own WAV rather than copied reference pixels. Superwhisper branding, exact artwork, segmented/reprocessing modes, analytics, cloud/model details, and pixel-identical styling remain excluded.

The same history-card component is used in the Command Palette's Dictation tab. Keyboard selection expands the active item and collapses peers; arrows move selection, Return retains the fast paste behavior, and the expanded card also exposes explicit Paste, Copy, playback, Translate, info/reveal, and delete actions. Switching tabs or closing the palette stops audio playback.

SuperMac adds an original Translate action to the expanded card. On macOS 15 or newer it opens an inline SuperMac panel backed by Apple's custom `TranslationSession`, providing a supported target-language picker, any required system language-model download flow, translated output, and copy. Translation content is processed on device. SuperMac does not overwrite or persist a translated variant in `meta.json`; the original transcript remains authoritative. On macOS 14 the action is visibly unavailable. The system `translationPresentation` is explicitly excluded because runtime inspection showed it may send selected content to Apple unless a separate system preference is enabled.

## Rectangle configuration reference

The installed Rectangle app, rather than the Window Manager prototype, is the source for the owner's starting Window Management configuration.

The owner-supplied `Rectangle Appshot 2026-09-11T20-56-49.682Z.png` visually corroborates the shortcut mappings below. The Appshot shows the Shortcuts surface only; it does not select Rectangle's Todo Mode, green-button override, or other General settings as SuperMac MVP requirements.

Observed assigned shortcuts:

| Action | Shortcut |
| --- | --- |
| Left | `Control-Option-Command-Left` |
| Right | `Control-Option-Command-Right` |
| Center half | `Control-Option-Command-5` |
| Top | `Control-Option-Shift-Command-Up` |
| Bottom | `Control-Option-Shift-Command-Down` |
| Top left | `Control-Option-U` |
| Bottom left | `Control-Option-J` |
| Bottom right | `Control-Option-K` |
| Maximize | `Control-Option-Command-Up` |
| Make smaller | `Control-Option-Minus` |
| Make larger | `Control-Option-Equals` |
| Move to center | `Control-Option-Command-M` |
| Restore | `Control-Option-Delete` |
| Next display | `Control-Option-Right` |
| Previous display | `Control-Option-Left` |
| First third | `Control-Option-Command-1` |
| Center third | `Control-Option-Command-2` |
| Last third | `Control-Option-Command-3` |
| First two thirds | `Control-Option-Command-4` |
| Last two thirds | `Control-Option-Command-6` |
| Top left sixth | `Control-Option-Shift-Command-4` |
| Top center sixth | `Control-Option-Shift-Command-5` |
| Top right sixth | `Control-Option-Shift-Command-6` |
| Bottom left sixth | `Control-Option-Shift-Command-7` |
| Bottom center sixth | `Control-Option-Shift-Command-8` |
| Bottom right sixth | `Control-Option-Shift-Command-9` |
| Last fourth | `Control-Option-Command-Southeast Arrow` |
| First three fourths | `Control-Option-Command-7` |
| Last three fourths | `Control-Option-Command-9` |
| Toggle Todo | `Command-B` |
| Reflow Todo | `Control-Option-N` |

Top right, Almost Maximize, Maximize Height, Center Two Thirds, First/Second/Third Fourth, Center Three Fourths, and directional Move actions had no assigned shortcuts.

Observed behavioral preferences:

- Launch on login: On
- Rectangle menu-bar icon: Hidden
- Repeated left/right commands: move to the adjacent display
- Window gaps: 0 px
- Move cursor with a window across displays: On
- Double-click title bar to maximize/restore: Off
- Green stoplight button maximizes instead of entering full screen: On
- Snap windows by dragging: On
- Restore window size when unsnapped: On
- Haptic feedback: On
- Animate footprint: On
- Todo Mode: visible, right side, 400 px wide
- Stage Manager recent-apps allowance: 190 px

The assigned shortcut mappings shown in the owner-supplied Appshot are the confirmed starting Window Management profile. Repeated sizing and display movement plus Rectangle-style drag-to-snap are also selected for MVP. Todo Mode and the green-stoplight override are explicitly excluded; other observed Rectangle preferences remain reference evidence rather than confirmed SuperMac MVP scope.

## Alfred reference slice

Only the owner's Spotlight-like search journey is in scope as a behavioral reference:

1. Press `Command-Space` from another application.
2. Type a partial application or file name.
3. Review matching local results.
4. Open or focus the selected result.

Observed configuration:

- Main hotkey: `Command-Space`
- Launch at login: On
- Location: United States
- Use `.com` for Google searches: On

SuperMac adopts `Command-Space`, launch at login, and app/file/folder search as the selected slice. Workflows, automation, web-search providers, contacts, music control, text expansion, themes, and the remainder of Alfred are outside this reference slice unless later selected explicitly. Clipboard History is being designed as a separate SuperMac capability rather than assumed to match Alfred.

The selected Quick Search behavior is a centered floating search panel with results underneath. Arrow keys change selection, Return opens the selected application, file, or folder, Command-Return reveals a file in Finder, and Escape or clicking elsewhere dismisses the panel.

The owner confirmed that Alfred Clipboard History is invoked separately with `Shift-Command-Space`. SuperMac adopts that shortcut for its own locally persisted ten-item text history without otherwise claiming Alfred Clipboard History parity.

## Unified command-palette reference slice

On 2026-09-12, the owner requested that the SuperMac launcher use a denser Alfred/Raycast-style command-palette hierarchy while remaining an original SuperMac design. The bounded slice contains exactly three palette tabs: Search as the default, Clipboard History, and Dictation History. Raycast is not installed on the reference Mac; current official Raycast product pages are design references only. Alfred 5.7.3 remains the locally observed reference for compact launcher geometry and immediate keyboard focus.

Selected traits are a single centered floating surface, a dominant search field, compact keyboard-first result rows, visible tab switching, strong selected-row treatment, and concise keyboard hints. Raycast and Alfred names, icons, illustrations, themes, proprietary interactions, broader feature sets, and exact pixel styling are excluded.

## Migration boundary

SuperMac starts with empty Shortcut Coaching, Dictation, and Clipboard histories. Existing historical content from Shortcut Coach, SERPy, Superwhisper, and Alfred is not imported. The owner-selected shortcuts and behavior form the new product defaults, while the old applications and their data remain untouched so rollback is possible.

During onboarding, SuperMac detects conflicting running copies of Alfred, Rectangle, and Superwhisper, identifies the shortcuts they occupy, and offers to quit them. It explains how to disable their launch-at-login settings but does not uninstall them, delete their data, or silently modify their configuration.

## HeyClicky permission-helper slice

On 2026-09-12, the owner supplied a HeyClicky screenshot showing its Accessibility setup experience. The app opens the exact System Settings privacy list and floats a helper near the bottom of that window. The helper says “I’m HeyClicky — drag me into the list above” and presents the signed application as a large draggable row.

SuperMac adopts this narrow interaction for Accessibility and Input Monitoring with original SuperMac branding and copy. The dragged payload must be the running signed `SuperMac.app` bundle as a public file URL; the helper does not grant or toggle consent. Microphone and Speech Recognition continue through their native system prompts because they are not add-an-app list permissions. Exact HeyClicky styling, identity, iconography, copy, and other permission or product behavior remain excluded.

## Product and distribution boundary

- Product: SuperMac
- Bundle identifier: `com.serp.supermac`
- Canonical implementation: a new repository; this Shortcut Coach repository remains a planning and reference source
- Compatibility: Apple Silicon and macOS 14.2 or newer
- Distribution: Developer ID-signed and notarized download from the product website
- Commercial model: one-time purchase
- Mac App Store: no current or planned SuperMac edition
- Processing and user content: local only
- Accounts, sync, cloud processing, analytics backend, and application server: excluded
- Updates: checked at every launch, downloaded in the background, then installed through a user-requested restart or at the next normal quit

## Dictation acceptance boundary

Dictation may use Apple Speech or another accurate local model; the acceptance target is the selected Superwhisper-like voice-to-text workflow, not Whisper branding. The language selector exposes the languages genuinely supported by the chosen local engine, with automatic per-recording detection deferred.

Dictation uses `Option-Space` to start and stop. A small floating indicator visibly distinguishes Recording from Transcribing, disappears after successful insertion, and cancels without pasting when the user presses Escape.

The default maximum recording length is five minutes. Dictation settings offer 10, 15, 30, and 60 minutes plus No Limit. Reaching a finite limit automatically stops capture and begins transcription. SuperMac records one continuous WAV and transcribes that completed local file rather than treating an early final result from a live recognition task as the entire dictation. If transcription fails, the audio remains available in Dictation History with an explicit failure state.

## Shortcut Coaching acceptance boundary

The first SuperMac release retains Shortcut Coach's current Accessibility and Input Monitoring permission requirements and its currently supported action coverage. Additional permission does not imply additional recognition coverage; new supported actions can arrive through later verified updates.

## Decision gate

The product-level design is confirmed. The owner wants the selected workflows integrated into a usable MVP before spending more time on reversible implementation details. Repository naming, internal module layout, provider choice, exact visual polish, and minor controls may be chosen pragmatically during implementation and tuned after hands-on use.

This confirmation does not itself authorize code implementation; the original planning-only boundary remains in effect until the owner explicitly starts that phase.
