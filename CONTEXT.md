# Keybumps domain

Keybumps is one installed native macOS companion made of independently enabled capabilities that share common app surfaces.

## Language

### App shell

**Capability**:
A user-enabled area of Keybumps that delivers one coherent outcome and owns its own resources and shortcuts. People see it as a **plugin**. Code and docs say capability for the module and what it does, and plugin for what it declares to people: its manifest (`PluginManifest.swift`), its preferences (stored as `plugin.<capability>.<key>`), its Settings page (`PluginSettingsPage`), and its listing on the website (ADR 0006).
_Avoid_: Mini-app, embedded app, feature, extension

**Plugin**:
What people see a capability called: in Settings › Plugins, in Quick Search, and on the website's Plugins page.
_Avoid_: Extension, add-on, app

**Plugin manifest**:
What a capability declares about itself, so the shell draws its Settings page, its row on the Plugins page, and its listing on the website the same way for every plugin: its name, summary, icon, and category; its commands (palette tab and shortcuts); the permissions it needs, and those it can use (optional, with why); whether it ships on; and its preferences, each a typed setting. Keybumps's version of a Raycast extension's manifest.
_Avoid_: Plist, config, schema

**Plugins page**:
Two places with one name. In the app, Settings › Plugins lists every plugin with its switch; Quick Search's Plugins command opens it. A turned-off plugin's own page says so at the top, with a Turn On button. On the website, keybumps.app/plugins lists every plugin with a page for each, and Settings › Plugins links to it ("Browse on keybumps.app"). For now every plugin is official, built by Keybumps, and ships in the app.
_Avoid_: Store, marketplace, gallery

**Capability Module**:
The internal, first-party unit that implements one Capability for the app shell.
_Avoid_: Extension

**Command Palette**:
The single floating, keyboard-first surface whose tabs present the capabilities' searchable content.
_Avoid_: Quick Search panel, Clipboard panel, Alfred clone, Raycast clone

**Notch notice**:
A brief, self-dismissing message that grows out of the notch, or the top of the menu bar on screens without one.
_Avoid_: Toast, HUD, banner

**Default capability**:
One of the seven capabilities Keybumps's feature set was locked at: Quick Search, Clipboard History, Screenshot Tools, Dictation, Window Manager, Shortcut Coach, and Snippets.
_Avoid_: Core plugin, built-in plugin

**Added capability**:
A capability added after the default set, starting with Timer. Settings lists added capabilities in their own group below the default ones.
_Avoid_: Plugin, extension, add-on

**Settings**:
The Keybumps window where capabilities are turned on and configured. Quick Search and the Command Palette offer it as Keybumps Settings.
_Avoid_: Preferences, Settings panel

**What's New**:
A release's notes for the people who use Keybumps, shown once in their own window after that release installs.
_Avoid_: Release notes window, changelog

**Changelog**:
Releases' What's New, newest first, in two places with one name. In the app, it's the Settings page with Keybumps' update status and the What's New of the installed release and earlier ones; the Version History button in the up-to-date alert opens it. On the website, keybumps.app/changelog/ lists every published release that has notes. The repository's `CHANGELOG.md` is a different thing: the developers' commit log that release notes are drafted from.
_Avoid_: Version history, release history, updates page

**Crash report**:
What Keybumps sends its developers through Sentry when it crashes or freezes, unless the person turned it off: versions, the Mac's model, which plugins are on, and stack traces, never user content (ADR 0007).
_Avoid_: Telemetry, analytics, tracking

**Problem report**:
What a person sends with Report a Problem…: their description, an optional email for a reply, and the same details a crash report carries plus permission states, the main ones shown before sending (ADR 0007).
_Avoid_: Feedback, bug report, ticket

### Capabilities

**Quick Search**:
Finding and opening local applications, files, and folders, finding snippets by keyword or name and emoji by name (while Emoji Picker shows them there), and running Quick Search commands; the default Command Palette tab.
_Avoid_: Web search, workflow launcher

**Quick Search command**:
A Keybumps action that Quick Search offers beside applications, files, and folders, shown as the kind Command: Keybumps Settings, Plugins, or a capability command.
_Avoid_: Workflow, extension command

**Capability command**:
The Quick Search command named for a capability, which goes to it: its Command Palette tab, or its Settings page when it has no tab or is turned off.
_Avoid_: Plugin, extension, navigation command

**Recent Items**:
The apps, files, and folders the user recently opened from Quick Search, listed while its search is empty. Quick Search commands never become Recent Items, and Keybumps itself is never listed.
_Avoid_: History, recents

