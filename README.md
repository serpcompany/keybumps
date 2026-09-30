# Keybumps

Keybumps is a native macOS utility combining local Quick Search, bounded text-and-image Clipboard History, Screenshot Tools, on-device Dictation, Window Manager, and Shortcut Coach in one app. Search (⌘1), Clipboard History (⌘2), Screenshots (⌘3), Dictation History (⌘4), and Shortcut Coach History (Hotkeys, ⌘5, hidden by default) share one Raycast-style, keyboard-first Command Palette. Delete removes the highlighted row, and copies confirm with a brief notice that grows out of the notch.

Screenshot Tools takes screenshots with its own hotkeys (⇧⌘2 every screen, ⇧⌘3 every screen then edit, ⇧⌘4 a selected area; it needs Screen Recording and temporarily takes over macOS's own ⇧⌘3/⇧⌘4), and adds those and macOS's ⇧⌘5 screenshots to Clipboard History and the ⌘3 Screenshots grid. Return (or ⌘E on any image) opens a lightweight editor with pixelate, redact, arrow, draw, and text; Done copies the flattened image and saves `<name> (edited).png` beside the original.

Automatic Dictation insertion and reuse from Dictation History are excluded from Clipboard History even though macOS pasteboard transport is used to deliver the text. An explicit user Copy remains normal clipboard activity.

Each completed dictation is stored locally under `~/Documents/Keybumps/recordings/<timestamp>/` with `meta.json` transcript metadata and playable `output.wav` audio. The dedicated Dictation History screen supports search, playback, copy, Finder reveal, and deletion.

On macOS 15 or newer, each expanded history card can open Keybumps's on-device translation panel for immediate target-language selection, translated-text copying, and optional spoken playback using an installed macOS voice without changing the original transcript.

Dictation records for up to five minutes by default. Dictation settings provide 10, 15, 30, and 60-minute limits plus No Limit. Keybumps transcribes the completed local WAV so pauses or early live results do not truncate the remainder of the session.

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

The local preview does not present fake commerce or update controls. Production licensing, signed updates, notarization, and customer packaging remain release gates.

## Website

`apps/web/` holds the keybumps.app website (Next.js on Cloudflare Workers through OpenNext). It is separate from the Mac app, with its own pnpm project, CI (`.github/workflows/web.yml`), and agent instructions (`apps/web/AGENTS.md`). Release-please skips a commit only if every file it touches is under `apps/web/`, so website PRs change only `apps/web/**`; a needed root change goes in a separate `chore:`, `docs:`, or `ci:` PR. Run `pnpm install && pnpm check` from `apps/web/`; see `apps/web/README.md`.

## Attribution

Window Manager behavior is derived from the MIT-licensed Rectangle project and the owner's independently identified fork. See `apps/macos/LICENSE.rectangle` and `docs/provenance/donor-ledger.md`.

Screenshot Tools redaction and markup rendering is adapted from the MIT-licensed Shotnix project. See `apps/macos/LICENSE.shotnix` and `docs/provenance/donor-ledger.md`.

Local Whisper transcription uses the MIT-licensed Argmax OSS Swift/WhisperKit package and OpenAI Whisper model family. See `apps/macos/LICENSE.argmax-oss-swift`, `apps/macos/NOTICES.argmax-oss-swift`, and `apps/macos/LICENSE.openai-whisper`.
