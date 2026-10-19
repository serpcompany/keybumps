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
The single floating, keyboard-first surface whose tabs present the capabilities' searchable content. One click on a row does what Return does, except in the tabs that show the highlighted row's actions (Dictation, Translate, and ScreenGrabs), where it highlights the row and a double-click does what Return does, and in the Hotkeys tab, whose rows have no Return action, where it only highlights. Moving the pointer over a row highlights it, as in Raycast, except in those four tabs: there the highlight, and with it the detail, the footer, and the keys, follows only clicks and keys, and the row under the pointer is only outlined, so the pointer crossing a row on its way to the detail's buttons never changes which row they act on.
_Avoid_: Quick Search panel, Clipboard panel, Alfred clone, Raycast clone

**Notch notice**:
A brief, self-dismissing message that grows out of the notch, or the top of the menu bar on screens without one.
_Avoid_: Toast, HUD, banner

**Default capability**:
One of the seven capabilities Keybumps's feature set was locked at: Quick Search, Clipboard History, ScreenGrabs (then Screenshot Tools), Dictation, Window Manager, Shortcut Coach, and Snippets.
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
Finding and opening local applications, files, and folders, finding snippets by keyword, name, or text and emoji by name (while Emoji Picker shows them there), and running Quick Search commands; the default Command Palette tab.
_Avoid_: Web search, workflow launcher

**Quick Search command**:
A Keybumps action that Quick Search offers beside applications, files, and folders: Keybumps Settings, Plugins, or a capability command, shown as the kind Command, or an action command, shown as the kind Action.
_Avoid_: Workflow, extension command

**Action command**:
A Quick Search command that does something a plugin does, rather than going somewhere, such as Record Screen or Hide Keystrokes. It's listed only while its plugin is on, and not while it would do nothing, such as Record Screen during a recording, or where ScreenGrabs can't record. Picking it closes the palette and does it, as the plugin's shortcut would, and opens the plugin's page when a permission it needs is missing.
_Avoid_: Quick action, workflow, shortcut (a key combination), command (alone)

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
The recent text and image items the user copied, kept locally: the newest 50 that aren't screenshots, and apart from them the newest 50 screenshot items, so copying never pushes out a screenshot and a screenshot never pushes out a copy. The Clipboard tab lists the newest 50 that match its filter and search, leaving out screenshots cleared or deleted there.
_Avoid_: Permanent clipboard archive, Dictation History duplicate

