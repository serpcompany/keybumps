# 0012: The window is Quick Search, and its first tab is the Search tab

Status: Accepted (2026-10-19). Tracked by #553. Supersedes `CONTEXT.md`'s Command Palette term and its "_Avoid_: Quick Search panel"; see "Superseded".

## Context

Keybumps has one floating, keyboard-first window, with a tab for each plugin that has one. `CONTEXT.md` called it the Command Palette, called only its first tab Quick Search, and told everyone to avoid "Quick Search panel". People never saw that split: ⌘Space is "Open Quick Search" and opens the whole window, Settings has a Quick Search page and no Command Palette one, and the app's text said "Command Palette" in only a few places, such as the Snippets summary and the Hotkeys tab's switch. So one window had two names.

On 2026-10-19 the owner decided (#553) that the window is Quick Search. The same decision makes Settings › Quick Search the window's page, lets tabs be reordered and hidden there, and has the tab keys follow that order; #553's later PRs carry those out. This record is the naming.

## Decisions

1. **The window is Quick Search** wherever people see it: the app's text and VoiceOver labels, `CONTEXT.md`, the README, and the docs. "Command Palette" retires from them.
2. **Its first tab is the Search tab:** apps, files, folders, snippets, emoji, and Quick Search commands. Quick Search commands keep their name. The other tabs are Quick Search's tabs, such as Quick Search's Snippets tab.
3. **A tab's ⌘ and number is its tab key**, from ⌘1 for the Search tab to ⌘9 for the Hotkeys tab. It replaces "Command-number" in `CONTEXT.md` and the docs, and matches `PluginsTable.tabKey`.
4. **Code keeps the former name for now:** the types (`CommandPaletteController`, `CommandPaletteTab`, and `Palette` in other types' names), the accessibility identifiers (`commandPalette`, `palette.tab.<tab>`), and the `-KBOpenPalette` launch argument, so no UI test or stored state changes. `CONTEXT.md` maps the names meanwhile, as it does for ScreenGrabs' `Screencast` types (ADR 0010), and docs that describe this code, such as `docs/architecture.md`, can call it the palette where they name the code. Renaming the types can follow on its own.
5. **The website changes after a release ships this,** so keybumps.app never names something the released app doesn't show.

## Consequences

- The plugin and the window share a name. Settings › Quick Search is the page of the Quick Search plugin, which owns ⌘Space and the Search tab. Until #553's second PR, turning that plugin off closes the Search tab and releases ⌘Space, while another plugin's shortcut, such as ⇧⌘Space, still opens Quick Search on its own tab.
- In code, the `QuickSearch` types (`QuickSearchModel`, `QuickSearchCommand`, `QuickSearchRanking`) are the Search tab's, and the window's are `CommandPalette*`.
- Release notes, `CHANGELOG.md`, and earlier ADRs keep "Command Palette": they record what was true when they were written.

## Superseded

From `CONTEXT.md`: the Command Palette entry, now Quick Search, and its "_Avoid_: Quick Search panel". Where ADRs [0004](0004-keyword-auto-expansion.md), [0006](0006-capabilities-as-plugins.md), and [0009](0009-screencast-records-and-sends-captures.md) say Command Palette, read Quick Search.
