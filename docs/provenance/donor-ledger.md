# Donor ledger

Captured 2026-09-12 before implementation.

| Source group | Donor | Commit | Working tree | Disposition |
| --- | --- | --- | --- | --- |
| App shell and Shortcut Coaching | `/Users/devin/dev/repos/keyboard-shortcut-coach-mac-app` | `5acf2ccb5d26744033546bc3bfb686c9ca69f439` | Dirty planning-doc changes only | Adapted owned source; code copied from commit working tree |
| Dictation behavior | `/Users/devin/dev/repos/serpy-clicky-mac-app` | `964802578ae4fb1a1278ffaa26ecf5ad8f5cc141` | Dirty implementation/evidence tree | Behavior and narrow algorithms adapted from current owned worktree; no guide UI imported |
| Window Management | `/Users/devin/dev/repos/mac-window-manager-app` | `47dc3782a554fe667552bbc426d3edb9fc871a34` | Clean | Rectangle-derived behavior under MIT; `LICENSE.rectangle` preserved (in `apps/macos/` since #161) |


## Screenshot Tools editor (added 2026-09-28, issue #52)

| Source | Donor | Commit | License | Disposition |
| --- | --- | --- | --- | --- |
| Redaction rendering and arrow/freehand/text drawing | [OMARVII/Shotnix](https://github.com/OMARVII/Shotnix) `Sources/ShotnixCore/Annotation/AnnotationRenderer.swift`, `AnnotationObject.swift` | `b50ee603462ea784a80123754c4674f03d759548` | MIT | Adapted into `apps/macos/Keybumps/ScreenshotTools/Editor/ScreenshotAnnotationRenderer.swift` (edge-clamped box-average pixellate, opaque average fill, opaque failure fill, density-aware export, arrow head geometry, flipped text drawing). `apps/macos/LICENSE.shotnix` ships in the app bundle. |
| Value-type annotation model in image points, one undo snapshot per gesture | [archcorsair/skritch](https://github.com/archcorsair/skritch) | `71bbf5783a1ff325808efb24a573dee1c77c66a1` | MIT | Design reference only; no source copied. |
| Minimum redaction strength floor | [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) | `6b88fa6012c2f9b96a3c0de678fa76d8e0929fb1` | BSD-3-Clause | Idea reference only; no source copied. |

No GPL or AGPL source was used. Better Shot was excluded because it mixes BSD-3-Clause with AGPL-3.0/GPL-3.0 files and annotation code of unstated origin.

The new repository has no runtime or checkout-path dependency on any donor. No Superwhisper or Alfred source/assets were copied.

## Timer (added 2026-10-06, issue #205)

| Source | Donor | Commit | License | Disposition |
| --- | --- | --- | --- | --- |
| Duration parsing: `m:ss` and `h:mm:ss`, numbers with units (`1h30m`, `1.5h`), a number without a unit taking the next smaller one (`1h 30`), unit spellings | [edelstone/tock](https://github.com/edelstone/tock) `Tock/TockModel.swift` (`parsedDuration`, `parsedCompositeDuration`, `parsedColonDuration`, `unitForToken`) | `bc36b00ca1c51daba1a428801ebee701b4f120a7` | MIT | Adapted into `apps/macos/Keybumps/Timer/TimerDurationParser.swift`. `apps/macos/LICENSE.tock` ships in the app bundle. |
| A timer as an end date plus remaining time while paused, an injected clock, a finished state that waits to be seen, and one sound per finish | [antonyshakirov/hop](https://github.com/antonyshakirov/hop) `Sources/HopCore/TimerEngine.swift` | `5b5b006c08c4d996cf26e898d46d1eb3afe63c69` | MIT | Design reference only; no source copied. |
| Feature set and lessons (ring until dismissed needs a clear dismiss) | [raycast/extensions](https://github.com/raycast/extensions) `extensions/timers`, `extensions/pomodoro` | `2a329b9` | MIT | Design reference only; no source copied. |

GPL and unlicensed timer apps were excluded.
