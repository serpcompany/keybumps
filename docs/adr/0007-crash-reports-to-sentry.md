# 0007: Crash reports go to Sentry, on by default, and never carry user content

Status: Accepted (2026-10-06). Tracked by #258.

## Context

On another Mac, the owner couldn't open the dropdowns in Dictation settings. Nothing reached us but their own report, and nobody could say which macOS that Mac ran. Keybumps had no way to learn about a crash, a freeze, or a bug a person ran into. `AGENTS.md` said user content and processing stay local, with no analytics, and the privacy policy said the app has none.

Raycast, superwhisper, and The Unarchiver all ship Sentry's macOS SDK. SwiftUI has no built-in problem-report form, and Apple's Feedback Assistant is only for Apple's software. MetricKit's crash and hang diagnostics arrive a day late with less context.

## Decisions

1. **Crash reports go to Sentry**: organization `serpcompany`, project `keybumps-mac`, through `sentry-cocoa` (`CrashReporting.swift`). Only Release builds carry the destination (`KEYBUMPS_CRASH_REPORTS_DSN`), so Debug builds and the unit-test host never send. QA candidates report as `qa` and releases as `production`; CI publishes one build to both update channels, so staging installs report as production.
2. **On by default, with an off switch** in Settings › General ("Send crash reports"). The switch takes effect at once. Reporting starts first thing at launch, so a crash during startup is caught too.
3. **What a report carries:** crashes and freezes with their stack traces; the Keybumps and macOS versions; the Mac's model, chip, and memory; and which plugins are on. Nothing is sent when nothing goes wrong: Sentry's session records, which report each launch and how long the app ran, are off, so there's no crash-free-users rate. Sentry's `device_app_hash`, derived from the Mac's network address, and the locale are removed.
4. **What it never carries**, the same list as before: clipboard contents, snippets, transcripts, recordings, screenshots, searches, window or document titles, file names, and URLs. (One known gap: Korean and Dutch macOS quote file names with single quotes, which the scrubber can't tell from apostrophes.) Sentry's automatic breadcrumbs, network capture, and tracing are off. Every event passes `CrashReportScrubber` before it's sent, crashes from an earlier run included. The scrubber removes paths in a home folder, on another volume, or in a temporary folder, URLs, and email addresses from free text, exception data included (a binary's path keeps only its file name), and keeps only the contexts and breadcrumbs the policy names. `CrashReportingTests` holds it to that.
5. **Uncaught Objective-C exceptions stay as they were.** Sentry's `enableUncaughtNSExceptionReporting` makes macOS end the app on one, where today AppKit logs it and carries on. Revisit if reports show we're missing them.
6. **Release builds upload debug symbols** to Sentry, so stack traces name Keybumps's code.
7. **Report a Problem…** (Help menu, the menu bar menu, and Settings › General) sends what a person writes, with the details from decision 3 plus permission states, and shows them every detail before sending. It goes as an ordinary event, so `CrashReportScrubber` runs on it; Sentry's user-feedback API skips that hook. It sends even with crash reports off, because the person chose to send it: Sentry then runs only for the send, with crash and freeze reporting off and its own queue, so a crash report queued before reports were turned off doesn't go with it. The window's details are sent as the report's `details`, since Sentry doesn't send the chip's name; the window says Sentry adds technical details of its own. What the person writes loses paths, URLs, and email addresses, but quoted text stays: it's their words, not a file name Cocoa quoted. A contact email is kept only when the person types one.

## Consequences

- The `keybumps-mac` project has **Prevent Storing of IP Addresses** on, and the advanced data scrubbing rule `[Remove] [Anything] from [$user.geo.**]` (Settings › Security & Privacy). Sentry works out a city from the sending IP before the IP setting applies, so it takes both; the app never sends either.
- `AGENTS.md` allows crash and problem reports to Sentry and still forbids analytics and sending user content.
- The privacy policy on keybumps.app must say so before the first release that includes this.
- A QA candidate (and only a QA candidate) crashes on purpose with `-KBTestCrash YES` or freezes with `-KBTestFreeze YES`, whether or not reports are on, so its owner can see a real report arrive and see that none arrives with the switch off.
- A bug that neither crashes nor freezes, like the dropdowns, still needs a person to report it. Report a Problem covers that.
