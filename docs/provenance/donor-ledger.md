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
| Key names: modifiers in menu order, the special-key table (including the media and JIS keys), keys read through the layout with `UCKeyTranslate` without ⇧, uppercased unless the capital is longer (ß), ⇧⇥ as ⇤, and re-reading the layout when the input source changes; "command keys only" (`isCommand`, ⌃ and ⌘), extended to ⌥ with a key that types nothing | [keycastr/keycastr](https://github.com/keycastr/keycastr) `keycastr/KCEventTransformer.m`, `keycastr/KCKeycastrEvent.m` | `1e552a150afdf8f73fa4a12ba3cca1bbf09eb6ab` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeystrokeNaming.swift` and `KeyPress.swift` (`KeystrokeFilter`). A ⌘ shortcut's key is read through the layout's ⌘ keys, unlike KeyCastr. `apps/macos/LICENSE.keycastr` ships in the app bundle. |
| Lines that stack: a command starts a new line, typing joins the line until a pause, each line fades; the bezel's look (white on 80% black) | [keycastr/keycastr](https://github.com/keycastr/keycastr) `keycastr/KCDefaultVisualizer.m` | `1e552a150afdf8f73fa4a12ba3cca1bbf09eb6ab` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeystrokeTimeline.swift` and `KeyDisplayOverlay.swift` (`KeystrokeLine`). A repeated shortcut counts (×3) instead of adding a line. Covered by `LICENSE.keycastr`. |
| A transparent, borderless overlay window that ignores the mouse, joins every Space and full-screen app, never becomes key or main, and is added back to a ScreenCaptureKit recording by its window number; the bottom-left, center, and right positions with an edge offset | [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) `Snapzy/Features/Recording/Managers/KeystrokeOverlayWindow.swift` | `368bc3384d176503f728eeded125b843214cb3ad` | BSD-3-Clause | Adapted into `apps/macos/Keybumps/Keystrokes/KeyDisplayOverlay.swift` (`KeyDisplayOverlayWindow`, one per screen) and `KeyDisplay.overlayWindowIDs`. `apps/macos/LICENSE.snapzy` ships in the app bundle. |
| A ring that grows and fades where the pointer clicks, drawn in a full-screen click-through overlay | [aurorascharff/ClickLight](https://github.com/aurorascharff/ClickLight) `Sources/ClickLight/ClickOverlayView.swift` | `e214e15ee95df721a5265ccab50f979c8afe7095` | MIT | Design reference only; no source copied (`ClickRing` in `KeyDisplayOverlay.swift`). |

## Screencast recording engine (added 2026-10-10, issue #446)

| Source | Donor | Commit | License | Disposition |
| --- | --- | --- | --- | --- |
| `AVAssetWriter` file with movie fragments, separate system-audio and microphone tracks, a synchronous write queue for backpressure, the writer health check, keeping the footage when a stream or the writer fails, App Nap and idle-sleep activity, and the video stream's setup and frame-status filter | [fayazara/Screendrop](https://github.com/fayazara/Screendrop) `Screendrop/ScreenRecordingManager.swift` (`ScreenRecordingWriter`, `ScreenRecordingCapture`, `ScreenRecordingManager`) | `062a9787d05f52e130fe7489a238e4782883e39e` | CC0-1.0 | Adapted into `apps/macos/Keybumps/Screencast/Recording/ScreencastMovieWriter.swift`, `ScreencastWriterCore.swift`, `ScreencastRecorder.swift`, and `ScreenCaptureKitCaptureSystem.swift`. Nothing from its `Engine/` folder. `apps/macos/LICENSE.screendrop` ships in the app bundle. |
| The pause timeline, audio placement on a gap-free track, trimming and default-format PCM buffers, the per-sample writer core (pending audio before the first frame, padding a quiet source, the final still frame), the own-window filter and `windowsToHide`, capture geometry in even pixels, following a recorded window, and the H.264/HEVC plan and queue depth | [OMARVII/Shotnix](https://github.com/OMARVII/Shotnix) `Sources/ShotnixCore/Capture/RecordingWriterCore.swift`, `RecordingCaptureFilter.swift`, `RecordingEngine.swift`, `RecordingEncoding.swift` | `7cc68cd2adee113d74eb0a432dcfdab1909b4418` | MIT | Adapted into `ScreencastTimeline.swift`, `ScreencastAudioBuffers.swift`, `ScreencastWriterCore.swift`, `ScreencastCaptureFilter.swift`, `ScreencastGeometry.swift`, `ScreencastMovieWriter.swift` (`ScreencastVideoFormat`), `ScreenCaptureKitCaptureSystem.swift`, and `ScreencastRecorder.swift` in the same folder. Covered by the existing `apps/macos/LICENSE.shotnix`, identical at this commit. |
| A second, display-wide `SCStream` (2×2 picture, frames discarded) that hears the whole Mac whatever the video shows, and silence matching a source's format to pad a track's start | [jsattler/BetterCapture](https://github.com/jsattler/BetterCapture) `BetterCapture/Service/SystemAudioStream.swift`, `SilentAudioBuffer.swift` | `ab852b44c4dd09c8e2ae69e7858a1b67e1cd17af` | MIT | Adapted into `ScreenCaptureKitCaptureSystem.makeAudioStream`, which here carries the microphone too and feeds every file, and `ScreencastAudioBuffers.silence`. `apps/macos/LICENSE.bettercapture` ships in the app bundle. |
| The single-track stereo mixdown written after stopping (reader audio mix at 1/N a sound, `mixdownInputVolume`, picture passed through), rebuilding the content filter when an overlay window is added (`addExceptedWindow`, `makeContentFilter`), and the microphone meter's decibel window | [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) `Snapzy/Services/Capture/ScreenRecordingManager.swift` (`RecordingAudioCompatibilityExporter`), `Snapzy/Services/Capture/RecordingAudioLevelMeter.swift` | `368bc3384d176503f728eeded125b843214cb3ad` | BSD-3-Clause | Adapted into `ScreencastAudioMixdown.swift`, `ScreencastCaptureFilter.swift` and `ScreencastRecorder.includeOverlayWindow(_:)`, and `ScreencastAudioBuffers.level(of:)`. `apps/macos/LICENSE.snapzy` ships in the app bundle. |

No QuickRecorder, Cap, Azayaka, or Capso code was used (ADR 0009).

## Screencast picker (added 2026-10-10, issue #447)

| Source | Donor | Commit | License | Disposition |
| --- | --- | --- | --- | --- |
| A borderless, non-activating panel per screen at the screen-saver level that takes the keys, the screen dimmed around the area with the area's size in pixels beside it, the click-through panel that dims everything but the area while it records, the countdown panel with its number and Cancel, cancelled by Escape in Keybumps or another app, and a bar whose inputs dim when off | [fayazara/Screendrop](https://github.com/fayazara/Screendrop) `Screendrop/RecordingAreaSelectionPresenter.swift`, `RecordingAreaHighlightPresenter.swift`, `CaptureCountdownPresenter.swift`, `RecordingPickerBar.swift` | `062a9787d05f52e130fe7489a238e4782883e39e` | CC0-1.0 | Adapted into `apps/macos/Keybumps/Screencast/Picker/ScreencastOverlayWindows.swift` and `ScreencastPickerBar.swift` (`ScreencastCountdownView`); the bar is a design reference. Nothing from its `Engine/` folder. Covered by `apps/macos/LICENSE.screendrop`. |
| Drawing, moving, and resizing the area: pressing outside it draws a new one, inside moves it, and on a handle resizes it, corners before edges, an edge along its own axis, a minimum size, kept on its screen, a new area on another screen replacing it, double-click to confirm, frame-resize cursors, and the size label in even pixels | [jsattler/BetterCapture](https://github.com/jsattler/BetterCapture) `BetterCapture/View/AreaSelectionOverlay.swift` (`AreaSelectionView`, `AreaSelectionOverlay`) | `ab852b44c4dd09c8e2ae69e7858a1b67e1cd17af` | MIT | Adapted into `ScreencastPickerGeometry.swift` (`ScreencastAreaEditor`) and `ScreencastOverlayWindows.swift` (`ScreencastPickerView`). Covered by `apps/macos/LICENSE.bettercapture`. |
| The remembered area (four numbers in AppKit's space, dropped when no screen shows it, saved for an area only), the screen under a point with an unflipped rect's edge rules, and which windows can be picked (ordinary windows over 32 points on a display, front to back in the window server's order, never the app's own) | [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy) `Snapzy/Features/Recording/RecordingCoordinator.swift` (`saveLastAreaRect`, `loadLastAreaRect`), `Snapzy/Services/Capture/ScreenshotLastAreaStore.swift`, `RecordingDisplaySelectionLogic.swift`, `WindowSelectionQueryService.swift`, `WindowCaptureSelectionPolicy.swift` | `368bc3384d176503f728eeded125b843214cb3ad` | BSD-3-Clause | Adapted into `ScreencastAreaMemory.swift`, `ScreencastPickerGeometry.swift` (`ScreencastScreenLayout.screen(containing:)`, `ScreencastWindowPicking`), and `ScreenCaptureKitPickerSystem.content()`. Covered by `apps/macos/LICENSE.snapzy`. |
