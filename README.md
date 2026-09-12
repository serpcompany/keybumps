# SuperMac

SuperMac is a native macOS utility combining local Quick Search, bounded Clipboard History, on-device Dictation, Window Management, and Shortcut Coaching in one app. Search, Clipboard History, and Dictation History share one three-tab keyboard-first Command Palette.

Each completed dictation is stored locally under `~/Documents/SuperMac/recordings/<timestamp>/` with `meta.json` transcript metadata and playable `output.wav` audio. The dedicated Dictation History screen supports search, playback, copy, Finder reveal, and deletion.

On macOS 15 or newer, each expanded history card can open SuperMac's on-device translation panel for immediate target-language selection, translated-text copying, and optional spoken playback using an installed macOS voice without changing the original transcript.

Dictation records for up to five minutes by default. Dictation settings provide 10, 15, 30, and 60-minute limits plus No Limit. SuperMac transcribes the completed local WAV so pauses or early live results do not truncate the remainder of the session.

## Build and run

Requirements: Apple Silicon Mac, macOS 14.2+, Xcode, and XcodeGen.

```sh
./scripts/build-and-run.sh
```

Run deterministic tests:

```sh
xcodegen generate
xcodebuild -project SuperMac.xcodeproj -scheme SuperMac -configuration Debug -derivedDataPath .derived test
```

The local preview does not present fake commerce or update controls. Production licensing, signed updates, notarization, and customer packaging remain release gates.

## Attribution

Window Management behavior is derived from the MIT-licensed Rectangle project and the owner's independently identified fork. See `LICENSE.rectangle` and `docs/provenance/donor-ledger.md`.