**Source app**:
The app a Clipboard History item was copied from, as far as macOS lets Keybumps tell. Screenshots and items from other devices have none.
_Avoid_: Origin, source (alone; a screenshot's original file is its source file)

**Source domain**:
The website a Clipboard History item was copied from, kept as its domain name only, when the app it came from (a browser, or an app built on one) says which page it was. IP addresses, single-label names such as `localhost`, and local or special-use names (`.local`, `.test`, `.invalid`, `.internal`, `.arpa`) aren't websites and have none.
_Avoid_: Source URL, page address (the full address is never kept)

**Dictation**:
A session that records speech, transcribes it locally, and inserts the text at the original cursor. It inserts through the clipboard, kept out of Clipboard History, then puts the clipboard back unless something else was copied meanwhile; turning off Put the clipboard back after inserting, in Settings › Dictation, leaves the transcript there. The Dictation tab's ⌘V leaves the transcript on the clipboard either way.
_Avoid_: Voice guide, assistant

**Recognition language**:
Dictation's language, in Settings › Dictation: **Automatic**, the default, or one language someone chose. With Automatic, a multilingual Whisper model detects the language of each recording, and Dictation History records the one it detected; Apple Speech uses the Mac's language (English if its on-device speech doesn't support it), and Whisper Medium English uses English.
_Avoid_: Input language, auto-detect setting

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

**ScreenGrabs**:
Taking screenshots and recordings of the screen, and marking screenshots up (ADR 0010). It replaced Screenshot Tools and Screencast, and ships on. Recording needs macOS 15; on an older Mac, ScreenGrabs takes screenshots only and says "Recording needs macOS 15". Its stored ID is still `screenshotTools`; its screenshot code is in `ScreenshotTools/` and its recording code, whose types keep Screencast's name, in `Screencast/`.
_Avoid_: Screenshot Tools and Screencast (former names), Screengrabs (lowercase g), screen grabs, screen capture, CleanShot clone

**Screengrab**:
One screenshot or one recording that ScreenGrabs took.
_Avoid_: Capture, clip, grab

**Screenshot**:
A PNG of the screens or an area, taken with ScreenGrabs' hotkeys, in the Screenshots folder, or with macOS's own, in the folder macOS saves screenshots to.
_Avoid_: Snap

**Screenshots folder**:
Where ScreenGrabs' hotkeys and the Screenshot Editor save screenshots: the folder chosen in Settings › ScreenGrabs, or, until one is, the folder macOS saves screenshots to (else the Desktop), following macOS's setting. A chosen folder that's gone or can't be written to stays chosen, and screenshots go to the default until it's back.

**ScreenGrabs tab**:
The Command Palette tab (⌘3) showing Clipboard History's newest 50 screenshot items and every recording in the recordings index, newest first (#494). Recordings show with Clipboard History off, and the header says why screenshots don't; on macOS 14 it shows screenshots only. Its grid has two columns, with the highlighted screengrab in full beside it, as in the Dictation tab (#552): its picture, a button for each of its actions with the keys that do the same, its name, and its information (Dimensions, Taken, and Size, or a recording's Length, Displays, Taken, and Size); until Down or a click highlights one, it says how to show one there. A click highlights a screengrab; a double-click or Return copies it, and a ⌘-click edits it. Clearing or deleting a screenshot in the Clipboard tab keeps it here; only this tab's Clear All or Delete, or 50 newer screenshots, remove it. Delete on a recording asks, then moves its folder to the Trash; Clear All leaves recordings. A recording moved or deleted outside Keybumps stays, marked "Moved or deleted", until it's removed.
_Avoid_: Screenshots tab (its former name), screenshot library, gallery

**Screenshot Editor**:
The ScreenGrabs window for marking up a screenshot.
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
The Command Palette tab (⌘5) that lists snippets. Return or ⌘C copies one, ⌘V pastes it into the app in front, and ⌘E edits it.
_Avoid_: Snippet library, snippet manager

**Timer**:
Counting down from a duration you type, and being told when it ends.
_Avoid_: Alarm, reminder, stopwatch, pomodoro

**Timer alarm**:
The card that stays at the top of the screen when a timer ends, ringing unless sound is off, until Stop, Repeat, or the Timers tab.
_Avoid_: Notification, banner, popup

**Timers tab**:
The Command Palette tab (⌘6) where you type a duration such as `5m` or `tea 25` to start a timer, and pause, restart, or delete the timers listed under it. A click on a row does what Return does.
_Avoid_: Timer list, timer manager

**Emoji Picker**:
Finding an emoji by its name, a keyword, or its `:shortcode:`, then copying it or pasting it into the app you're using. The first plugin that ships off; it's turned on in Settings › Plugins or with Turn On on its page.
_Avoid_: Emoji keyboard, character viewer

**Emoji tab**:
The Command Palette tab (⌘7) for the Emoji Picker: a grid of recent emoji and Unicode's groups to browse, or a ranked list once you type. A click, Return, or ⌘C copies; ⌘V pastes and puts the clipboard back.
_Avoid_: Emoji grid, emoji search

**Recent emoji**:
The emoji you picked most recently, shown first in the Emoji tab. User content, kept only on this Mac (`emoji-recent.json`) and never logged; turning off "Remember recently used emoji" clears them.
_Avoid_: Frequently used, history

**Translation**:
Translating text between your two languages on this Mac, with Apple's Translation. It ships off, and needs macOS 15: on an older Mac it's listed with "Requires macOS 15" and can't be turned on.
_Avoid_: Translator, Translate (the tab's name)

**Translate tab**:
The Command Palette tab (⌘8) for Translation: what you type or paste in the search field, translated as you type. Return saves the translation to recent translations and clears the field; ⌘Return saves it and pastes it, then puts the clipboard back. ⌘V pastes into the field, as in any text field. ⌘T or the swap button translates the text the other way, and the target language in the header is a menu for picking another; either lasts until the text changes. A target picked for text detected in my language also becomes Other language. With the field empty, it lists recent translations.
_Avoid_: Translation window, translator

**Recent translations**:
The last 50 translations saved with Return or ⌘Return in the Translate tab, newest first, listed there while the search field is empty, with the highlighted one in full beside the list, as in the Dictation tab. Return or ⌘C copies one, kept out of Clipboard History; its Paste button pastes it (⌘V stays the search field's in this tab); Delete asks, then deletes it; and Read Aloud, or Space, reads it aloud in an installed voice for its language, or says there's none. User content, kept only on this Mac (`recent-translations.json`) and never logged. Turning Translation off keeps them; Clear Recent Translations in its settings removes them.
_Avoid_: Translation history, favorites, phrasebook

**Language pair**:
Translation's My language and Other language, never the same: text in my language is translated into the other, and text in any other language into mine. Dictation's Translate uses it while Translation is on, and English and Japanese otherwise.
_Avoid_: Source and target (one translation's languages), target language setting

**Keystrokes**:
Showing the shortcuts you press on screen, for demos, recordings, and screen sharing, through the key display, on the screen with the pointer. It ships off, and needs Input Monitoring. Unless Show is All keys it shows only shortcuts: ⌘ or ⌃ held, or ⌥ with a key that types nothing, such as an arrow. Nothing shows while you type a password, and a screenshot shortcut macOS or Keybumps knows clears it. Its keys are **shown** or **hidden** apart from turning it on or off, and that acts on what's on screen now: hiding takes every key on screen away, a recording's included until that recording ends, and showing brings them back, a recording's in its own look. They stay hidden after a relaunch, and turning the plugin on shows them. Show keystrokes in its settings switches it, and can't change while the plugin is off. Show Keystrokes in the menu bar menu (checked while keys are on screen, a recording's included, which they can't be without Input Monitoring), the Show & Hide Keystrokes shortcut, and Quick Search's Show Keystrokes or Hide Keystrokes act on the screen: they hide the keys if any are on screen, or show them if none are, and switch it to match; the shortcut's notice says Keystrokes shown or Keystrokes hidden, or why the keys can't show.
_Avoid_: Show Keys (the design canvas's name), KeyCastr, key overlay; showing keystrokes or keys on screen (say shown)

**Key display**:
The keys on screen that the Keystrokes plugin and a recording share. Only one shows however many hold it: it takes the most recent holder's look, shows only shortcuts if any holder asks for that, and while a recording holds it, shows on its screens, inside the area or window it records, with its clicks setting. Hiding Keystrokes hides every holder's keys; a recording that starts later shows its own. Pressing a screenshot shortcut macOS or Keybumps knows clears it at once. A keystroke stays in memory only while it's on screen, and is never logged or stored.
_Avoid_: Keycast, overlay, HUD, bezel (one of its two styles)

**Recording**:
A video ScreenGrabs made of an area, a window, or the screens, with the microphone and the Mac's sound (ADR 0009), kept on this Mac in a folder of its own in the recordings folder until the person deletes it, or sends it to a destination and has the copy deleted; a recording of every screen holds one video per display. Record Screen (⇧⌘5, or Quick Search) starts one. A screenshot isn't one.
_Avoid_: Capture (Screencast's word, which also meant screenshots), screencast, video (one display's file), screen recording (macOS's permission; only the ⌘3 tile's name says "Screen Recording <date>", as macOS names its own recordings), Dictation's audio

**Recordings folder**:
Where recordings are saved, each in a folder of its own: the folder chosen in Settings › ScreenGrabs, apart from the Screenshots folder, or, until one is, the folder macOS saves screenshots to (else the Desktop). A chosen folder that's gone or can't be written to falls back the same way. Recordings saved before #504 stay in `~/Documents/Keybumps/captures` (`ProductPaths.captures`), still listed.
_Avoid_: Captures folder; Dictation's recordings folder (`ProductPaths.recordings`)

**Recordings index**:
ScreenGrabs' list of every recording it keeps, wherever it's saved, for the ScreenGrabs tab (`RecordingLibrary`): each recording's folder, start, length, and displays, never what the person wrote about it. A recording moved or deleted outside Keybumps stays listed, marked as moved or deleted.
_Avoid_: Captures index

**Recording picker**:
What Record Screen opens over every screen to choose a recording: an area to drag, a window to click, or a screen (one chosen by name in the bar or clicked, starting with the one with the pointer, or All Screens), with switches for the microphone, the Mac's sound, shortcuts, and clicks that are Settings › ScreenGrabs' own. Record counts down, then records. Escape closes the picker, and does nothing once Record is pressed: the countdown's Cancel stops a countdown, and only the control bar's Discard throws a recording away. It opens as Record last left it: area, window, or screen, the same screen or All Screens while connected, the last area drawn, and the switches, which Record saves to Settings (the microphone's only with Microphone access). A window is never remembered, so Window mode opens with none chosen.
_Avoid_: Screencast picker (its former name), selection overlay, capture HUD, crosshair, the screenshot hotkeys' area selection (macOS's own)

**Control bar**:
The floating bar on the recorded screen while recording, never in the video: the time recorded, Pause and Resume, Draw, the microphone and the Mac's sound, Restart, Discard, and Stop. Restart and Discard ask in the bar first ("Restart?" or "Discard?", with Keep). While the recording starts, only Discard works, cancelling the start. It stays where it was dragged on each screen. While recording, the time also shows beside the menu bar icon, with Stop and Pause in its menu.
_Avoid_: HUD, toolbar, recording panel, status bar (macOS's menu bar)

**Drawing**:
Marking up the screen while recording, in the video: a pen, an arrow, a highlighter, or a rectangle, in a few colors, each mark fading a few seconds after it's drawn or staying until cleared. Draw on the control bar, or its shortcut, turns it on and off; while it's on, the recorded screens take the pointer, with a yellow border that isn't in the video, the drawing tools show above the control bar, and Escape stops, Delete clears, and ⌘Z undoes the last mark. The tools' choices carry over to the next recording; the marks don't, and Restart clears them and the keys on screen before the new take starts.
_Avoid_: Annotation (the Screenshot Editor's marks), ink, markup, telestrator

**Recording window**:
What opens after each recording, asking what to do with it: a window that all but fills the screen with the recording's player (play, pause, and scrubbing), and Trim, Crop, Blur, Discard, Copy, and Save in its editor bar, with nothing to type. Trim opens a timeline under the player: its handles trim the ends, and a part selected on it is cut out with Cut Section; trimmed and cut parts stay on it, dimmed, to bring back. Crop puts one rectangle over the video for the whole recording, Free, 16:9, or 1:1. Blur draws mosaic blurs over the video, each with a bar on the timeline for when it shows. A trim applies to every display; a crop and blurs to the display picked. With edits, Save and Copy first export the edited recording, keeping the original until that's complete, and closing asks "Save your edits?" (Keep Original or Save Edited); the next recording starting, or quitting, keeps the original. Save keeps the recording; Copy keeps it and puts it on the clipboard, kept out of Clipboard History; Discard asks, then deletes it. Return saves and ⌘C copies; Escape, closing it, or starting the next recording saves too. Opened again from the ScreenGrabs tab on a saved recording, Discard is Move to Trash, which moves it to the Trash as Delete there does, and Save is Done, which only closes (or saves edits). The window closes then, and a notice in the notch says which folder it was saved to, that it was copied, or why it couldn't be saved; starting the next recording shows a notice only if it couldn't. The review it writes, the type, the guessed repository, and the app the recording was made in, is user content, kept in the recording's `meta.json` on this Mac.
_Avoid_: Review panel (its former name), quick access card, post-capture window, editor

**Editor bar**:
The bar along the top of the Screenshot Editor and the recording window: the window's tools on the left, then undo and redo and the window's actions, each with the key that also does it as a keycap, the main one filled with the accent color.
_Avoid_: Toolbar (macOS's, in a window's title bar)

**Repository guess**:
The GitHub repository (`owner/name`) the recording window fills in, from the app in front when the recording started and, for a browser, the website's domain or a local development site such as `localhost:3000`. Once the person corrects it, the correction is remembered for that website, or the app, on this Mac only.
_Avoid_: Repo mapping, project, target

**Destination**:
An account of the person's own, connected in Settings › ScreenGrabs, that a recording goes to only when the person sends it. Each is built into Keybumps, Clipy first.
_Avoid_: Integration, upload target, share service

### Licensing

**License Check**:
The app's cached result of its last successful License validation.
_Avoid_: Lease, token, license file

**Locked**:
The app state without a valid License Check, in which capabilities do not run.
_Avoid_: Trial mode, demo mode, unregistered

**Update year**:
The updates a License includes: every release made on or before its last day, a year after the key was bought (2027-10-19 for Licenses bought before 2026-10-19), or later if a Renewal paid for more. Its end never Locks the version a person has; a newer one shows in the app with Renew instead of Install (ADR 0011). In code, `UpdateYear` and its `lastDay`.
_Avoid_: Subscription, maintenance period, expiry, `updatesUntil` (ADR 0001's name)

**Renewal**:
Another year of updates for a License, bought on keybumps.app/pricing. It reaches the app as the Polar customer's `keybumps_updates_until`, never as a new key.
_Avoid_: Upgrade, resubscribe
