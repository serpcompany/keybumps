# Changelog

## [0.0.3-beta.4](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.3...v0.0.3-beta.4) (2026-09-29)

This beta introduces the new Keybumps icon, adds Screenshot Tools, gives the Command Palette and Settings a Raycast-style look, adds notch notices, and renames Keyboard Shortcutter to Shortcut Coach.

> **This beta is not notarized.** It is signed with our Developer ID, but Apple notarization is temporarily unavailable. The first time you open a downloaded copy, macOS blocks it: open **System Settings › Privacy & Security** and click **Open Anyway** next to the Keybumps message. Updates inside the app install normally, and later releases will be notarized again.

### Screenshot Tools (new)

- Take screenshots with Keybumps hotkeys: ⇧⌘2 captures every screen, ⇧⌘3 captures every screen and opens the editor, and ⇧⌘4 captures a selected area. All three can be changed in Settings.
- While Keybumps uses ⇧⌘3 and ⇧⌘4, it turns off macOS's own versions and turns them back on when Screenshot Tools is off or the hotkey moves.
- Screenshots from these hotkeys and from macOS (⇧⌘5) appear in Clipboard History and in the new ⌘3 Screenshots tab, a grid of large thumbnails.
- Mark up any screenshot or copied image with pixelate, redact, arrow, draw, and text (keys 1–5). Done copies the result and saves an "(edited)" copy next to the original.
- The hotkeys need Screen Recording. Keybumps asks once, and Settings shows Allow and Restart Keybumps when it's still needed.

### Command Palette

- New Raycast-style look: a larger near-black window, search on top, outlined keycaps, and a floating action bar.
- Tabs are ⌘1 Search, ⌘2 Clipboard, ⌘3 Screenshots, and ⌘4 Dictation. The Hotkeys tab (⌘5) is hidden unless you turn it on in Shortcut Coach settings.
- Delete removes the highlighted item once the search field is empty; ⌘Delete works while typing.
- Copying shows "Copied to Clipboard" at the notch.
- Search results show each item's name and kind without the full path.
- The Dictation tab lists recordings on the left and shows the selected one on the right: its player and actions at the top, then the full transcript and details.

### Shortcut Coach

- Keyboard Shortcutter is now called **Shortcut Coach**.
- New **Notch** presentation: the notch widens to show the app, the action, and the shortcut's glowing keys. It is the default for new installs; existing installs keep their choices.

### Settings and app

- New Keybumps icon: the mascot on a keycap. The menu-bar icon is the mascot on its own.

- Raycast-style dark Settings with an account row, toolbar enable switches, Raycast-style hotkey fields, and a Window Manager grid.
- Onboarding is one screen and uses the default shortcuts.
- Escape closes the Settings window.
- The menu-bar menu has Open Keybumps, About Keybumps, Check for Updates…, Settings…, and Quit Keybumps.
- Clipboard History keeps 50 items, and copying an image file in Finder stores the image rather than its icon.

### Fixes

- Quitting is never silently refused. Keybumps asks first only when quitting would lose unsaved editor changes or a dictation in progress.
- Keybumps starts at launch even when no window opens.
- Denied Microphone access can be recovered from System Settings.
- The onboarding welcome text no longer cuts off.
