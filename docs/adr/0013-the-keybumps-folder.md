# 0013: Each plugin's files are kept in its own folder in the Keybumps folder, which never syncs

Status: Accepted (2026-10-21) when the owner merges it. Tracked by #602 and #605, part of the epic #601, which holds the plan. Supersedes parts of [0010](0010-screengrabs-one-plugin.md)'s decisions 5 and 6; see "Superseded".

## Context

Before #602, Keybumps kept files in two places. Dictation History, and ScreenGrabs' recordings made before #504, were in `~/Documents/Keybumps` (`recordings/` and `captures/`). Everything else sat loose at the top of `~/Library/Application Support/Keybumps`: Clipboard History and its images, snippets, recent translations, Shortcut Coach history, the recordings index, timers, recents, and Dictation's models.

On 2026-10-21 the owner asked (#601) for every plugin that keeps history to keep it in one place, with each plugin's folder shown in Settings. After trying the first candidate (4035.602.1) the same day, the owner asked for a folder for every plugin that saves files, "just for consistency sake", and for the folder to be shown only on Settings › General: "maybe we just put it in like the general area only?" #602 is the first of #601's PRs. After trying its second candidate, the owner asked for ScreenGrabs to keep everything there too: "save screenshots in the `…/Keybumps/screengrabs/screenshots/` area.... thats where the history is built from... WE CAN ALSO COPY/DUPE THEM ONTO THE DESKTOP JUST FOR CONVENIENCE" (#605, decision 4). Change… (#603) and keeping all of Clipboard History (#604) follow.

## Decisions

1. **The Keybumps folder is `~/Library/Application Support/Keybumps`** (`ProductPaths.keybumpsFolder`). Every plugin that saves files has its own folder in it, and nothing is loose at its top level (the owner, 2026-10-21):
   - `clipboard_history/`: `clipboard-history.json`, and the images' copies in `media/`.
   - `dictation/`: `recordings/` (Dictation History, a folder per dictation), `models/` (the downloaded models), and `last-dictation.txt`.
   - `emoji_picker/`: `emoji-recent.json`.
   - `quick_search/`: `recent-items.json` and `application-usage.json`.
   - `screengrabs/`: `recordings.json`, `screencast-repositories.json`, and ScreenGrabs' history (decision 4): `recordings/` (every recording, a folder each) and `screenshots/` (every screenshot).
   - `shortcut_coach/`: `coaching-events.json`.
   - `snippets/`: `snippets.json`, and any `snippets.unreadable-<date>.json` copies.
   - `timers/`: `timers.json`.
   - `translations/`: `recent-translations.json`.

   Window Management and Keystrokes save no files, so they have no folder. Caches (`~/Library/Caches/Keybumps`) and temporary files stay where they were. Where macOS saves screenshots, which gets a copy of each screengrab (decision 4), is the person's own, and syncing it is fine.

2. **Never a folder that syncs.** Syncing between devices is a paid feature (the owner: "syncing between devices is a paid feature gate"), so the Keybumps folder never goes in a folder that syncs to another device.
   - Documents was the first plan. It syncs to iCloud whenever Desktop & Documents is on, and macOS offers no supported way to keep one folder out.
   - Naming a folder `.nosync` is folklore, not a documented exclusion, and iCloud Drive doesn't honor the exclusion flag.
   - Application Support is where a Mac app usually keeps its data, and iCloud never syncs it.

   Finder hides `~/Library`, so Settings › General shows the Keybumps folder, with Show in Finder (`KeybumpsFolderRow`), and says each plugin keeps its files in its own folder there. Plugins' pages don't repeat it, and none shows a folder (the owner, 2026-10-21): ScreenGrabs' Screenshots and Recordings folder rows went in #605. Change… (#603) will refuse a folder that syncs.

3. **A one-time move at launch** (`KeybumpsFolderMove`), before any store loads, brings each file from its old place to its new one:
   - **How it moves:** a rename that never replaces anything. Failing that, such as across volumes, a copy is written beside the destination, checked against the original, and put in place, and only then is the original removed.
   - **Every launch runs it,** so it does nothing once done, and a move cut short finishes at the next launch.
   - **Nothing is overwritten.** If the new place already has a different file, both stay, and the store reads the new one. An identical copy in the old place is removed.
   - **A failure leaves the file where it was,** and its store reads it there that launch (`ProductPaths.inUse`).
   - **Absolute paths are rewritten** in Clipboard History, the recordings index, each Dictation model's `model-location.txt`, and the folders ScreenGrabs remembers recording into, once their files have moved.
   - **Dictation's models** (about 4 GB) move in one rename. A download cut short moves with them and is still not installed: a model is installed only once its download has finished and `model-location.txt` names it.
   - **The first candidates' layout:** a dictation folder at the top of `dictation/` moves into `dictation/recordings/`.
   - **`~/Documents/Keybumps`** is looked in only on a Mac that ran an earlier build, so a new install never makes macOS ask for Documents:
     - Until everything of Keybumps's there has moved (`keybumpsFolder.documentsMoved`, the time it did), on a Mac with the Keybumps folder or where an earlier build ran (`didCompleteOnboarding` or `lastLaunchedVersion`), so a Keybumps folder removed by hand or by an uninstaller doesn't hide it.
     - After that, again when a file outside Documents is in its old place and newer than that time: a build before #602 ran since, and it saves dictations in Documents.
     - It's removed once only Finder's `.DS_Store` is left in it, and never while anything else is.
     - A folder chosen in Settings › ScreenGrabs before #605 (`AppPreferences.chosenScreengrabFolderPaths`) inside it isn't moved, and a chosen `~/Documents/Keybumps` isn't removed.
   - **Logs** say only the stage, the item, an error code, and how long the move took.

4. **ScreenGrabs keeps every screenshot and recording in `screengrabs/`, its history, and puts a copy where macOS saves screenshots** (#605).
   - **The history:** the screenshot hotkeys and the Screenshot Editor's Save on a screenshot save into `screengrabs/screenshots/`, each under a name nothing there has yet, and a screenshot macOS saves gets a copy there. An edited screenshot is a screenshot item of its own. Recordings save into `screengrabs/recordings/`. The ScreenGrabs tab, the recordings index, and Clipboard History's screenshot items name these files, and a screenshot has no copy in `clipboard_history/media/`. Delete and Clear All in the ScreenGrabs tab move the history's file to the Trash.
   - **The copy** goes where macOS saves screenshots: `com.apple.screencapture` `location`, else the Desktop (`ScreengrabCopies`).
     - A hotkey screenshot is copied as it's taken, and an edited screenshot as it's saved. A recording's whole `<timestamp>/` folder is copied once the recording window keeps it (Save, Copy, or a review that couldn't be written), or once it's kept because the Mac locked or ScreenGrabs turned off. A screenshot macOS saved is already there and gets no second copy.
     - It's an APFS clone (`clonefile`), which takes no more space on the same volume, else a copy checked against the original. It never replaces anything: a name already there gets Finder's next one (`ScreengrabFiles`).
     - The copy is the person's. Nothing Keybumps keeps names it, so moving or deleting it, such as by clearing the Desktop, never makes a screengrab "Moved or deleted". Edits to a recording opened from ⌘3 don't reach its copy.
   - **No folder choice.** Settings › ScreenGrabs shows no folders. A Screenshots or Recordings folder chosen there before #605 is no longer used, and its stored choice is read only by the launch's moves.
   - **Nothing is dropped.** Clipboard History keeps every screenshot item, apart from its 50 other items (`ClipboardHistoryService.capacity`), and the ScreenGrabs tab lists every one. At launch, a file in `screengrabs/screenshots/` that no item names, such as one taken while Clipboard History was off, gets an item, kept out of the Clipboard tab (`adoptScreenshots`).
   - **What was kept before #605 comes into the history at launch** (`ScreengrabsHistoryMove`), after decision 3's move and by its rules, except that the original stays: a copy (an APFS clone, else a checked copy) that never replaces anything, nothing done twice, and a failure leaving it as it was until the next launch.
     - Every launch: a screenshot item whose file isn't in the history gets a copy there, from its copy in `media/`, else its own file, under its own file's name, and the item then names it. Its copy in `media/` is removed; its own file, such as one on the Desktop, is the person's and stays.
     - Every launch: a recording the index lists outside the history, such as one saved on the Desktop from #504 until #605, gets a copy of its folder there, and the index then names it. The folder it was in stays, as the person's copy.
     - Once: a recording the index lacks, in a folder ScreenGrabs recorded into, gets a copy unless the history has its folder.
     - Recordings wait while decision 3's move has left the recordings or the index in their old place, unless it left them for a folder chosen before #605; new recordings go to the history either way.
     - Every launch: a partial copy Keybumps left when it quit mid-copy (`.<name>.keybumps-moving`) is removed from the history. One where copies go is removed just before the next copy there, so the launch's moves never read that folder, and a Mac that doesn't use ScreenGrabs is never asked for its Desktop (#611).

## Consequences

- **Downgrading** to a release before #602 starts with empty Clipboard History, snippets, recent translations, Shortcut Coach history, recordings index, repository guesses, recent emoji, Recent Items, learned usage, and timers, no dictations, and no downloaded models, so Dictation goes back to Apple Speech, because the older build reads the old places. Nothing is lost: upgrading again finds everything in the Keybumps folder. Whatever the older build saved in the meantime moves at the next launch, its dictations once it has written anything outside Documents, such as `last-dictation.txt` after each one is transcribed. Where the new place already has a file, the old one is left beside it. The release notes say so.
  - Known gap: after a downgrade and an upgrade, a Clipboard History conflict keeps the older build's history in the old place, and its new images merge into `media/` where nothing refers to them.
- **iCloud Desktop & Documents:** on a Mac that syncs Documents, moving dictations and older recordings out of `~/Documents/Keybumps` takes them out of iCloud, so the person's other Macs stop seeing them there. This is intended (the owner, 2026-10-21: syncing between devices is a paid feature). The release notes say so.
- `ProductPaths.applicationSupport` is now `keybumpsFolder`. `recordings` and `captures` are now `dictationRecordings` and `screengrabsRecordings`, `dictationModels` is `dictation/models`, and `oldDocumentsFolder` names `~/Documents/Keybumps` for the move alone.
- The unit-test host and the UI-test sandbox move both the Keybumps folder and the old Documents folder into their own temporary folders, and the move never runs under either ([testing](../testing.md)).
- **Downgrading** to a release before #605 lists the history's screengrabs, since Clipboard History and the recordings index name its files, and saves new ones in its own folders, which the next upgrade brings into the history. It keeps only the newest 50 screenshot items, but removes files only in `media/`, so upgrading again lists the rest (`adoptScreenshots`). For the same reason, a screenshot deleted in the older build is listed again after upgrading.
- **Disk space:** a screengrab and its copy share their storage on the same volume. A screenshot from before #605 whose own file is still on the Desktop is kept twice, once in the history and once as the person's file.
- The website still names `~/Documents/Keybumps`. As in ADR 0012's decision 5, it changes after a release ships this.

## Superseded

From [0010](0010-screengrabs-one-plugin.md)'s decision 5:
- "Recordings already in `~/Documents/Keybumps/captures` stay there": they move to the Keybumps folder's `screengrabs/recordings/`, still indexed, so ⌘3 lists them.
- "Dictation's audio stays in Keybumps's own folder, `~/Documents/Keybumps/recordings` (`ProductPaths.recordings`)": it's in the Keybumps folder's `dictation/recordings/` (`ProductPaths.dictationRecordings`).
- "Screenshots and recordings each have their own save folder, and both default to the Mac's screenshot folder", with a Choose… for each in Settings › ScreenGrabs (#504): both save in ScreenGrabs' history in the Keybumps folder, with a copy where macOS saves screenshots, and there's no folder to choose (decision 4, #605).

From [0010](0010-screengrabs-one-plugin.md)'s decision 6:
- "Clipboard History keeps the newest 50 screenshots apart from its newest 50 other items": it keeps every screenshot, apart from its 50 other items (decision 4, #605).
