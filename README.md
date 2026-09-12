# SuperMac

SuperMac is a native macOS utility combining local Quick Search, bounded Clipboard History, on-device Dictation, Window Management, and Shortcut Coaching in one app. Search, Clipboard History, and Dictation History share one three-tab keyboard-first Command Palette.

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
