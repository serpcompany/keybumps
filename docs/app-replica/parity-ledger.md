# Selected product-slice parity ledger

Reference: Superwhisper 2.18.3 (`com.superduper.superwhisper`) on 2026-09-12. Candidate: SuperMac (`com.serp.supermac`). Private reference transcript values were not inspected or copied.

| Surface | State | Interaction | Persistence boundary | Reference observation | SuperMac acceptance | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Documents archive | Completed dictation | Finish recording | One timestamp directory | `meta.json` plus `output.wav` | `~/Documents/SuperMac/recordings/<timestamp>/` contains both files | Pass |
| Dictation settings | Default and customized duration | Select maximum length | User defaults | Five-minute reference default reported by owner | Default 5 minutes; 10, 15, 30, 60 minutes and No Limit persist | Pass |
| Dictation engine | Pause or early recognition final | Stop recording | Completed local WAV | Reference supports multi-minute dictation | Transcribe the completed WAV rather than an early live final result | Pass |
| Dictation engine | Recognition failure or timeout | Finish recording | Recording directory | Not observed | Preserve playable WAV with explicit failed-transcription metadata | Deliberate difference, pass |
| Documents archive | Relaunch | Load history | Directory enumeration | Recording folders remain available | Entries reload newest-first without a monolithic index | Pass |
| History | Populated | Search | In-memory filtered metadata | Search field filters transcript cards | Case-insensitive transcript search | Pass |
| History | Populated | Clear History | Destructive confirmation | Reference exposes deletion controls | Native bordered button requires confirmation; alert focus/clicks never dismiss the palette | Pass, runtime cancellation |
| History card | Collapsed | Select card | Expansion state | Two-line transcript preview expands on selection | Expand selected card and collapse the previous card | Pass |
| History card | Collapsed | Click padded header | Button hit region | Whole card reads as the disclosure row | Full-width padded target with hover feedback and accessibility hint | Pass, structural |
| History card | Expanded | Review item | Metadata and audio pair | Full transcript appears above audio and actions | Full transcript, real waveform/audio, duration, Original label, and working actions | Pass |
| History card | Expanded transcript | Translate | Apple Translation framework | New SuperMac feature, not part of reference slice | Custom on-device target picker and translated output; original remains unchanged | Reconstructed; model download pending |
| Translation panel | Translated text | Play Translation | Installed macOS speech voices | New SuperMac feature, not part of reference slice | Match the target language, play/stop on demand, stop on close, and do not persist generated speech | Automated selector; runtime audio pending |
| History card | Idle audio | Play | Local WAV | Play button and duration strip | Play real `output.wav`; show progress and duration | Pass |
| History card | Playing audio | Pause/resume | Player state | Audio control changes state | Only one recording plays at a time | Pass |
| History card | Available item | Copy transcript | Pasteboard | Copy action is exposed | Exact local transcript is copied | Pass, automated seam |
| History card | Available item | Reveal/info | Finder | Info/reveal action is exposed | Reveal the recording directory in Finder | Pass |
| History card | Available item | Delete | Recording directory | Trash action removes item | Delete exact directory and update UI | Pass, automated seam |
| History | Empty | No interaction | No directories | Empty list | Truthful empty state | Pass, structural |
| History card | Missing audio | Attempt play | Metadata remains | Not observed | Disable playback and label audio unavailable | Deliberate difference, structural |
| Command Palette Dictation | Selected item | Arrow/click selection | Palette selection | Earlier candidate used one compact transcript row | Reuse rich accordion card with transcript, audio, Paste, Copy, Translate, info, and delete | Pass |
| Command Palette Dictation | Playing audio | Switch tab or close | Ephemeral player state | Not observed | Stop playback when rich Dictation results disappear | Pass, structural |

The selected slice is reconstructed and exercised. Full product parity remains out of scope; the completion manifest still records unrelated unresolved rows and the lack of installed-artifact and independent verification.

## Window Management settings layout

| Surface | State | Interaction | Persistence boundary | Reference observation | SuperMac acceptance | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Window settings | Default | Review shortcuts | Existing shortcut preferences | Two compact columns with action footprint, recorder, and clear control | Same information hierarchy inside SuperMac sidebar and status header | Reconstructed; runtime inspected |
| Window settings | Assigned/unassigned | Record or clear | Existing shortcut preferences | Assigned keys show glyphs; empty keys say Record Shortcut | Existing working recorder and clear behavior retained for every supported action | Pass, automated behavior |
| Window settings | Full list | Scroll | View only | Primary layouts above divider; fractional layouts below | All 30 supported actions appear once in four ordered groups | Pass, automated inventory |

## Clipboard rich-media history

| Surface | State | Interaction | Persistence boundary | Reference observation | SuperMac acceptance | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Clipboard palette | Copied image | Review | Separate local media file plus history metadata | Rich clipboard history requested by owner | Thumbnail, Image label, relative time, and selected-row treatment | Reconstructed; runtime image pending |
| Clipboard palette | Selected image | Return/click | System pasteboard | Rich clipboard history requested by owner | Restore original image bytes and pasteboard media type | Pass, automated named pasteboard |
| Clipboard store | Relaunch/delete/evict/clear | Manage history | Application Support | Bounded history requested by owner | Ten total entries; image file reloads and is removed with lifecycle | Pass, automated storage |
