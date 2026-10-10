# Keybumps

Keybumps is a native macOS utility combining local Quick Search, bounded text-and-image Clipboard History, Screenshot Tools, on-device Dictation, Snippets, Timer, Emoji Picker, Translation, Keystrokes, Screencast, Window Manager, and Shortcut Coach in one app. Search (⌘1), Clipboard History (⌘2), Screenshots (⌘3), Dictation History (⌘4), Snippets (⌘5), Timers (⌘6), Emoji (⌘7, once you turn Emoji Picker on in Settings › Plugins), Translate (⌘8, once you turn Translation on; it needs macOS 15), and Shortcut Coach History (Hotkeys, ⌘9, hidden by default) share one Raycast-style, keyboard-first Command Palette; with the search field empty, ← and → switch between its tabs. In Timers, type a duration such as `5m` or `tea 25` and press Return; when it ends, an alarm stays on screen and rings until you stop it. On a highlighted row, ⌘C copies and ⌘P pastes into the app you're using, and with the search field empty, Space plays a recording or reads a saved translation aloud. Snippets are text you save to reuse: Return or ⌘C copies one and ⌘P pastes it into the app you're using. In Translate, type or paste text and it is translated on this Mac as you type, between the two languages you choose; Return saves the translation to the tab's recent translations (the last 50, kept on this Mac) and ⌘P saves it and pastes it. With the field empty, the highlighted recent translation shows in full beside the list; Return or ⌘C copies it, ⌘P pastes it, and the detail's Read Aloud button or Space reads it aloud in a macOS voice. Delete removes the highlighted row (in Snippets, Dictation, and Translate it asks first), and copies confirm with a brief notice that grows out of the notch.

Keystrokes, once you turn it on in Settings › Plugins, shows the shortcuts you press on screen for demos, recordings, and screen sharing: Keybumps-style keycaps with the action's name ("Copy" with ⌘C), or KeyCastr's classic bezel, at the bottom left, center, or right of the screen with the pointer, with the last one or two above the newest. By default it shows only shortcuts (⌘ or ⌃, or ⌥ with a key that types nothing, such as ⌥←); All keys also shows typing. Nothing shows while you type a password, and a screenshot shortcut clears the screen, so the keys are never in the screenshot. It can show a ring where you click, and it needs Input Monitoring. Its Show & Hide Keystrokes shortcut starts unassigned.

