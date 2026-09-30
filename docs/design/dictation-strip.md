# Docked Dictation strip (draft)

Status: **draft design, not decided.** Tracks serpcompany/keybumps#184. The mockups and the open decisions are in [the issue comment](https://github.com/serpcompany/keybumps/issues/184#issuecomment-5915548324). This file is a placeholder spec; the implementation replaces it, and `docs/architecture.md` then describes the result.

## What it is
A narrow, non-activating strip docked to the screen edge while Dictation runs, in place of today's notch indicator. It never takes focus, so text still lands at the original cursor.

- **Status:** a pulsing red dot while Recording. It turns gray while paused, and a spinner replaces it while Transcribing.
- **Timer:** monospaced digits. It freezes while paused or Transcribing.

## Buttons
| Button | Action | Shortcut |
| --- | --- | --- |
| Pause / Play | Pause or resume recording | — |
| Mic mute / unmute | Silence the mic while the recording continues | — |
| Save | Stop → transcribe → insert at the cursor (today's Finish) | Dictation shortcut |
| Trash | Stop → discard the recording (today's Cancel) | Escape |

Save and Trash come in two versions: separate buttons (A), or one Stop button with a Save/Trash flyout (B). Hovering a button shows its shortcut. While Transcribing, only Trash is enabled. If the paste fails, the strip expands into a card with Copy Transcript, Retry and Show in History.

## Open decisions
1. Version A or B.
2. Placement: right edge centered, right edge lower, or left edge.
3. Whether notch notices keep showing during Dictation.
4. Whether Pause releases the microphone, and whether a paused recording can be saved.
5. Whether Mute records silence or skips the muted time.
6. Whether Trash asks for confirmation on long recordings.

## Proposed PRs once decided
1. The strip with Save and Trash, replacing the notch indicator.
2. Recovery actions when a paste fails.
3. Pause and mute, which need changes to Dictation's audio capture.
