# Chrome tab-strip characterization

`chrome-153-tab-strip.json` is the sanitized structural projection of the local Chrome 153.0.8010.12 Accessibility observation described in `docs/research/chrome-non-menu-action-detection.md`.

`chrome-153-settings-failing-trace.json` is the privacy-sanitized projection of the agent-run physical action recorded on issue #14: opening Chrome's three-dot menu and choosing Settings navigated successfully but produced no coaching event. The replay retains only the two pointer gestures, generic AX control roles/actions, a live-command resolution state, tab counts, and a derived destination class. It does not retain the address value used to derive that class.

It intentionally retains only generic browser-chrome semantics used by deterministic tests: bundle identity, role, generic control name, Press support, selected state, tab ancestry, and sibling order. It excludes page content, tab titles, URLs, account/profile data, and browsing history.

The current slice uses a short bounded Accessibility re-query after mouse-up. AXObserver notification support has not yet been characterized on every target control. The Settings trace proves deterministic behavior through the production orchestration seam, but a fresh installed-build physical replay is still required to prove the repaired system adapters against live Chrome.

The adapter's static Chrome shortcut defaults for tab-strip actions are explicitly tied to the tab-strip fixture version and tested. Settings has no static fallback: the system adapter must resolve exactly one enabled command from Chrome's live application menu and the post-query must return the same shortcut plus the sanitized Settings destination.