Screenshot Tools takes screenshots with its own hotkeys (⇧⌘2 every screen, ⇧⌘3 every screen then edit, ⇧⌘4 a selected area; it needs Screen Recording and temporarily takes over macOS's own ⇧⌘3/⇧⌘4), and adds those and macOS's ⇧⌘5 screenshots to Clipboard History and the ⌘3 Screenshots grid. New screenshots also go on the clipboard unless that's turned off in Screenshot Tools settings or you've copied something since the screenshot was saved; ⇧⌘3 copies only when you Save, so an unredacted shot never lands there. In the ⌘3 grid, Return copies a screenshot, as in the Clipboard tab, and ⌘Return (or ⌘E on any image) opens a lightweight editor with blur, redact, arrow, draw, and text; Save (Return) copies the flattened image and saves `<name> (edited).png` beside the original, and Cancel (Esc) discards it.

Screencast, which ships off and needs macOS 15, is being built to record the screen as a screenshot or a video, with your voice and the Mac's sound, and keep each capture on this Mac under `~/Documents/Keybumps/captures/<timestamp>/` ([ADR 0009](docs/adr/0009-screencast-records-and-sends-captures.md)). So far, Settings › Screencast sets up its permissions, its sound and recording preferences, and its Start Screencast shortcut (unassigned; for now it opens that page).

Clipboard writes Keybumps makes for you stay out of Clipboard History: Dictation insertion, transcript copies from the Dictation tab, copies from the Snippets, Emoji, and Translate tabs and of emoji in Quick Search, ⌘P pastes, keyword expansion, the copy made when a paste can't go through, and putting your clipboard back afterwards. A copy you make yourself, in any app, is normal clipboard activity.

Each completed dictation is stored locally under `~/Documents/Keybumps/recordings/<timestamp>/` with `meta.json` transcript metadata and playable `output.wav` audio. The dedicated Dictation History screen supports search, playback, copy, Finder reveal, and deletion.

On macOS 15 or newer, each expanded history card can open Keybumps's on-device translation panel for immediate target-language selection, translated-text copying, and optional spoken playback using an installed macOS voice without changing the original transcript.

Keybumps sends crash and freeze reports to its developers through Sentry, never with user content, and Settings › General turns them off. Report a Problem… (Help menu, menu bar menu, Settings › General) sends a description the person writes, with the Mac's details ([ADR 0007](docs/adr/0007-crash-reports-to-sentry.md)).

Dictation records for up to five minutes by default. Dictation settings provide 10, 15, 30, and 60-minute limits plus No Limit. Keybumps transcribes the completed local WAV so pauses or early live results do not truncate the remainder of the session. After inserting, Dictation puts back what was on the clipboard unless something else was copied meanwhile; Settings › Dictation turns that off.

## Brand assets

`brand/` holds the approved Keybumps brand pack (see `brand/README.md`): the keycap logo with the mascot, the standalone mascot, and platform exports. The macOS app icon is an Icon Composer file, `apps/macos/Keybumps/Resources/Keybumps.icon` (the 3D keycap and the mascot as separate layers on a purple gradient); Xcode compiles it into the asset catalog with fallbacks for older macOS. Edit it in Icon Composer and copy it to `brand/apple/macos/Keybumps.icon`. The menu-bar item and small in-app marks use the standalone mascot as a template image (`KeybumpsMascot.imageset`, cropped from `brand/monochrome/mascot-dark.png`). The `web/` and `social/` exports are for keybumps.app.

## Build and run

The Mac app lives in `apps/macos/`: its sources, tests, Xcode project (`project.yml`), scripts, and bundled licenses. Commands below run from the repository root unless they `cd` first. Requirements: Apple Silicon Mac, macOS 14.2+, Xcode, and XcodeGen.

```sh
apps/macos/scripts/build-and-run.sh
```

Run deterministic tests:

```sh
cd apps/macos
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps -configuration Debug -derivedDataPath .derived test
```

Build, install, and launch a Developer ID-signed manual-QA candidate for an issue (backs up the installed app first):

```sh
apps/macos/scripts/build-qa-candidate.sh <issue-number>
apps/macos/scripts/restore-previous-keybumps.sh   # roll back
```

Releases are Developer ID-signed and notarized, licensed with Polar license keys ([ADR 0002](docs/adr/0002-polar-native-license-keys.md)), and updated through Sparkle ([update operations](docs/releases/sparkle-update-operations.md)). QA candidates are never notarized or published.

## Website

`apps/web/` holds the keybumps.app website (Next.js on Cloudflare Workers through OpenNext). It is separate from the Mac app, with its own pnpm project, CI (`.github/workflows/web.yml` checks pull requests, and `web-deploy.yml` deploys after merge), and agent instructions (`apps/web/AGENTS.md`). Release-please skips a commit only if every file it touches is under `apps/web/`, so website PRs change only `apps/web/**`; a needed root change goes in a separate `chore:`, `docs:`, or `ci:` PR. Run `pnpm install && pnpm check` from `apps/web/`; see `apps/web/README.md`.

## Attribution

Window Manager behavior is derived from the MIT-licensed Rectangle project and the owner's independently identified fork. See `apps/macos/LICENSE.rectangle` and `docs/provenance/donor-ledger.md`.

Screenshot Tools redaction and markup rendering is adapted from the MIT-licensed Shotnix project. See `apps/macos/LICENSE.shotnix` and `docs/provenance/donor-ledger.md`.

Timer's duration parsing is adapted from the MIT-licensed Tock project. See `apps/macos/LICENSE.tock` and `docs/provenance/donor-ledger.md`. The Emoji Picker's emoji, names, and keywords come from Unicode and CLDR, and its `:shortcode:` aliases from GitHub's gemoji; see `apps/macos/LICENSE.unicode`, `apps/macos/LICENSE.gemoji`, and the donor ledger.

Local Whisper transcription uses the OpenAI Whisper model family, run by the MIT-licensed Argmax OSS Swift/WhisperKit package or, for Large v3 Turbo (Fast), by MIT-licensed whisper.cpp on the GPU ([ADR 0008](docs/adr/0008-dictation-on-whisper-cpp.md)). See `apps/macos/LICENSE.argmax-oss-swift`, `apps/macos/NOTICES.argmax-oss-swift`, `apps/macos/LICENSE.whisper-cpp`, and `apps/macos/LICENSE.openai-whisper`.

Crash reports use the MIT-licensed Sentry Cocoa SDK. See `apps/macos/LICENSE.sentry-cocoa`.

Keystrokes' key names and its lines that stack and fade are adapted from the BSD-3-Clause KeyCastr project, and its overlay window from the BSD-3-Clause Snapzy project. See `apps/macos/LICENSE.keycastr`, `apps/macos/LICENSE.snapzy`, and `docs/provenance/donor-ledger.md`.
