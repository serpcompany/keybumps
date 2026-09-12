# Architecture

`SuperMacApp` and `AppModel` own composition and lifecycle. Feature services own behavior but never create another app delegate, status item, Settings scene, updater, license system, or launch-at-login controller.

The shared `GlobalShortcutCoordinator` is the sole Carbon hot-key registrar. `AppPreferences` persists the editable Quick Search, Clipboard History, Dictation, and Window Management bindings; assigning one key combination removes it from any previous owner before the coordinator re-registers the complete valid set. Dictation temporarily registers unmodified Escape only while Recording or Transcribing can still be cancelled before insertion. `PermissionCoordinator` centralizes truthful permission state and recovery. Each capability stops its service and releases its shortcut when disabled. `ClipboardHistoryService` excludes only the exact pasteboard change written by automatic Dictation delivery, so a subsequent user copy—even of identical text—is still captured.

`NativeStatusItemController` retains the SwiftUI main-window opener configured while the initial window is alive. The status menu, Dock reopen path, and Key Bumps menu panel call that persistent route directly, so closing the Settings window does not remove the only listener capable of recreating it.

`CommandPaletteController` owns one floating keyboard-first surface for Quick Search, Clipboard History, and Dictation History. Command-Space and Shift-Command-Space route into different tabs of that same surface. The palette tracks its native Clear History confirmation as an internal presentation, so sheet focus changes and alert-button clicks do not trigger outside-click dismissal. Clipboard retains bounded JSON persistence. `DictationHistoryService` owns the independently stored `~/Documents/SuperMac/recordings/<timestamp>/meta.json` and `output.wav` pairs; the dedicated Dictation History screen owns browsing and playback presentation.

Key Bumps retains its donor separation between Detection, Delivery, Infrastructure, Domain, and Views. Window frame calculations remain pure and separately testable from Accessibility execution. Dictation owns no guide or assistant behavior.
