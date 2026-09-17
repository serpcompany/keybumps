# Key Bumps MVP feature inventory

This inventory describes the full release lane. The App Store Lite lane provides the shortcut library, active-app guidance, presentation previews, app presence, menu-bar access, and Full Version website CTA; it excludes Accessibility permission and manual-action detection.

## User journey

1. SuperMac launches in the Dock, Cmd-Tab, and menu bar.
2. The user grants Accessibility permission.
3. The detector observes a supported menu item, Chrome control, standard window control, or Finder-to-Trash drag.
4. The click becomes one durable key bump.
5. The inbox unread count updates.
6. The delivery module fans the event out to the selected presentation channels.
7. The user can review, mark read, search, or clear history.

## Product surfaces

| Surface | MVP behavior | Verification |
| --- | --- | --- |
| Menu bar | Always inserted; opens Key Bumps history | Implemented; clean menu-extra screenshot still limited by this Mac's crowded status area |
| Key Bumps history | History rows, unread state, mark read, mark all read, test event, Open Settings | Runtime and persistence verified |
| Main window | History, Notification Styles, App Presence, Permissions, Diagnostics | Runtime verified |
| Dock | Visible by default; optional unread badge and attention request | Presence policy verified; badge/attention visual acceptance remains |
| Cmd-Tab | Visible with Dock under regular activation policy | Foreground/UIElement transition verified |

## Presentation channels

Durable inbox recording is mandatory and occurs before transient delivery. Users can enable any set of these additional channels:

| Channel | Behavior | MVP status |
| --- | --- | --- |
| Native macOS Banner | Notification Center banner | Implemented; permission-dependent live acceptance remains |
| Top-right Toast | Compact custom key-bump card | Implemented; real Finder event notification confirmed by human |
| Top-center Shelf | Prominent top-center key-bump shelf | Implemented with preview; visual acceptance remains |
| Pointer Card | Key-bump card beside pointer location | Implemented with preview; visual acceptance remains |
| Status Feedback | Brief evaluating-to-success state | Implemented with preview; visual acceptance remains |
| Decision Banner | Wide prompt with dismiss actions | Implemented with preview; visual acceptance remains |
| Dock Badge | Shows durable unread count | Implemented; unread behavior tested, Dock capture remains |
| Dock Bounce | Requests informational attention | Implemented; live acceptance remains |
| Sound | Plays the system Glass sound from its separate Sound settings section | Implemented; audible owner acceptance remains |

## Settings and diagnostics

- Enable or disable each transient presentation channel.
- Preview each presentation channel and Sound with the same delivery adapters used by detected events.
- Close custom presentations with their close button, Escape, or a horizontal trackpad swipe; hover pauses the remaining auto-dismiss duration.
- Show or hide the app in the Dock and Cmd-Tab together.
- View Accessibility permission state and request/retry detection.
- Send a test key bump.
- Inspect per-channel delivery outcomes.
- Search history and manage read state.

## Detector coverage

The detector reads live shortcut metadata for clicked AXMenuItem elements. Chrome rules recognize characterized New Tab, active-tab Close, direct tab selection, and Settings. Standard window-control rules retain the clicked window and require a close, minimize, or frame-change postcondition. Finder-to-Trash uses a separate cross-process drag monitor and emits only when the Finder source disappears after reaching the Dock Trash target. Ambiguous or incomplete Accessibility data is silently suppressed.

Covered:

- Physical click on Finder → File → New Finder Window.

Not yet covered:

- Uncharacterized Chrome or Safari controls.
- Toolbar buttons and other non-menu controls.
- Context-menu commands that do not expose shortcut metadata.
- Commands without a keyboard shortcut.
- Application-specific semantic mappings outside the implemented slices.
