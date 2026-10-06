# Adding a plugin

A plugin is a capability people turn on or off (`CONTEXT.md`, ADR 0006). It's first-party and ships in the app; there is no external plugin API. This is the checklist for adding one. Timer (#232) and Emoji Picker (#250–#253, #274) are the worked examples; follow their files.

Ship it in small PRs, in this order: the app's seams first, then the plugin, then the website.

## 1. The app

- **Capability:** a case in `Capability` (`Keybumps/Domain/Capability.swift`).
- **Descriptor and module:** `Keybumps/Capabilities/<Name>Module.swift` declares its `CapabilityDescriptor` and its `CapabilityModule`. The descriptor holds:
  - the title, `systemImage`, and `iconTint`;
  - required and optional permissions (with the reason shown for each), and its dependencies;
  - its Command Palette tab, if it has one. It takes the next free Command-number, and the hidden Hotkeys tab stays last (Emoji Picker took ⌘7, and Hotkeys moved to ⌘8);
  - the Settings page summary and the explanation shown when it's turned off. New plugins draw their page from the manifest with `PluginSettingsPage`;
  - search keywords, the category, and `PluginPreference`s;
  - `isOnByDefault`: ship off when it needs a permission or most people won't want it;
  - `criticalOperations`: declare `.unsavedWork` if it holds anything unsaved, so an update restart waits (#272 is the cautionary case).
- **Registry:** add it to `CapabilityCatalog.descriptors` (`Capabilities/CapabilityModule.swift`), after anything it depends on. Never add it to `defaultCapabilities`, which is the locked original set.
- **Composition:** construct the module in `AppModel` (`App/AppModel.swift`, with the other modules). Give every system boundary an inert stand-in in `App/UITestComposition.swift` and under unit tests.
- **Shortcut:** an optional global shortcut is a `CapabilityShortcut` case in `Infrastructure/GlobalShortcutCoordinator.swift`, with its title and default binding. Leave it unassigned unless it has an obvious key.
- **Settings and palette:** a `SettingsSection` case (`Views/SettingsRootView.swift`), and a `CommandPaletteTab` case (`CommandPalette/CommandPaletteController.swift`) if it has a tab. UI tests open them with `-KBOpenSettings <case>` and `-KBOpenPalette <case>`, which read these enums, so `UITestLaunchConfiguration` needs no change.

## 2. Tests that list every plugin

These name each plugin on purpose, so a new one fails them until it's added:

- `CapabilityCommandTests`, `CapabilityModuleTests`, `KeybumpsFeatureTests`, `PluginManifestTests`, `QuickSearchCommandTests`, `SettingsSidebarTests`, `UITestLaunchConfigurationTests`
- the section list in `SmokeUITests.testEverySettingsPageOpens`
- the wiring snapshot, `KeybumpsTests/Fixtures/capability-wiring.json`. Re-record it with `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1` on the `xcodebuild` command line, and review the diff.

Add the plugin's own tests in Swift Testing (`docs/testing.md`).

## 3. Docs in the same PR

- **README:** the plugin list and the Command Palette tab list.
- **testing.md:** the `-KBOpenPalette` and `-KBOpenSettings` tokens.
- **CONTEXT.md:** any new term.
- **architecture.md:** only a new boundary or seam; keep it a map.
- **Release notes:** `docs/releases/v<version>.md`, merged before the release PR.

## 4. The website

The website lists every plugin on `/plugins/`, gives each its own page, and builds the home page grid from the same list. Website PRs change only `apps/web/**` (`apps/web/AGENTS.md`).

- **Before the release** that ships the plugin, and only if it keeps anything: add a line to the privacy page (`src/app/(analytics)/legal/privacy/page.tsx`).
- **After the release:**
  - an entry in `src/lib/plugins.ts`, copied from the Swift. Move `isNew` to it;
  - its route folder `src/app/(analytics)/plugins/<slug>/page.tsx`, which `plugins.test.ts` requires;
  - a tile in the hero list in `src/app/(analytics)/plugins/page.tsx`;
  - a new SF Symbol mapped in `src/components/plugin-icon.tsx`, and a new tint in `iconTints`;
  - the plugin-count floor in `scripts/smoke.sh`.
