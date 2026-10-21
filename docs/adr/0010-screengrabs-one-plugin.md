# 0010: Screenshots and recordings are one plugin, ScreenGrabs, and both are found again in the ⌘3 tab

Status: Accepted (2026-10-17) when the owner merges it. Tracked by #488, part of the epic #482, which holds the plan. Supersedes parts of [0006](0006-capabilities-as-plugins.md) and [0009](0009-screencast-records-and-sends-captures.md); see "Superseded". Partly superseded by [0013](0013-the-keybumps-folder.md) (2026-10-21, #602): decision 5's `~/Documents/Keybumps/captures` and `~/Documents/Keybumps/recordings` moved into the Keybumps folder, as `screengrabs/recordings/` and `dictation/`.

## Context

Keybumps has two plugins for the screen. Screenshot Tools, a default capability, takes screenshots through macOS's `screencapture`, lists them in the ⌘3 tab from Clipboard History, and marks them up in the Screenshot Editor. Screencast, an added capability that ships off and needs macOS 15 (ADR 0009), records video through its own picker into `~/Documents/Keybumps/captures`, and has no palette tab. Since #485 it records video only.

On 2026-10-12 the owner asked for one plugin: "the way i wanna merge screenshot tools and screencast together is by calling them screengrabs. making it one plugin. and having both save in the cmd+3 area." #482 holds the design, the migration and what a rollback keeps, the risks, and the child issues; the owner answered its questions on 2026-10-17. This record keeps only the decisions.

## Decisions

