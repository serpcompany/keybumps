# Architecture

`SuperMacApp` and `AppModel` own composition and lifecycle. Feature services own behavior but never create another app delegate, status item, Settings scene, updater, license system, or launch-at-login controller.

The shared `GlobalShortcutCoordinator` is the sole Carbon hot-key registrar. `AppPreferences` persists the editable Quick Search, Clipboard History, Dictation, and Window Management bindings; assigning one key combination removes it from any previous owner before the coordinator re-registers the complete valid set. `PermissionCoordinator` centralizes truthful permission state and recovery. Each capability stops its service and releases its shortcut when disabled. `ClipboardHistoryService` excludes only the exact pasteboard change written by automatic Dictation delivery, so a subsequent user copy—even of identical text—is still captured.

`CommandPaletteController` owns one floating keyboard-first surface for Quick Search, Clipboard History, and Dictation History. Command-Space and Shift-Command-Space route into different tabs of that same surface. Clipboard retains bounded JSON persistence. `DictationHistoryService` owns the independently stored `~/Documents/SuperMac/recordings/<timestamp>/meta.json` and `output.wav` pairs; the dedicated Dictation History screen owns browsing and playback presentation.

Key Bumps retains its donor separation between Detection, Delivery, Infrastructure, Domain, and Views. Window frame calculations remain pure and separately testable from Accessibility execution. Dictation owns no guide or assistant behavior.
