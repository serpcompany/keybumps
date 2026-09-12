# Selected dictation archive parity ledger

Reference: Superwhisper 2.18.3 (`com.superduper.superwhisper`) on 2026-09-12. Candidate: SuperMac (`com.serp.supermac`). Private reference transcript values were not inspected or copied.

| Surface | State | Interaction | Persistence boundary | Reference observation | SuperMac acceptance | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Documents archive | Completed dictation | Finish recording | One timestamp directory | `meta.json` plus `output.wav` | `~/Documents/SuperMac/recordings/<timestamp>/` contains both files | Pass |
| Documents archive | Relaunch | Load history | Directory enumeration | Recording folders remain available | Entries reload newest-first without a monolithic index | Pass |
| History | Populated | Search | In-memory filtered metadata | Search field filters transcript cards | Case-insensitive transcript search | Pass |
| History card | Idle audio | Play | Local WAV | Play button and duration strip | Play real `output.wav`; show progress and duration | Pass |
| History card | Playing audio | Pause/resume | Player state | Audio control changes state | Only one recording plays at a time | Pass |
| History card | Available item | Copy transcript | Pasteboard | Copy action is exposed | Exact local transcript is copied | Pass, automated seam |
| History card | Available item | Reveal/info | Finder | Info/reveal action is exposed | Reveal the recording directory in Finder | Pass |
| History card | Available item | Delete | Recording directory | Trash action removes item | Delete exact directory and update UI | Pass, automated seam |
| History | Empty | No interaction | No directories | Empty list | Truthful empty state | Pass, structural |
| History card | Missing audio | Attempt play | Metadata remains | Not observed | Disable playback and label audio unavailable | Deliberate difference, structural |

The selected slice is reconstructed and exercised. Full product parity remains out of scope; the completion manifest still records unrelated unresolved rows and the lack of installed-artifact and independent verification.
