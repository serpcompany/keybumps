# Keybumps domain

Keybumps is one installed native macOS companion with six independently enabled capabilities presented through shared app surfaces.

## Language

**Capability**:
A user-enabled area providing one coherent outcome. Disabling it stops the resources and shortcuts it owns.
_Avoid_: Mini-app, embedded app

**Capability Module**:
The first-party unit that implements one Capability and is registered with the app shell: a descriptor (names, icon, required permissions, dependencies, optional Command Palette tab, Settings page, onboarding card, and update-safety operations) plus the runtime owner of its resources and shortcuts. Internal only; not an extension point.
_Avoid_: Plugin, extension, mini-app

**Command Palette**:
The single floating, keyboard-first surface with Search, Clipboard, Dictation, Hotkeys, and Screenshots tabs.
_Avoid_: Quick Search panel, Clipboard panel, Alfred clone, Raycast clone

**Quick Search**:
The default Command Palette tab for finding local applications, files, and folders.
_Avoid_: Web search, workflow launcher

**Clipboard History**:
The Command Palette tab containing the fifty most recent user-originated local text or image clipboard items, with visual previews for images. Keybumps's temporary pasteboard writes for automatic Dictation delivery are not clipboard activity.
_Avoid_: Permanent clipboard archive, Dictation History duplicate

**Dictation**:
The Option-Space session that records speech, transcribes locally, and inserts text at the original cursor.
_Avoid_: Voice guide, assistant

**Dictation History**:
The local per-recording archive of completed Dictation transcripts and playable audio, shown in its dedicated History screen and exposed for transcript reuse in the Command Palette.
_Avoid_: Cloud transcript, monolithic history file

**Window Management**:
Rectangle-derived window movement and sizing under the owner's selected shortcuts.
_Avoid_: Rectangle app

**Keyboard Shortcutter**:
Passive recognition of currently supported manual actions, durable history, and selected presentations.
_Avoid_: Shortcut Coach, Shortcut Coaching, Keylume app

**Hotkeys**:
The Command Palette tab label for Keyboard Shortcutter history. Settings and the capability keep the name Keyboard Shortcutter.

**Screenshot Tools**:
The capability that adds screenshots macOS saves (Shift-Command-3/4/5) to Clipboard History as screenshot items and owns the **Screenshot Editor**. It never captures the screen itself.
_Avoid_: Screen capture, screenshot app, CleanShot clone

**Screenshots tab**:
The ⌘5 Command Palette tab listing screen-capture items from Clipboard History; Return opens the Screenshot Editor. Owned by Screenshot Tools.
_Avoid_: Screenshot library, gallery

**Screenshot Editor**:
The Screenshot Tools window that marks up a Clipboard History image with pixelate, redact, arrow, draw, and text, then copies the flattened result and saves an `(edited)` copy.
_Avoid_: Image editor, annotation app, Markup

**Development License Adapter**:
An explicit non-production local gate used only to exercise onboarding before a commerce provider is chosen.
_Avoid_: License, activation