1. **One plugin, ScreenGrabs, replaces Screenshot Tools and Screencast.** It keeps Screenshot Tools' stored ID, `screenshotTools`, and the tokens `CommandPaletteTab.screenshots` and `SettingsSection.screenshotTools`; only what people see changes. That follows `docs/architecture.md`'s stable-identifier rule, as Shortcut Coach kept `keyboardShortcutter`.
   - `Capability.screencast` is retired, and a one-time step at launch folds its saved state in (#489).
   - Screencast's declared preferences keep their stored keys, `plugin.screencast.<key>`, through a storage-name override on `PluginPreference` (#490), so nothing is copied.
   - Swift types and folders keep their names (`Screencast*`, `ScreenshotTools/`), and `CONTEXT.md` maps them to the new names (#490).
2. **It ships on and stays a default capability, with no `minimumMacOS`.** Recording has no switch of its own.
   - Recording needs macOS 15 inside the plugin, through a new `PluginCompatibility.supportsRecording` that Settings, Quick Search's actions (`offers`), the Record Screen shortcut, and the menu bar read; `#available` wraps only the ScreenCaptureKit calls (#490). This narrows `docs/architecture.md`'s "`PluginCompatibility` is the one rule" from whole plugins to a part of one.
   - Recording reaches everyone with ScreenGrabs on: Record Screen in Quick Search and on ⇧⌘5 (decision 4), and the optional Microphone and Input Monitoring rows. Nothing records until the person asks.
   - Clipboard History stays a dependency, for screenshots only.
3. **Screenshots and recordings keep their own paths.** Screenshots keep their instant hotkeys, macOS's `screencapture`, and the Screenshot Editor. Recordings go through the recording picker (video only, #485), which remembers its last choices (#486) and opens on Screen when it has none (#501), then the control bar, then the recording window (#479).
4. **Record Screen gets ⇧⌘5 by default,** taking over macOS's screenshot toolbar as ⇧⌘3 and ⇧⌘4 already are: the owner wants Keybumps's shortcuts to take precedence over ones already in use.
   - macOS's hotkey 184 joins `SystemScreenshotShortcutTakeover.managed`, beside 28 and 30 (#490).
   - Every stored binding keeps its raw value: Record Screen is still the shortcut `screencast`, and Quick Search's action `startScreencast`.
   - Every install gets ⇧⌘5 for Record Screen once, through a one-time step in #490, even if Record Screen already has another shortcut, unless another Keybumps shortcut uses those keys (#513; the owner: "lets overwrite this by default and use our thing now").
   - Where recording isn't supported, the shortcut doesn't run, and macOS keeps ⇧⌘5 (#490).
5. **Screenshots and recordings each have their own save folder, and both default to the Mac's screenshot folder:** `com.apple.screencapture` `location`, else the Desktop (`ScreenshotLocationResolver`). Keybumps takes over ⇧⌘3, ⇧⌘4, and ⇧⌘5, so people look for the files where macOS puts them, and current users' screenshots don't move.
   - Settings › ScreenGrabs shows two folders, Screenshots and Recordings, each with its own Choose… (#504). The owner: "let them select each one individually".
   - The Screenshots folder keeps following macOS's setting until the person chooses one in Keybumps.
   - Recordings already in `~/Documents/Keybumps/captures` stay there and are indexed once, so ⌘3 lists them (#492).
   - Dictation's audio stays in Keybumps's own folder, `~/Documents/Keybumps/recordings` (`ProductPaths.recordings`).
6. **The ⌘3 tab, ScreenGrabs, lists both, newest first** (#494): screenshot items from Clipboard History and recordings from ScreenGrabs' recordings index (#492). Clipboard History keeps the newest 50 screenshots apart from its newest 50 other items (#493), where today they share one limit of 50 (`ClipboardHistoryService.capacity`).
7. **Recordings get editing in phases, each gated on mockups the owner approves:** trim (#497), then blur and redact (#498), then arrows, drawing, and text (#499). All of it draws through the Screenshot Editor's path, `ScreenshotAnnotationRenderer`. Each phase waits until the owner schedules it.
8. **ADR 0009's destinations apply to recordings unchanged** (Clipy and the webhook receiver; #451 and #452). Their settings move to Settings › ScreenGrabs.
9. **beta.26 waits until ScreenGrabs is ready to ship,** so no public build has Screencast as a plugin of its own. Before that release, #495's first PR describes recordings on the privacy page (ADR 0009, Consequences). After it, the website's `/plugins/screenshot-tools/` becomes `/plugins/screengrabs/`, with a permanent redirect (308) from the old address (#495's second PR).

## Superseded

From [0006](0006-capabilities-as-plugins.md):
- Decision 2's name for one default capability: Screenshot Tools is now ScreenGrabs, with the same ID.

From [0009](0009-screencast-records-and-sends-captures.md):
- Decision 1: Screencast was an added plugin that shipped off. Recording is part of ScreenGrabs, which ships on (decisions 1 and 2 above).
- Decision 3's screenshots, as the 2026-10-12 amendment (#485) left them: screenshots are ScreenGrabs' too, through their own hotkeys, never the recording picker.
- Decision 4's review panel and its fixed folder. After a recording comes the recording window (#479). Recordings save where decision 5 above says, not under `~/Documents/Keybumps/captures/<timestamp>/` or in "the captures folder set in Settings › Screencast" (#479's amendment).
- The Open question whether it gets a palette tab: recordings are in the ⌘3 tab.

Still in force from 0009: decision 2 (recording needs macOS 15, now through `supportsRecording` rather than `minimumMacOS`); decision 3 for recordings (video of an area, a window, or every screen; the microphone and system-audio switches; the control bar; keys shown through Keystrokes; drawing); decision 4's rule that a recording stays on the Mac until the person sends it; and decisions 5–8 (destinations, Clipy, donors, and the webhook receiver), now for recordings.

## Consequences

- Nothing a person has is lost: on/off state, shortcuts, settings, learned usage, ⌘3's screenshots, and earlier recordings carry over (#482, "Migration"; #489, #492, #493). A rollback brings Screencast back off, with its settings and shortcuts kept.
- Someone who used only Screencast, with Screenshot Tools off, keeps macOS's ⇧⌘3 and ⇧⌘4: each screenshot hotkey still on its default key is unassigned (#489).
- `CONTEXT.md`'s terms, `docs/architecture.md`'s `PluginCompatibility` sentence, `docs/adding-a-plugin.md`, and root `AGENTS.md`'s "Screencast capture" change with the code, in #490.
- ScreenGrabs needs Screen Recording; Microphone and Input Monitoring are optional. The bundle ID doesn't change, so macOS keeps every grant.

## Open

- Whether one card follows each screengrab, for both kinds (#496), parked until the owner decides after trying wave 3 (#482).
