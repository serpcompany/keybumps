# 0006: Capabilities are Keybumps's plugins: a default set, then added ones

Status: Accepted (2026-10-06). Tracked by #205, #233, and #235. The third-party extensions non-goal in `AGENTS.md` stands.

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
   - is turned on once for existing installs (known capabilities), and can be turned off in Settings;
   - is listed in its own Settings group, below the default ones.

   Timer is the first.
4. **No marketplace.** Keybumps never downloads or loads code for a capability. People find capabilities through:
   - the Settings sidebar;
   - Quick Search's capability commands;
   - What's New after an update;
   - the website's feature grid.
5. **Revisit with a new ADR** if capabilities should update separately from the app, or other people should write them. That ADR has to settle:
   - how the code runs (a manifest and a script runtime, or signed bundles);
   - how it's kept away from user content such as Clipboard History, transcripts and snippets;
   - signing and notarization;
   - distribution and review;
   - pricing.

## Consequences

- Adding a capability takes an app release, and only Keybumps writes them.
- Each new capability's PR, or its release, also:
  - adds its terms to `CONTEXT.md`;
  - writes its What's New lines in `docs/releases/`;
  - adds it to the website's feature grid, and to the privacy page if it keeps anything;
  - adds a donor ledger entry and a `LICENSE.*` if it adapts outside code;
  - adds a UI smoke test that opens its tab or page.
- The shell seams Timer needed now serve every capability: a module's own palette tab (`CapabilityPaletteContent`), the menu bar dot (`MenuBarAttention`), text and menu sections on the menu bar item (`MenuBarStatus`), and waiting for the notch (`PaletteHUD.whenNotchFree`).
- **Recipe gaps still open**, each a small shared-code edit per capability:
  - a shortcut's details in `CapabilityShortcut`;
  - settings in `AppPreferences`;
  - Command-numbers assigned by hand.