**Learned usage**:
How often and how recently the user picked each app or Quick Search command from Quick Search, kept locally per item and used only to rank results: what the user picks more rises, weighed against how well each result matches the query. It is never listed, and no query is kept.
_Avoid_: Search history, frecency

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
A session that records speech, transcribes it locally, and inserts the text at the original cursor. It inserts through the clipboard, kept out of Clipboard History, then puts the clipboard back unless something else was copied meanwhile; turning off Put the clipboard back after inserting, in Settings › Dictation, leaves the transcript there. The Dictation tab's ⌘P leaves the transcript on the clipboard either way.
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
The Command Palette tab showing screenshot items from Clipboard History. Clearing or deleting a screenshot in the Clipboard tab keeps it here; only this tab's Clear All or Delete removes it.
_Avoid_: Screenshot library, gallery

**Screenshot Editor**:
The Screenshot Tools window for marking up a screenshot.
_Avoid_: Image editor, annotation app, Markup

**Snippets**:
Saving text you reuse, then copying or pasting it from the Command Palette.
_Avoid_: Clippings, text library, plugin

**Snippet**:
A named piece of text the user saved to reuse, kept locally.
_Avoid_: Clipping, template, abbreviation

**Keyword**:
A short word, such as `;ship`, that finds a snippet in search and, with auto-expansion on, expands to it as you type. It's shown as a code-style chip.
_Avoid_: Abbreviation, shortcut (a key combination), tag

**Auto-expansion**:
Replacing a snippet's keyword with the snippet as you type it in another app, then putting the clipboard back. Off until turned on in Settings › Snippets (ADR 0004).
_Avoid_: Text expansion, autocorrect, abbreviation expansion

**Sensitive snippet**:
A snippet whose text is hidden in the Command Palette and Settings, left out of search, and kept in the Keychain instead of the snippets file.
_Avoid_: Secret, password snippet

**Snippets tab**:
The Command Palette tab (⌘5) that lists snippets. Return or ⌘C copies one and ⌘P pastes it into the app in front.
_Avoid_: Snippet library, snippet manager

**Timer**:
Counting down from a duration you type, and being told when it ends.
_Avoid_: Alarm, reminder, stopwatch, pomodoro

**Timer alarm**:
The card that stays at the top of the screen when a timer ends, ringing unless sound is off, until Stop, Repeat, or the Timers tab.
_Avoid_: Notification, banner, popup

**Timers tab**:
The Command Palette tab (⌘6) where you type a duration such as `5m` or `tea 25` to start a timer, and pause, restart, or delete the timers listed under it.
_Avoid_: Timer list, timer manager

**Emoji Picker**:
Finding an emoji by its name, a keyword, or its `:shortcode:`, then copying it or pasting it into the app you're using. The first plugin that ships off; it's turned on in Settings › Plugins or with Turn On on its page.
_Avoid_: Emoji keyboard, character viewer

**Emoji tab**:
The Command Palette tab (⌘7) for the Emoji Picker: a grid of recent emoji and Unicode's groups to browse, or a ranked list once you type. Return or ⌘C copies; ⌘P pastes and puts the clipboard back.
_Avoid_: Emoji grid, emoji search

**Recent emoji**:
The emoji you picked most recently, shown first in the Emoji tab. User content, kept only on this Mac (`emoji-recent.json`) and never logged; turning off "Remember recently used emoji" clears them.
_Avoid_: Frequently used, history

