---
status: accepted
---

# ADR 0004: Distribute one local-only commercial product directly

SERP Companion will be sold as a one-time purchase with no trial from its website and distributed only as a Developer ID-signed, notarized direct download. It will not have a Mac App Store or App Store Lite release, because its system-wide coaching, window-management, dictation, and clipboard capabilities do not fit the sandboxed product boundary and the owner does not want parallel release lanes.

The first release supports Apple Silicon Macs running macOS 14.2 or newer. Dictation, search, clipboard content, histories, preferences, and capability processing remain local to the Mac with no account, sync, cloud processing, analytics backend, or application server. The local dictation engine is selected by measured accuracy and latency rather than by model brand, and Settings exposes whichever recognition languages that engine genuinely supports.

The app checks for signed updates at launch, downloads an available update in the background, offers Restart to Update, and otherwise installs it at the next normal quit without interrupting active work. Network access is otherwise limited to commerce and the one-time license activation defined by ADR 0005.

Existing Shortcut Coach App Store artifacts are retained as historical release material, but they do not define a continuing SERP Companion release lane.
