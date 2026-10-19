# Adding a plugin

A plugin is a capability people turn on or off (`CONTEXT.md`, ADR 0006). It's first-party and ships in the app; there is no external plugin API. This is the checklist for adding one. Timer (#232) and Emoji Picker (#250–#253, #274) are the worked examples; follow their files. App paths below are under `apps/macos/Keybumps/` (tests under `apps/macos/`), and website paths under `apps/web/`.

Ship it in small PRs, in this order: the app's seams first, then the plugin, then the website.

## 1. The app

- **Capability:** a case in `Capability` (`Domain/Capability.swift`).
- **Descriptor and module:** `Capabilities/<Name>Module.swift` declares its `CapabilityDescriptor` and its `CapabilityModule`.
  - **Basics:** the title, `systemImage`, and `iconTint`; search keywords, the category, and any `PluginPreference`s.
  - **Permissions:** required permissions show `MacPermission.explanation` (`Infrastructure/SystemServices.swift`). Add the plugin to the explanation of each one it needs. Optional permissions carry their own reason. (The website entry's permission reasons come in §4.)
  - **Settings page:** its summary, and the explanation the on/off switch shows as a tooltip. New plugins draw their page from the manifest with `PluginSettingsPage`; a switch that governs the rest of the page goes under its header with `placement: .top`, and can't change while the plugin is off. Rows no declaration covers go in its slots: above the declared preferences (`abovePreferences`, as ScreenGrabs' Screenshots group), at the end of one of their groups (`groupRows`, as ScreenGrabs' recordings folder under Recordings), or last (`custom`). A declared preference that moved from a retired plugin keeps its stored key through `storageName`, as ScreenGrabs' recording preferences keep `plugin.screencast.<key>`. A page drawn by hand shows the plugin's optional permissions with `PluginPermissionsGroup`, and `PluginManifestTests` fails if a page leaves one out (#379).
  - **Its tab in Quick Search, if any (`paletteTab`):** the module's `paletteContent` supplies the rows, drawn with `PaletteRow` under a `PaletteListHeader` (or, for a grid, inset to `PaletteRowMetrics.wellX`), so switching tabs moves nothing (#381). Each row's button is a `PaletteClickButton` that reports to the context's `click`, and the tab's `clickAction` says what one click does: `.acts` does Return's action, where a row has one obvious job, and `.selects` highlights it, where the tab shows the highlighted row's actions (#552). The descriptor's `systemImage` is the tab's icon in the tab bar, so it must differ from the other tabs'. The tab takes the next tab key, and the hidden Hotkeys tab moves to stay last. Emoji Picker took ⌘7, then Translation took ⌘8 and Hotkeys moved to ⌘9. Moving Hotkeys also changes:
    - `KeyboardShortcutterModule`'s `commandKey`;
    - the README and architecture.md tab lists, and the release notes;
    - Shortcut Coach's `commandKey` in the website's `plugins.ts`, whose test requires unique numbers.

    Quick Search matches one typed digit, and Hotkeys now has ⌘9, the last one: a tenth tab needs another way in.
  - **Quick Search actions, if any:** `actions` lists the `PluginAction`s Quick Search offers while it's on, such as Show or Hide Keystrokes. The module runs them in `perform`, and can rename one for its state in `title(for:)` or leave it out for now in `offers`. An action's `id` never changes once shipped: it keys the action's learned usage.
  - **`isOnByDefault`:** most plugins ship on. Emoji Picker, Translation, and Keystrokes ship off. Several tests depend on this choice (§2).
  - **`minimumMacOS`:** set it when the plugin needs a newer macOS than Keybumps does, as Translation needs 15. `PluginCompatibility` then keeps it off on older Macs and Settings says why; give its macOS-only code an inert path for the older ones. When only part of a plugin needs it, gate that part through `PluginCompatibility` instead, as ScreenGrabs' recording reads `supportsRecording`, never `#available`, which a test can't fake.
  - **`criticalOperations`:** a plugin that holds unsaved work must make an update restart wait. It has to be declared *and* set while work is unsaved (`updateSafety.setCriticalOperation(_:active:)`, as `ScreenshotToolsModule` does); declaring alone does nothing. But `.unsavedWork` is one shared flag: a second plugin that clears it also clears the Screenshot Editor's, and the quit warning in `Updates/UpdateController.swift` names only the Screenshot Editor. So first give each source its own case (or count holders) and its own quit reason, which is #272.
- **Registry:** add it to `CapabilityCatalog.descriptors` (`Capabilities/CapabilityModule.swift`), after anything it depends on. Construct its module in `AppModel` (`App/AppModel.swift`) in the same order, or a launch precondition stops the app. Never add it to the locked sets `defaultCapabilities`, `Capability.originalCapabilities`, or `CapabilityShortcut.originalShortcuts`.
- **Seams:** give every system boundary an inert stand-in in `App/UITestComposition.swift` and under unit tests.
- **Shortcut:** an optional global shortcut is a `CapabilityShortcut` case in `Infrastructure/GlobalShortcutCoordinator.swift`, with its title and default binding. Leave it unassigned unless it has an obvious key.
- **Settings and palette enums:** a `SettingsSection` case (`Views/SettingsRootView.swift`), and a `CommandPaletteTab` case (`CommandPalette/CommandPaletteController.swift`) if it has a tab. UI tests open them with `-KBOpenSettings <case>` and `-KBOpenPalette <case>`, which read these enums, so `UITestLaunchConfiguration` needs no change.
- **Third-party code or data:** if it bundles any, add all of these:
  - the `LICENSE.*` file in `apps/macos/`;
  - its resources entry in `project.yml`;
  - the bundled-license list in `KeybumpsFeatureTests`;
  - a row in `docs/provenance/donor-ledger.md`;
  - the README's attribution paragraph.

## 2. Tests that list plugins

These name plugins on purpose. Update every one. Some fail when a plugin is missing. Some fail only when it ships on (or off). The smoke lists pass without it but then don't cover it.

- **Plugin lists:** `CapabilityCommandTests`, `CapabilityModuleTests`, `KeybumpsFeatureTests`, `PluginManifestTests`, `QuickSearchActionTests` (only the plugins it names may declare actions), `QuickSearchCommandTests`, `SettingsSidebarTests`, `UITestLaunchConfigurationTests`.
- **Tab keys:** a new tab moves Hotkeys and the first unused number, which these check:
  - `SnippetTests`' tab order and tab keys;
  - `EmojiPickerTests` (Hotkeys' number);
  - `KeybumpsFeatureTests`, which expects ⌘0 to match nothing.
- **Tab layout:** `PaletteRowMetricsTests` lays out every tab and fails until a new one is in its list tabs or grid tabs; give the fixture made-up rows for it.
- **Tab clicks:** `PaletteClickTests` lists every tab's `clickAction` and fails until a new one is in it.
- **Upgrades:** `ScreenshotToolsTests` lists the plugins an upgrade turns on, so a plugin that ships on changes it.
- **Smoke tests:** `SmokeUITests`' section list in `testEverySettingsPageOpens`, and `testPaletteCommandNumberSwitchesTabs`, which expects the number after the last visible tab to do nothing.
- **Wiring snapshot:** `KeybumpsTests/Fixtures/capability-wiring.json`. Re-record it with `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1` in `xcodebuild`'s environment, before the command (after it, it's a build setting and never reaches the tests), and review the diff. It records every combination of the default capabilities, alone and with each added one, so a new plugin adds about 130 combinations instead of doubling them (#455). Combinations are named by the plugins that are on, so a re-record keeps every existing name and adds the new plugin's steps to each, except the everything-on-but-one entries, which it replaces with ones whose names include the new plugin.

Add the plugin's own tests in Swift Testing (`docs/testing.md`).

## 3. Docs in the same PR

- **README:** the plugin list and Quick Search's tab list.
- **architecture.md:** its lists of Quick Search's tabs and shortcut owners, plus any new boundary or seam. Keep it a map.
- **testing.md:** the `-KBOpenPalette` and `-KBOpenSettings` tokens.
- **CONTEXT.md:** any new term.
- **Release notes:** `docs/releases/v<version>.md`, merged before the release PR.

## 4. The website

The website lists every plugin on `/plugins/`, gives each its own page, and builds the home page grid from the same list. Website PRs change only `apps/web/**` (`apps/web/AGENTS.md`).

- **Before the release** that ships the plugin: the privacy page names no plugins (#583), so it needs a change only if the plugin sends data off the Mac or changes what the site collects. Then say it by category, not by feature (ADR 0007).
- **After the release:**
  - an entry in `src/lib/plugins.ts`, copied from the Swift. Move `isNew` to it. A new SF Symbol also goes in the `PluginSystemImage` type;
  - its route folder `src/app/(analytics)/plugins/<slug>/page.tsx`, which `plugins.test.ts` requires. The slug is the plugin's name in lowercase, with hyphens for spaces: the app's Open on keybumps.app (`PluginLinks.page(for:)`) builds the address that way;
  - a tile in the hero list in `src/app/(analytics)/plugins/page.tsx`;
  - the new symbol mapped in `src/components/plugin-icon.tsx`, and a new tint in `iconTints`;
  - the plugin-count floor in `scripts/smoke.sh`;
  - if release notes call it by another name too (a tab name, an older name), those words, exactly as the notes write them (tags match whole words and case), under its slug in `pluginAliases` in `src/lib/changelog.ts`, so `/changelog/` tags the releases that change it.
