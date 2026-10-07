# Changelog

## [0.0.3-beta.21](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.20...v0.0.3-beta.21) (2026-10-07)


### Features

* ⌘C copies and ⌘P pastes the highlighted row, and Space plays and pauses audio ([#370](https://github.com/serpcompany/keybumps/issues/370)) ([#372](https://github.com/serpcompany/keybumps/issues/372)) ([b43249f](https://github.com/serpcompany/keybumps/commit/b43249f0f9fb7c1dc7b280d6e384d623e0123855))


### Fixes

* the shortcut question is announced to VoiceOver, and shortcut rows record one at a time ([#345](https://github.com/serpcompany/keybumps/issues/345)) ([#371](https://github.com/serpcompany/keybumps/issues/371)) ([fb9a1fe](https://github.com/serpcompany/keybumps/commit/fb9a1febb998791e78859dcadee16922cef478ed))

## [0.0.3-beta.20](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.19...v0.0.3-beta.20) (2026-10-07)


### Features

* the Translate tab keeps recent translations, saved with Return, and reads them aloud ([#362](https://github.com/serpcompany/keybumps/issues/362)) ([#366](https://github.com/serpcompany/keybumps/issues/366)) ([b0c0056](https://github.com/serpcompany/keybumps/commit/b0c005666ed7ae1b9a08590e7337e8f3163b3a71))

## [0.0.3-beta.19](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.18...v0.0.3-beta.19) (2026-10-07)


### Features

* / in the Command Palette filters a tab's items ([#332](https://github.com/serpcompany/keybumps/issues/332)) ([497981a](https://github.com/serpcompany/keybumps/commit/497981ade9d9502f7792d1a76815507eecb89981))
* Left and Right switch Command Palette tabs while the search field is empty ([#326](https://github.com/serpcompany/keybumps/issues/326)) ([e662f9d](https://github.com/serpcompany/keybumps/commit/e662f9d8fb4437f27cb380126c4c3775e05e6725))
* moving the pointer over a Command Palette row highlights it, as in Raycast ([#351](https://github.com/serpcompany/keybumps/issues/351)) ([405d307](https://github.com/serpcompany/keybumps/commit/405d307c92f35a24d59e898f66aded733f5d7eec))
* Quick Search finds emoji, with a setting to turn it off ([#335](https://github.com/serpcompany/keybumps/issues/335)) ([4db62bf](https://github.com/serpcompany/keybumps/commit/4db62bf9b41d0feb4dd266dcad04af2d9f97a9a5))
* the Command Palette's tabs are icons, with names only on the open tab ([#360](https://github.com/serpcompany/keybumps/issues/360)) ([d0dd7e5](https://github.com/serpcompany/keybumps/commit/d0dd7e5ac6974c3d7148c236f8ac4aed9b5729e3))
* the Translate tab swaps languages (⌘T) and picks the other language from its header ([#362](https://github.com/serpcompany/keybumps/issues/362), part 1) ([bbbecd7](https://github.com/serpcompany/keybumps/commit/bbbecd742612dfc25f8038f1d13845548fbb3e0b))
* Translation plugin with a Translate tab (⌘8), for macOS 15 ([#358](https://github.com/serpcompany/keybumps/issues/358)) ([5580e20](https://github.com/serpcompany/keybumps/commit/5580e209b80ede78b87f75806267a3d54eebb164))


### Fixes

* a Dictation recording cut off by a crash can be retried ([#328](https://github.com/serpcompany/keybumps/issues/328)) ([42d5b09](https://github.com/serpcompany/keybumps/commit/42d5b09138dadd9f5e9c00430fce2ff0f0ceeec4))
* copying a Clipboard History image whose file is missing no longer empties the clipboard ([#324](https://github.com/serpcompany/keybumps/issues/324)) ([890ab1e](https://github.com/serpcompany/keybumps/commit/890ab1e8e0da6036b4c3ee2bb2296c5bc498b074))
* Dictation's Translate offers English for text in another language, and the palette stays open while a language downloads ([#330](https://github.com/serpcompany/keybumps/issues/330)) ([bd6f525](https://github.com/serpcompany/keybumps/commit/bd6f525b7d724a57c75241d744fe218b176cf0c6))
* Escape while Dictation's model loads stops the wait and no longer fails the next dictation ([#318](https://github.com/serpcompany/keybumps/issues/318)) ([106d73d](https://github.com/serpcompany/keybumps/commit/106d73d576e1b1e79f419a350d914e9ef20948e0))
* every Command Palette list keeps the highlighted row on screen ([#353](https://github.com/serpcompany/keybumps/issues/353)) ([49697b3](https://github.com/serpcompany/keybumps/commit/49697b314e78900a40eda95aaf579bcbafe43f66))
* on a small screen the Settings window fits above the Dock ([#323](https://github.com/serpcompany/keybumps/issues/323)) ([d3b9057](https://github.com/serpcompany/keybumps/commit/d3b90570df99a34da60ab74a0085d78dcfc00f5d))
* setting a shortcut another Keybumps action uses asks before moving it ([#342](https://github.com/serpcompany/keybumps/issues/342)) ([b16456a](https://github.com/serpcompany/keybumps/commit/b16456a0ab36a1acd7533c9f9a6ec31c146043c6))
* the Command Palette's Command keys work while Caps Lock is on ([#182](https://github.com/serpcompany/keybumps/issues/182)) ([2d181e8](https://github.com/serpcompany/keybumps/commit/2d181e810df937d6db7a65b81d330e07a0e8fe73))
* the Command Palette's corners no longer show a square edge outside the rounded ones ([#315](https://github.com/serpcompany/keybumps/issues/315)) ([47ea55f](https://github.com/serpcompany/keybumps/commit/47ea55fa129fc259fcd817c680606c439f8dfcf5))


### Improvements

* translation languages move to a shared Translation folder, with a language pair ([#356](https://github.com/serpcompany/keybumps/issues/356)) ([002d3db](https://github.com/serpcompany/keybumps/commit/002d3db8b81186be11e4cd4991c5426b447165fa))

## [0.0.3-beta.18](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.17...v0.0.3-beta.18) (2026-10-06)


### Features

* Cancel Dictation is a command in Settings (default Esc), and Dictation's shortcut is named Start & Stop Dictation ([#292](https://github.com/serpcompany/keybumps/issues/292)) ([bc9ace3](https://github.com/serpcompany/keybumps/commit/bc9ace3c742073e7c5026bde88807c5b89d31d3d))
* Dictation's Large v3 Turbo (Fast) runs on whisper.cpp on the GPU, about 3 times faster with no Neural Engine recompile ([#283](https://github.com/serpcompany/keybumps/issues/283)) ([59f14aa](https://github.com/serpcompany/keybumps/commit/59f14aa9ae90bb9e9973ac9d7e1c8b544f09b58d))


### Fixes

* the dropdowns in Settings › Dictation open again, as native pop-up menus ([#287](https://github.com/serpcompany/keybumps/issues/287)) ([2c957c4](https://github.com/serpcompany/keybumps/commit/2c957c4ed4732246ff62fd1acef9739bedcaa8d7))


### Improvements

* Dictation starts loading the Whisper model when recording starts, and saves each transcription's wait ([#280](https://github.com/serpcompany/keybumps/issues/280)) ([b3f998f](https://github.com/serpcompany/keybumps/commit/b3f998f42c5b4f84dde0022e7b652937f9dfa0c4))

## [0.0.3-beta.17](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.16...v0.0.3-beta.17) (2026-10-06)


### Features

* Keybumps reports crashes and freezes to its developers, with an off switch in Settings › General ([#259](https://github.com/serpcompany/keybumps/issues/259)) ([1078ca1](https://github.com/serpcompany/keybumps/commit/1078ca1f9de0b515675ccb9aefa6756485626ae1))
* Report a Problem… sends what went wrong, with this Mac's details, from the Help menu, the menu bar, and Settings ([#265](https://github.com/serpcompany/keybumps/issues/265)) ([440bbbe](https://github.com/serpcompany/keybumps/commit/440bbbe105545fb461b6f7521ec9cd59797ce5ae))


### Fixes

* problem report scrubbing stays fast on long text, and finds email addresses with combining marks ([#270](https://github.com/serpcompany/keybumps/issues/270)) ([a6045bf](https://github.com/serpcompany/keybumps/commit/a6045bf9f1c4e7eb75db1e4e6b2e9e5016a70ade))

## [0.0.3-beta.16](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.15...v0.0.3-beta.16) (2026-10-05)


### Features

* a turned-off plugin's Settings page says so, with a Turn On button ([#255](https://github.com/serpcompany/keybumps/issues/255)) ([3d7f0f2](https://github.com/serpcompany/keybumps/commit/3d7f0f23342dfd8ad1a5f0fb0c6d3cf5948ca8fe))

## [0.0.3-beta.15](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.14...v0.0.3-beta.15) (2026-10-05)


### Features

* add Timer, a capability for countdowns in the Command Palette ([#232](https://github.com/serpcompany/keybumps/issues/232)) ([7e14600](https://github.com/serpcompany/keybumps/commit/7e14600c28f973c1c4c3fae06ebd957cedefea93))
* plugin manifests and one settings template, starting with Timer ([#240](https://github.com/serpcompany/keybumps/issues/240)) ([eb1c3ec](https://github.com/serpcompany/keybumps/commit/eb1c3ec6f990f48b6637b73441eddf4908c6356b))
* plugin manifests can declare optional permissions and ship off ([#251](https://github.com/serpcompany/keybumps/issues/251)) ([5fd4561](https://github.com/serpcompany/keybumps/commit/5fd4561291b4c0a208a2a9a0310e37c275f7f958))
* plugin tabs can be grids, and can copy and paste through the palette ([#250](https://github.com/serpcompany/keybumps/issues/250)) ([491eee4](https://github.com/serpcompany/keybumps/commit/491eee4f3ddf06b48a03bb2d811ffba3e873e851))
* Plugins in Quick Search, and Settings › Plugins links to keybumps.app/plugins ([#242](https://github.com/serpcompany/keybumps/issues/242)) ([0df1d69](https://github.com/serpcompany/keybumps/commit/0df1d69a93344f0c466d5c77dc9e2dd34f046cf2))
* ring a timer alarm on screen until it's stopped ([#236](https://github.com/serpcompany/keybumps/issues/236)) ([c19b798](https://github.com/serpcompany/keybumps/commit/c19b798c7d3f725cd07a1ddd5e8052bc2641059b))
* Settings › Plugins, a page listing every plugin, and Settings opens filling the screen ([#241](https://github.com/serpcompany/keybumps/issues/241)) ([5f8887c](https://github.com/serpcompany/keybumps/commit/5f8887c01629b4dfde93c30ec27f25dd7f1c3525))
* show running timers in the menu bar and the Keybumps menu ([#234](https://github.com/serpcompany/keybumps/issues/234)) ([7e0e5b9](https://github.com/serpcompany/keybumps/commit/7e0e5b97674823b6756db84aaa3cce98e6817cdf))
* the Emoji Picker plugin, with an Emoji tab that's a grid to browse and a list to search ([#253](https://github.com/serpcompany/keybumps/issues/253)) ([20859d5](https://github.com/serpcompany/keybumps/commit/20859d5d989a1249cc2817ea439a738393448720))
* the Emoji Picker's emoji list, generated from pinned Unicode, CLDR, and gemoji data ([#252](https://github.com/serpcompany/keybumps/issues/252)) ([a5a5bda](https://github.com/serpcompany/keybumps/commit/a5a5bda5dc7a46f9e60a961454e6a76c6502fc94))


### Improvements

* let capability modules supply their palette tab and the menu bar dot ([#231](https://github.com/serpcompany/keybumps/issues/231)) ([b24baf0](https://github.com/serpcompany/keybumps/commit/b24baf0b962d40747b2aeb04024c9ddd5a028055))

## [0.0.3-beta.14](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.13...v0.0.3-beta.14) (2026-10-05)


### Features

* make updates hard to miss with a restart prompt, a red dot, and What's New ([#226](https://github.com/serpcompany/keybumps/issues/226)) ([873e696](https://github.com/serpcompany/keybumps/commit/873e696fb860c90e5ed6360a53832b3ce1b7375b))

## [0.0.3-beta.13](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.12...v0.0.3-beta.13) (2026-10-02)


### Documentation

* write the 0.0.3-beta.13 notes (notarized again) ([#223](https://github.com/serpcompany/keybumps/issues/223)) ([1f2a12f](https://github.com/serpcompany/keybumps/commit/1f2a12fc8498c267e58057c5af579f4c015e9b58))

## [0.0.3-beta.12](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.11...v0.0.3-beta.12) (2026-10-02)


### Features

* expand snippet keywords as you type in any app ([#220](https://github.com/serpcompany/keybumps/issues/220)) ([92be364](https://github.com/serpcompany/keybumps/commit/92be364865dd591432835d0a32796d036e8446e2))
* find snippets by keyword and name in Quick Search ([#218](https://github.com/serpcompany/keybumps/issues/218)) ([7badd69](https://github.com/serpcompany/keybumps/commit/7badd69e2150cb053182215b4e33688339fff5ad))
* go to each capability by searching its name in Quick Search ([#186](https://github.com/serpcompany/keybumps/issues/186)) ([6c88045](https://github.com/serpcompany/keybumps/commit/6c88045329e1a815e58628fbdbc8e46c0c254139))
* import snippets from an Alfred export ([#209](https://github.com/serpcompany/keybumps/issues/209)) ([6382444](https://github.com/serpcompany/keybumps/commit/63824448869d62834211b7430b52ac65a1a65b9f))
* save text as snippets and copy or paste it from the Command Palette ([#190](https://github.com/serpcompany/keybumps/issues/190)) ([dc29440](https://github.com/serpcompany/keybumps/commit/dc29440ab0e48b5386a9c6c75a4769d2de4347e9))
* sort the Snippets table by column and change several snippets at once ([#216](https://github.com/serpcompany/keybumps/issues/216)) ([9bd6652](https://github.com/serpcompany/keybumps/commit/9bd66520a473b1852597d315aeb3a02215776bc1))


### Fixes

* copy on Return in the Screenshots tab, and edit with ⌘Return ([#196](https://github.com/serpcompany/keybumps/issues/196)) ([68690e4](https://github.com/serpcompany/keybumps/commit/68690e437adb2c5578a8f3f9da8a01de4dad445b))
* Dictation asks for the Accessibility access it needs to paste ([#195](https://github.com/serpcompany/keybumps/issues/195)) ([0b5cb8b](https://github.com/serpcompany/keybumps/commit/0b5cb8baf31df71c8852a2474765ec21fe24c1bd))
* keep screenshots in the Screenshots tab when clearing the Clipboard tab ([#204](https://github.com/serpcompany/keybumps/issues/204)) ([4b579ca](https://github.com/serpcompany/keybumps/commit/4b579caff838cc59ed797bd7b90e9ff2b7c2e680))
* remove the thin line at the ends of the palette's pills ([#198](https://github.com/serpcompany/keybumps/issues/198)) ([83fc126](https://github.com/serpcompany/keybumps/commit/83fc1268a328571eb5c72d4bdc711336cc17c041))
* stop Shortcut Coach's click checks from freezing Keybumps ([#213](https://github.com/serpcompany/keybumps/issues/213)) ([0a59900](https://github.com/serpcompany/keybumps/commit/0a59900cde8298ed60bf8a272fb44792158c3268))

## [0.0.3-beta.11](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.10...v0.0.3-beta.11) (2026-09-30)


### Features

* copy new screenshots to the clipboard and clarify the Screenshot Editor's actions ([#173](https://github.com/serpcompany/keybumps/issues/173)) ([1d11171](https://github.com/serpcompany/keybumps/commit/1d11171ec75c2ec111e3640914da1c2684e47fe5))
* open Keybumps Settings from the Command Palette and Quick Search ([#179](https://github.com/serpcompany/keybumps/issues/179)) ([d5ddf39](https://github.com/serpcompany/keybumps/commit/d5ddf3900a2d6256778898c6686f93a11a8f2845))
* show where each Clipboard History item was copied from ([#180](https://github.com/serpcompany/keybumps/issues/180)) ([2404b4d](https://github.com/serpcompany/keybumps/commit/2404b4d3081677087d0b6048f79f4ee97148d1aa))

## [0.0.3-beta.10](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.9...v0.0.3-beta.10) (2026-09-30)


### Documentation

* record the first release from the apps/macos layout ([#167](https://github.com/serpcompany/keybumps/issues/167)) ([e1c7a0d](https://github.com/serpcompany/keybumps/commit/e1c7a0d7939986dc7b5d3e9b4c569d12eb7d4351))

## [0.0.3-beta.9](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.8...v0.0.3-beta.9) (2026-09-30)


### Chores

* describe latest.json as the website's latest-release pointer ([#164](https://github.com/serpcompany/keybumps/issues/164)) ([79c3085](https://github.com/serpcompany/keybumps/commit/79c3085f12d863067157ce0a03340ee55bb50065))

## [0.0.3-beta.8](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.7...v0.0.3-beta.8) (2026-09-30)


### Improvements

* remove extra Shortcut Coach presentation channels ([#137](https://github.com/serpcompany/keybumps/issues/137)) ([f163bf0](https://github.com/serpcompany/keybumps/commit/f163bf016a062710b6d8f3232db5b44211cf347c))

## [0.0.3-beta.7](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.6...v0.0.3-beta.7) (2026-09-29)


### Features

* email License Keys and resend-key endpoint ([#127](https://github.com/serpcompany/keybumps/issues/127)) ([c286d53](https://github.com/serpcompany/keybumps/commit/c286d533090a49da700f06453c70190e1ad3caf1))
* in-app licensing with Polar license keys ([#133](https://github.com/serpcompany/keybumps/issues/133)) ([df14c44](https://github.com/serpcompany/keybumps/commit/df14c44b067e535c0dbea525dc5519b10ce6ae0a))
* licensing service skeleton with signed leases ([#123](https://github.com/serpcompany/keybumps/issues/123)) ([b6bd8fc](https://github.com/serpcompany/keybumps/commit/b6bd8fc247b360d0191c1d771f78e89429bd242b))
* Polar provider adapter and order fulfillment ([#125](https://github.com/serpcompany/keybumps/issues/125)) ([f978d08](https://github.com/serpcompany/keybumps/commit/f978d0864cfdf65f4b33216cd087e7993df06d3c))

## [0.0.3-beta.6](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.5...v0.0.3-beta.6) (2026-09-29)


### Features

* Icon Composer app icon (3D keycap on purple) ([#114](https://github.com/serpcompany/keybumps/issues/114)) ([a3aeb03](https://github.com/serpcompany/keybumps/commit/a3aeb03d17fb992b039ce3f61211a0cc490a71d8))

## [0.0.3-beta.5](https://github.com/serpcompany/keybumps/compare/v0.0.3-beta.4...v0.0.3-beta.5) (2026-09-29)

This beta gives Keybumps a properly sized Mac icon and moves Dictation's recording indicator into the notch.

> **This beta is not notarized.** It is signed with our Developer ID, but Apple notarization is temporarily unavailable. If you download it fresh, macOS blocks the first launch: open **System Settings › Privacy & Security** and click **Open Anyway** next to the Keybumps message. Updating from inside Keybumps works normally, and later releases will be notarized again.

### Changes

- The Keybumps icon now follows the standard Mac icon shape, so the keycap is no longer small inside a large dark tile.
- Dictation shows its state in the notch. While recording, a red dot and timer sit to the left of the notch, and live microphone bars and your Dictation shortcut (the key that finishes) sit to the right. While transcribing, a sparkle and moving dots appear. If Dictation fails, the notch drops down with the reason. Escape still cancels.

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
