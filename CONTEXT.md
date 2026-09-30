# Keybumps domain

Keybumps is one installed native macOS companion made of independently enabled capabilities that share common app surfaces.

## Language

### App shell

**Capability**:
A user-enabled area of Keybumps that delivers one coherent outcome and owns its own resources and shortcuts.
_Avoid_: Mini-app, embedded app, feature

**Capability Module**:
The internal, first-party unit that implements one Capability for the app shell.
_Avoid_: Plugin, extension

**Command Palette**:
The single floating, keyboard-first surface whose tabs present the capabilities' searchable content.
_Avoid_: Quick Search panel, Clipboard panel, Alfred clone, Raycast clone

**Notch notice**:
A brief, self-dismissing message that grows out of the notch, or the top of the menu bar on screens without one.
_Avoid_: Toast, HUD, banner

**Settings**:
The Keybumps window where capabilities are turned on and configured. Quick Search and the Command Palette offer it as Keybumps Settings.
_Avoid_: Preferences, Settings panel

### Capabilities

**Quick Search**:
Finding and opening local applications, files, and folders, and running Quick Search commands; the default Command Palette tab.
_Avoid_: Web search, workflow launcher

**Quick Search command**:
A Keybumps action that Quick Search offers beside applications, files, and folders, shown as the kind Command: Keybumps Settings, or a capability command.
_Avoid_: Workflow, extension command

**Capability command**:
The Quick Search command named for a capability, which goes to it: its Command Palette tab, or its Settings page when it has no tab or is turned off.
_Avoid_: Plugin, extension, navigation command

**Clipboard History**:
The recent text and image items the user copied, kept locally.
_Avoid_: Permanent clipboard archive, Dictation History duplicate

**Source app**:
The app a Clipboard History item was copied from, as far as macOS lets Keybumps tell. Screenshots and items from other devices have none.
_Avoid_: Origin, source (alone; a screenshot's original file is its source file)

**Source domain**:
The website a Clipboard History item was copied from, kept as its domain name only, when the app it came from (a browser, or an app built on one) says which page it was. IP addresses, single-label names such as `localhost`, and local or special-use names (`.local`, `.test`, `.invalid`, `.internal`, `.arpa`) aren't websites and have none.
_Avoid_: Source URL, page address (the full address is never kept)

**Dictation**:
A session that records speech, transcribes it locally, and inserts the text at the original cursor.
_Avoid_: Voice guide, assistant

**Dictation History**:
The local archive of completed Dictation recordings and their transcripts.
_Avoid_: Cloud transcript

**Window Manager**:
Moving and sizing windows with shortcuts.
_Avoid_: Rectangle app, Window Management

**Shortcut Coach**:
Recognition of actions the user did by hand that have a keyboard shortcut, with a history of them.
_Avoid_: Keyboard Shortcutter (former name; code types still use it), Shortcut Coaching, Keylume app

**Hotkeys**:
The Command Palette tab label for Shortcut Coach history; everywhere else, including its capability command, it is called Shortcut Coach.

**Screenshot Tools**:
Taking screenshots and marking them up.
_Avoid_: Screen capture, screenshot app, CleanShot clone

**Screenshots tab**:
The Command Palette tab showing screenshot items from Clipboard History.
_Avoid_: Screenshot library, gallery

**Screenshot Editor**:
The Screenshot Tools window for marking up a screenshot.
_Avoid_: Image editor, annotation app, Markup

### Licensing

**License Check**:
The app's cached result of its last successful License validation.
_Avoid_: Lease, token, license file

**Locked**:
The app state without a valid License Check, in which capabilities do not run.
_Avoid_: Trial mode, demo mode, unregistered