**Translation**:
Translating text between your two languages on this Mac, with Apple's Translation. It ships off, and needs macOS 15: on an older Mac it's listed with "Requires macOS 15" and can't be turned on.
_Avoid_: Translator, Translate (the tab's name)

**Translate tab**:
The Command Palette tab (⌘8) for Translation: what you type or paste in the search field, translated as you type. Return saves the translation to recent translations and clears the field; ⌘P saves it and pastes it, then puts the clipboard back. ⌘T or the swap button translates the text the other way, and the target language in the header is a menu for picking another; either lasts until the text changes. A target picked for text detected in my language also becomes Other language. With the field empty, it lists recent translations.
_Avoid_: Translation window, translator

**Recent translations**:
The last 50 translations saved with Return or ⌘P in the Translate tab, newest first, listed there while the search field is empty, with the highlighted one in full beside the list, as in the Dictation tab. Return or ⌘C copies one, kept out of Clipboard History; ⌘P pastes it; Delete asks, then deletes it; and Read Aloud, or Space, reads it aloud in an installed voice for its language, or says there's none. User content, kept only on this Mac (`recent-translations.json`) and never logged. Turning Translation off keeps them; Clear Recent Translations in its settings removes them.
_Avoid_: Translation history, favorites, phrasebook

**Language pair**:
Translation's My language and Other language, never the same: text in my language is translated into the other, and text in any other language into mine. Dictation's Translate uses it while Translation is on, and English and Japanese otherwise.
_Avoid_: Source and target (one translation's languages), target language setting

**Keystrokes**:
Showing the shortcuts you press on screen, for demos, recordings, and screen sharing, through the key display, on the screen with the pointer. It ships off, and needs Input Monitoring. Unless Show is All keys it shows only shortcuts: ⌘ or ⌃ held, or ⌥ with a key that types nothing, such as an arrow. Nothing shows while you type a password, and a screenshot shortcut macOS or Keybumps knows clears it. Its Show & Hide Keystrokes shortcut hides the keys until it's pressed again.
_Avoid_: Show Keys (the design canvas's name), KeyCastr, key overlay

**Key display**:
The keys on screen that the Keystrokes plugin and a Screencast recording share. Only one shows however many hold it: it takes the most recent holder's look, shows only shortcuts if any holder asks for that, and while a recording holds it, shows on its screens, inside the area or window it records, with its clicks setting. Pressing a screenshot shortcut macOS or Keybumps knows clears it at once. A keystroke stays in memory only while it's on screen, and is never logged or stored.
_Avoid_: Keycast, overlay, HUD, bezel (one of its two styles)

**Screencast**:
Recording what's on screen, as a screenshot or a video with the microphone and the Mac's sound, then keeping each capture on this Mac or sending it to a destination (ADR 0009). It ships off, and needs macOS 15: on an older Mac it's listed with "Requires macOS 15" and can't be turned on.
_Avoid_: Screen recorder, screen recording (macOS's permission), Clipy (a destination)

**Capture**:
One screenshot or one recording Screencast took, kept on this Mac in a folder of its own until the person deletes it, or sends it and has the copy deleted; a recording of every screen holds one video per display. A screenshot taken with Screenshot Tools isn't one.
_Avoid_: Clip, video (one display's file in a recording), screencast (the plugin)

**Screencast picker**:
What Start Screencast opens over every screen to choose a capture: an area to drag, a window to click, or a screen (one clicked, or every screen), as a screenshot or a video, with switches for the microphone, the Mac's sound, shortcuts, and clicks that start as Settings › Screencast has them. Record counts a video down; Capture takes a screenshot at once. Escape cancels until recording starts. It opens with the last area drawn.
_Avoid_: Selection overlay, capture HUD, crosshair, Screenshot Tools' area selection (macOS's own)

**Control bar**:
The floating bar on the recorded screen while Screencast records, never in the video: the time recorded, Pause and Resume, Draw, the microphone and the Mac's sound, Restart, Discard, and Stop. Restart and Discard ask in the bar first ("Restart?" or "Discard?", with Keep). It stays where it was dragged on each screen. While recording, the time also shows beside the menu bar icon, with Stop and Pause in its menu.
_Avoid_: HUD, toolbar, recording panel, status bar (macOS's menu bar)

**Drawing**:
Marking up the screen while Screencast records, in the video: a pen, an arrow, a highlighter, or a rectangle, in a few colors, each mark fading a few seconds after it's drawn or staying until cleared. Draw on the control bar, or its shortcut, turns it on and off; while it's on, the recorded screens take the pointer, with a yellow border that isn't in the video, the drawing tools show above the control bar, and Escape stops, Delete clears, and ⌘Z undoes the last mark. The tools' choices carry over to the next recording; the marks don't.
_Avoid_: Annotation (the Screenshot Editor's marks), ink, markup, telestrator

**Review panel**:
The panel in the corner of the screen after each capture, asking what to do with it. It has a one-line note, the type (Bug, Feature, or Feedback), the repository, and the destination. A recording can be trimmed, and a screenshot opens in the Screenshot Editor and can also go to the Screenshots tab (⌘3). Save keeps the capture with its note; Copy keeps it and puts it on the clipboard, kept out of Clipboard History; Discard asks, then deletes it. Return saves, and Escape or closing it saves too. The note, type, repository, and the app it was taken in are user content, kept in the capture's `meta.json` on this Mac.
_Avoid_: Quick access card, post-capture window, editor

**Repository guess**:
The GitHub repository (`owner/name`) the review panel fills in, from the app in front when the capture started and, for a browser, the website's domain or a local development site such as `localhost:3000`. Once the person corrects it, the correction is remembered for that website, or the app, on this Mac only.
_Avoid_: Repo mapping, project, target

**Destination**:
An account of the person's own, connected in Settings › Screencast, that a capture goes to only when the person sends it. Each is built into Keybumps, Clipy first.
_Avoid_: Integration, upload target, share service

### Licensing

**License Check**:
The app's cached result of its last successful License validation.
_Avoid_: Lease, token, license file

**Locked**:
The app state without a valid License Check, in which capabilities do not run.
_Avoid_: Trial mode, demo mode, unregistered
