# Keybumps

Keybumps is a native macOS utility combining local Quick Search, bounded text-and-image Clipboard History, Screenshot Tools, on-device Dictation, Window Manager, and Keyboard Shortcutter in one app. Search, Clipboard History, Dictation History, Keyboard Shortcutter History (Hotkeys), and Screenshots share one five-tab keyboard-first Command Palette.

Screenshot Tools adds screenshots you take with Shift-Command-3/4/5 to Clipboard History and the ⌘5 Screenshots tab. Return (or ⌘E on any image) opens a lightweight editor with pixelate, redact, arrow, draw, and text; Done copies the flattened image and saves `<name> (edited).png` beside the original. Keybumps never captures the screen itself.

Automatic Dictation insertion and reuse from Dictation History are excluded from Clipboard History even though macOS pasteboard transport is used to deliver the text. An explicit user Copy remains normal clipboard activity.

Each completed dictation is stored locally under `~/Documents/Keybumps/recordings/<timestamp>/` with `meta.json` transcript metadata and playable `output.wav` audio. The dedicated Dictation History screen supports search, playback, copy, Finder reveal, and deletion.

On macOS 15 or newer, each expanded history card can open Keybumps's on-device translation panel for immediate target-language selection, translated-text copying, and optional spoken playback using an installed macOS voice without changing the original transcript.

Dictation records for up to five minutes by default. Dictation settings provide 10, 15, 30, and 60-minute limits plus No Limit. Keybumps transcribes the completed local WAV so pauses or early live results do not truncate the remainder of the session.

## Build and run

Requirements: Apple Silicon Mac, macOS 14.2+, Xcode, and XcodeGen.

```sh
./scripts/build-and-run.sh
```

Run deterministic tests:

```sh
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps -configuration Debug -derivedDataPath .derived test
```

Build, install, and launch a Developer ID-signed manual-QA candidate for an issue (backs up the installed app first):

```sh
./scripts/build-qa-candidate.sh <issue-number>
./scripts/restore-previous-keybumps.sh   # roll back
```

The local preview does not present fake commerce or update controls. Production licensing, signed updates, notarization, and customer packaging remain release gates.

## Attribution

Window Manager behavior is derived from the MIT-licensed Rectangle project and the owner's independently identified fork. See `LICENSE.rectangle` and `docs/provenance/donor-ledger.md`.

Screenshot Tools redaction and markup rendering is adapted from the MIT-licensed Shotnix project. See `LICENSE.shotnix` and `docs/provenance/donor-ledger.md`.

Local Whisper transcription uses the MIT-licensed Argmax OSS Swift/WhisperKit package and OpenAI Whisper model family. See `LICENSE.argmax-oss-swift`, `NOTICES.argmax-oss-swift`, and `LICENSE.openai-whisper`.
