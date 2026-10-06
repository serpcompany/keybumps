# 0006: Capabilities are Keybumps's plugins: a default set, added ones, and an official-only plugin list

Status: Accepted (2026-10-06). Tracked by #205, #233, #235, and #239. The third-party extensions non-goal in `AGENTS.md` stands.

## Context

The owner wanted to lock the current feature set as the "default plugins" Keybumps ships with, and to keep adding more, the way Raycast adds extensions. Keybumps already builds each feature as a first-party capability module (`docs/architecture.md`). Timer (#205) was built as the first new one, to test that recipe. The research and mockups are on #205.

Raycast does it differently:
- A few built-in extensions ship with the app.
- Everything else comes from its Store, which you can browse in the app and on raycast.com/store.
- Store extensions are open-source TypeScript and React. Their authors submit them as pull requests to one public repository, Raycast reviews them, and they run in a Node runtime the app downloads and updates on its own.

That model needs a runtime for outside code, an isolation and permission model, a review pipeline, and a way to distribute and sign extensions.

## Decisions

1. **"Plugin" is the owner's word for a capability.** Code and docs keep saying capability (`CONTEXT.md`).
2. **The default capabilities** are the seven the feature set was locked at: Quick Search, Clipboard History, Screenshot Tools, Dictation, Window Manager, Shortcut Coach, and Snippets (`CapabilityCatalog.defaultCapabilities`).
3. **Added capabilities ship inside the app, first-party.** Each is built with the recipe in `docs/architecture.md` and reaches people in a normal release, through Sparkle. A new one:
   - is turned on once for existing installs (known capabilities), unless its manifest says it ships off (`isOnByDefault`), and can be turned on or off in Settings;
   - is listed in its own Settings group, below the default ones.

   Timer is the first.
4. **An official-only plugin list, modeled on Raycast's Store (#239).** The owner's call: build the Raycast shape now, listing only official plugins built by Keybumps.
   - **Plugin manifests:** each capability declares its name, summary, icon, category, commands, the permissions it needs, and its preferences as typed settings. Its preferences are stored under the plugin's own name.
   - **One settings template:** the shell draws every plugin's Settings page from its manifest in a fixed order: header, Commands, permissions, preferences. A plugin's genuinely custom parts, such as the Snippets library, go in one slot below.
   - **Settings › Plugins:** like Raycast's Extensions list, a searchable page of every plugin with its palette tab, shortcut, and switch. Each plugin keeps its own row in the Settings sidebar, one column as before, and a row on the Plugins page opens it.
   - **Plugins on keybumps.app:** the website's Plugins page at `/plugins`, with a page for each plugin, which Settings › Plugins links to ("Browse on keybumps.app"). It lists every official plugin by category, each shown as "Official · by Keybumps". Every plugin ships in the app, so the website only shows them; Settings › Plugins turns them on and off, and Quick Search's Plugins command opens it. On 2026-10-06 the owner chose the website over a Store inside the Command Palette, and the name Plugins over Store.
   - **Not yet:** Keybumps never downloads or loads code. Every plugin listed ships inside the app.
5. **Revisit with a new ADR** if capabilities should update separately from the app, or other people should write them. That ADR has to settle:
   - how the code runs (a manifest and a script runtime, or signed bundles);
   - how it's kept away from user content such as Clipboard History, transcripts and snippets;
   - signing and notarization;
   - distribution and review;
   - pricing.

## Consequences

- Adding a capability takes an app release, and only Keybumps writes them. Its manifest is the part a third-party plugin would one day provide, so the settings template won't need to change if that day comes. The website's Plugins page keeps its own copy of each manifest's facts (`apps/web/src/lib/plugins.ts`).
- Each new capability's PR, or its release, also:
  - adds its terms to `CONTEXT.md`;
  - writes its What's New lines in `docs/releases/`;
  - adds an entry to `apps/web/src/lib/plugins.ts` and its `src/app/(analytics)/plugins/<slug>/` route, which feed both the Plugins page and the home page's grid, in a website PR that merges after the release that ships it; if it keeps anything, the privacy page says so before that release;
  - adds a donor ledger entry and a `LICENSE.*` if it adapts outside code;
  - adds a UI smoke test that opens its tab or page.
- The shell seams Timer needed now serve every capability: a module's own palette tab (`CapabilityPaletteContent`), the menu bar dot (`MenuBarAttention`), text and menu sections on the menu bar item (`MenuBarStatus`), and waiting for the notch (`PaletteHUD.whenNotchFree`).
- **Recipe gaps still open**, each a small shared-code edit per capability:
  - a shortcut's details in `CapabilityShortcut`;
  - settings outside the manifest: a plugin's declared preferences are stored by name, but the older plugins' settings stay in `AppPreferences` until their pages move to the template;
  - Command-numbers assigned by hand.
