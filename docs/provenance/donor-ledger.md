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

## Emoji Picker data (added 2026-10-06, issue #243)

| Source | Donor | Commit / version | License | Disposition |
| --- | --- | --- | --- | --- |
| Emoji list, order, groups, versions, skin-tone sequences | Unicode [`emoji-test.txt`](https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt) | Emoji 17.0 (2025-08-04), SHA-256 `1d8a944f…` | Unicode-3.0 | Converted by `apps/macos/scripts/generate-emoji-data.swift` into `apps/macos/Keybumps/EmojiPicker/emoji.json`; `apps/macos/LICENSE.unicode` ships in the app bundle |
| Names and keywords | [unicode-org/cldr](https://github.com/unicode-org/cldr) `common/annotations/en.xml`, `common/annotationsDerived/en.xml` | `release-48-2` (`11299982335beb974c1c63c45265184e759c0f41`) | Unicode-3.0 | Same; covered by `LICENSE.unicode` |
| `:shortcode:` aliases | [github/gemoji](https://github.com/github/gemoji) `db/emoji.json` | `v4.1.0` (`5476a66d2794e0d1551b1f96e449afc72e9f7bec`) | MIT | Aliases only; emoji newer than gemoji get one made from their CLDR name. `apps/macos/LICENSE.gemoji` ships in the app bundle |
| Search: every word must start a name word, keyword, or alias; name hits rank first | [missive/emoji-mart](https://github.com/missive/emoji-mart) `src/helpers/search-index.ts` | `16978d04a766eec6455e2e8bb21cd8dc0b3c7436` | MIT | Design reference only; no source copied |

The generator checks each source against its pinned SHA-256 (in the script) before converting it. The app never fetches emoji data. To update, bump all three pins together, rerun the generator, and update this table.

## Keystrokes (added 2026-10-10, issue #443)

| Source | Donor | Commit | License | Disposition |
| --- | --- | --- | --- | --- |
| Key names: modifiers in menu order, the special-key table (including the media and JIS keys), keys read through the layout with `UCKeyTranslate` without ⇧, uppercased unless the capital is longer (ß), ⇧⇥ as ⇤, and re-reading the layout when the input source changes; "command keys only" (`isCommand`, ⌃ and ⌘), extended to ⌥ | [keycastr/keycastr](https://github.com/keycastr/keycastr) `keycastr/KCEventTransformer.m`, `keycastr/KCKeycastrEvent.m` | `1e552a150afdf8f73fa4a12ba3cca1bbf09eb6ab` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeystrokeNaming.swift` and `KeyPress.swift` (`KeystrokeFilter`). A ⌘ shortcut's key is read through the layout's ⌘ keys, unlike KeyCastr. `apps/macos/LICENSE.keycastr` ships in the app bundle. |
| Lines that stack: a command starts a new line, typing joins the line until a pause, each line fades; the bezel's look (white on 80% black) | [keycastr/keycastr](https://github.com/keycastr/keycastr) `keycastr/KCDefaultVisualizer.m` | `1e552a150afdf8f73fa4a12ba3cca1bbf09eb6ab` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeystrokeTimeline.swift` and `KeyDisplayOverlay.swift` (`KeystrokeLine`). A repeated shortcut counts (×3) instead of adding a line. Covered by `LICENSE.keycastr`. |
| A transparent, borderless overlay window that ignores the mouse, joins every Space and full-screen app, never becomes key or main, and is added back to a ScreenCaptureKit recording by its window number; the bottom-left, center, and right positions with an edge offset | [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) `Snapzy/Features/Recording/Managers/KeystrokeOverlayWindow.swift` | `368bc3384d176503f728eeded125b843214cb3ad` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeyDisplayOverlay.swift` (`KeyDisplayOverlayWindow`, one per display) and `KeyDisplay.overlayWindowIDs`. `apps/macos/LICENSE.snapzy` ships in the app bundle. |
| A ring that grows and fades where the pointer clicks, drawn in a full-screen click-through overlay | [aurorascharff/ClickLight](https://github.com/aurorascharff/ClickLight) `Sources/ClickLight/ClickOverlayView.swift` | `e214e15ee95df721a5265ccab50f979c8afe7095` | MIT | Design reference only; no source copied (`ClickRing` in `KeyDisplayOverlay.swift`). |
