# 0013: Each plugin's history is kept in its own folder in the Keybumps folder, which never syncs

Status: Accepted (2026-10-21) when the owner merges it. Tracked by #602, part of the epic #601, which holds the plan. Supersedes part of [0010](0010-screengrabs-one-plugin.md)'s decision 5; see "Superseded".

## Context

Before #602, Keybumps kept files in two places. Dictation History, and ScreenGrabs' recordings made before #504, were in `~/Documents/Keybumps` (`recordings/` and `captures/`). Everything else sat loose at the top of `~/Library/Application Support/Keybumps`: Clipboard History and its images, snippets, recent translations, Shortcut Coach history, the recordings index, timers, recents, and Dictation's models.

On 2026-10-21 the owner asked (#601) for every plugin that keeps history to keep it in one place, with each plugin's folder shown in Settings. #602 is the first of #601's PRs. Change… (#603), keeping all of Clipboard History (#604), and ScreenGrabs' own copies (#605) follow.

## Decisions

1. **The Keybumps folder is `~/Library/Application Support/Keybumps`** (`ProductPaths.keybumpsFolder`). Each plugin that keeps history has its own folder in it:
   - `dictation/`: each dictation's folder, and `last-dictation.txt`.
   - `clipboard_history/`: `clipboard-history.json`, and the images' copies in `media/`.
   - `translations/`: `recent-translations.json`.
   - `snippets/`: `snippets.json`, and any `snippets.unreadable-<date>.json` copies.
   - `shortcut_coach/`: `coaching-events.json`.
   - `screengrabs/`: `recordings.json`, `screencast-repositories.json`, `recordings/` (those made before #504), and `screenshots/` (empty until #605).

   What isn't history stays at the top level: recent emoji, Search's recents and usage, timers, and `DictationModels/`. Caches (`~/Library/Caches/Keybumps`) and temporary files stay where they were. The Screenshots and Recordings folders from ADR 0010's decision 5 are the person's own, and syncing them is fine.

2. **Never a folder that syncs.** Syncing between devices is a paid feature (the owner: "syncing between devices is a paid feature gate"), so the Keybumps folder never goes in a folder that syncs to another device.
   - Documents was the first plan. It syncs to iCloud whenever Desktop & Documents is on, and macOS offers no supported way to keep one folder out.
   - Naming a folder `.nosync` is folklore, not a documented exclusion, and iCloud Drive doesn't honor the exclusion flag.
   - Application Support is where a Mac app usually keeps its data, and iCloud never syncs it.

   Finder hides `~/Library`, so Settings shows the folders (`KeybumpsFolderRow`): each plugin's page shows its own, with Show in Finder, and Settings › General shows the Keybumps folder. Change… (#603) will refuse a folder that syncs.

3. **A one-time move at launch** (`KeybumpsFolderMove`), before any store loads, brings each file from its old place to its new one:
   - **How it moves:** a rename that never replaces anything. Failing that, such as across volumes, a copy is written beside the destination, checked against the original, and put in place, and only then is the original removed.
   - **Every launch runs it,** so it does nothing once done, and a move cut short finishes at the next launch.
   - **Nothing is overwritten.** If the new place already has a different file, both stay, and the store reads the new one. An identical copy in the old place is removed.
   - **A failure leaves the file where it was,** and its store reads it there that launch (`ProductPaths.inUse`).
   - **Absolute paths are rewritten** in Clipboard History, the recordings index, and the folders ScreenGrabs remembers recording into, once their files have moved.
   - **`~/Documents/Keybumps`** is looked in only on a Mac that ran an earlier build, so a new install never makes macOS ask for Documents:
     - Until everything of Keybumps's there has moved (`keybumpsFolder.documentsMoved`, the time it did), on a Mac with the Keybumps folder or where an earlier build ran (`didCompleteOnboarding` or `lastLaunchedVersion`), so a Keybumps folder removed by hand or by an uninstaller doesn't hide it.
     - After that, again when a file outside Documents is in its old place and newer than that time: a build before #602 ran since, and it saves dictations in Documents.
     - It's removed once only Finder's `.DS_Store` is left in it, and never while anything else is.
     - A folder chosen in Settings › ScreenGrabs inside it isn't moved, and a chosen `~/Documents/Keybumps` isn't removed.
   - **Logs** say only the stage, the item, an error code, and how long the move took.

## Consequences

- **Downgrading** to a release before #602 starts with empty Clipboard History, snippets, recent translations, Shortcut Coach history, recordings index, and repository guesses, and no dictations, because the older build reads the old places. Nothing is lost: upgrading again finds everything in the Keybumps folder. Whatever the older build saved in the meantime moves at the next launch, its dictations once it has written anything outside Documents, such as `last-dictation.txt` after each one is transcribed. Where the new place already has a file, the old one is left beside it. The release notes say so.
  - Known gap: after a downgrade and an upgrade, a Clipboard History conflict keeps the older build's history in the old place, and its new images merge into `media/` where nothing refers to them.
- **iCloud Desktop & Documents:** on a Mac that syncs Documents, moving dictations and older recordings out of `~/Documents/Keybumps` takes them out of iCloud, so the person's other Macs stop seeing them there. This is intended (the owner, 2026-10-21: syncing between devices is a paid feature). The release notes say so.
- `ProductPaths.applicationSupport` is now `keybumpsFolder`. `recordings` and `captures` are now `dictation` and `screengrabsRecordings`, and `oldDocumentsFolder` names `~/Documents/Keybumps` for the move alone.
- The unit-test host and the UI-test sandbox move both the Keybumps folder and the old Documents folder into their own temporary folders, and the move never runs under either ([testing](../testing.md)).
- The website still names `~/Documents/Keybumps`. As in ADR 0012's decision 5, it changes after a release ships this.

## Superseded

From [0010](0010-screengrabs-one-plugin.md)'s decision 5:
- "Recordings already in `~/Documents/Keybumps/captures` stay there": they move to the Keybumps folder's `screengrabs/recordings/`, still indexed, so ⌘3 lists them.
- "Dictation's audio stays in Keybumps's own folder, `~/Documents/Keybumps/recordings` (`ProductPaths.recordings`)": it's in the Keybumps folder's `dictation/` (`ProductPaths.dictation`).
