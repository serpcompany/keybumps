# 0009: Screencast records the screen and sound, and sends a capture to the person's own Clipy account when they choose

Status: Accepted (2026-10-10) when the owner merges it. Tracked by #329.

## Context

The owner builds many sites and apps and keeps finding bugs and changes while using them. Turning one into a useful report takes too long: a screenshot, a recording, typing out what happened, finding the right repository, filing the issue. The owner wants one hotkey that captures what's on screen (a screenshot or a video, with their voice, the Mac's sound, the keys they press, and drawing) and one more keypress that turns it into a GitHub issue a person or an agent can act on. #329 asked for quick screen recordings with annotations and for pushing videos into a Clipy account.

Three rules stood in the way. `AGENTS.md` keeps user content and processing local, with no accounts or hosted history; it lists system-audio capture as a non-goal; and Keybumps supports macOS 14.2, where ScreenCaptureKit can't record the microphone.

Clipy (clipy.online) is a third-party screen recorder built for coding agents. It turns a recording into a summary, a transcript, key moments with frames and pointer positions, and an interaction timeline, and hands all of it to an agent through its CLI (`clipy context <id>`), its MCP server, or, for a public recording, the AREC document at the recording's URL plus `.arec`. What it offers an integration, as of 2026-10-10:
- **REST API v1** (`/openapi/clipy-v1.json`): reads recordings, renames them, changes their share mode and tags. It has no endpoint for uploading a video.
- **The CLI** uploads videos (`clipy proof --video`) through `/api/videos/raw-upload/*`, which isn't documented.
- **The `ingest` scope**, which creating content needs, comes only with an API key the person makes; OAuth can't grant it.
- **Webhooks**: signed (Standard Webhooks) events when a recording, transcript, summary, or key moments are ready.
- **Share links are unlisted by default**: anyone with the link can watch.

## Decisions

1. **Screencast is an added plugin that ships off** (ADR 0006, `isOnByDefault` false), built with the recipe in `docs/adding-a-plugin.md`. The person turns it on and sets it up in Settings › Screencast: permissions, audio defaults, and the Clipy key if they want to send.
2. **It needs macOS 15** (`minimumMacOS`), so ScreenCaptureKit records the screen, system audio, and microphone in one stream. On 2026-10-10 the owner decided macOS 14 doesn't need it. Keybumps itself still supports 14.2.
3. **What it captures:**
   - screenshots and video of an area, a window, or every screen, reusing Screenshot Tools' selection, redaction, and markup;
   - the microphone and system audio, each with its own switch;
   - a floating control bar with the elapsed time, pause and resume, stop, discard, restart, the audio switches, and drawing. The bar is left out of the recording;
   - the keys pressed, shown on screen, but only combinations with ⌘, ⌃, or ⌥, never plain typing. It reuses Keybumps's existing key monitoring;
   - drawing on screen while recording, and optionally a ring where the pointer clicks.
4. **Captures stay on the Mac until the person sends one.** Each is saved under `~/Documents/Keybumps/captures/<timestamp>/`, as Dictation keeps recordings. A review panel after each capture takes a one-line note, the type (bug, feature, or feedback), and the target repository, guessed from the frontmost app's bundle ID or the browser's domain and remembered once corrected. It then offers what to do with it, and shows what will be sent before anything is:
   - **Save**: keep it on the Mac only;
   - **Save and Send**: keep it and send it to Clipy;
   - **Send and Delete**: send it, then delete the local copy once Clipy confirms the upload. If the upload fails, the capture stays;
   - **Copy**: put the screenshot or video on the clipboard;
   - **Discard**.
5. **Send to Clipy goes to the person's own account**, with a Clipy API key they create and paste in Settings › Screencast, kept in the Keychain. It sends the media, the note and type, the target repository, the app's name and bundle ID and the browser's domain at capture time, and the Mac, macOS, and Keybumps versions. Keybumps then makes the recording **private** through the API, so the link isn't left unlisted.
6. **Keybumps uploads only through an endpoint Clipy documents.** Until Clipy publishes one, Send to Clipy hands the file to the installed `clipy` CLI, and the button explains how to install it when it's missing.
7. **Keybumps never files GitHub issues or holds a GitHub token.** A small webhook receiver run by SERP, a Cloudflare Worker, takes Clipy's `summary.ready` and `key_moments.ready` events and files the issue in the repository the capture named. It dedupes on the webhook ID and the recording ID. The issue holds the summary, the action items, a thumbnail, the link, the label `clipy`, and a marker an agent can find: `Clipy: <link>` and `<!-- clipy:<id> -->`. An agent picking up the issue runs `clipy context <id>` or the MCP tool `get_agent_context`.

## Consequences

- `AGENTS.md` changes with this decision: user content still stays local except a capture the person sends to their own Clipy account, and system-audio capture leaves the non-goals. Meeting capture stays a non-goal.
- Crash and problem reports don't change. A capture never goes to Sentry, and `CrashReportScrubber` doesn't see it.
- The privacy policy on keybumps.app must describe Screencast and Clipy before the first release that includes it.
- Screencast asks for Screen Recording and Microphone, which Screenshot Tools and Dictation already request, and for whatever permission the existing key monitoring needs.
- A capture depends on a third party only once it's sent. If Clipy changes its API or shuts down, captures still save, copy, and open locally.
- The webhook receiver is a separate deployment with its own secrets (the Clipy signing secret and a GitHub token), outside this repository.
- iOS comes later and needs its own decision: a share extension or a broadcast extension, and in which app.

## Open

- Is Send to Clipy part of Keybumps Pro?
- Does it get a Command Palette tab? ⌘1–⌘9 are taken (`docs/adding-a-plugin.md`).
- Where does the repository mapping live: in Keybumps, sent with each capture (as above), or in the webhook receiver?
- A rolling buffer that keeps the last 30 seconds, so a hotkey saves what already happened.
