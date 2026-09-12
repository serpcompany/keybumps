# Architecture

`SuperMacApp` and `AppModel` own composition and lifecycle. Feature services own behavior but never create another app delegate, status item, Settings scene, updater, license system, or launch-at-login controller.

The shared `GlobalShortcutCoordinator` is the sole Carbon hot-key registrar. `AppPreferences` persists the editable Quick Search, Clipboard History, Dictation, and Window Management bindings; assigning one key combination removes it from any previous owner before the coordinator re-registers the complete valid set. `PermissionCoordinator` centralizes truthful permission state and recovery. Each capability stops its service and releases its shortcut when disabled.

`CommandPaletteController` owns one floating keyboard-first surface for Quick Search, Clipboard History, and Dictation History. Command-Space and Shift-Command-Space route into different tabs of that same surface; the Dictation settings screen can open the third tab. Clipboard and Dictation history services own their bounded local persistence independently of presentation.

Shortcut Coaching retains its donor separation between Detection, Delivery, Infrastructure, Domain, and Views. Window frame calculations remain pure and separately testable from Accessibility execution. Dictation owns no guide or assistant behavior.
