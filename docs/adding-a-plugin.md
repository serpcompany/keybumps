# Adding a plugin

A plugin is a capability people turn on or off (`CONTEXT.md`, ADR 0006). It's first-party and ships in the app; there is no external plugin API. This is the checklist for adding one. Timer (#232) and Emoji Picker (#250–#253, #274) are the worked examples; follow their files. App paths below are under `apps/macos/Keybumps/` (tests under `apps/macos/`), and website paths under `apps/web/`.

Ship it in small PRs, in this order: the app's seams first, then the plugin, then the website.

## 1. The app

- **Capability:** a case in `Capability` (`Domain/Capability.swift`).
- **Descriptor and module:** `Capabilities/<Name>Module.swift` declares its `CapabilityDescriptor` and its `CapabilityModule`.
  - **Basics:** the title, `systemImage`, and `iconTint`; search keywords, the category, and any `PluginPreference`s.
  - **Permissions:** required permissions show `MacPermission.explanation` (`Infrastructure/SystemServices.swift`). Add the plugin to the explanation of each one it needs. Optional permissions carry their own reason. (The website entry's permission reasons come in §4.)
  - **Settings page:** its summary, and the explanation the on/off switch shows as a tooltip. New plugins draw their page from the manifest with `PluginSettingsPage`.
  - **Palette tab, if any:** the module's `paletteContent` supplies the rows, and the descriptor's `systemImage` is the tab's icon in the tab bar, so it must differ from the other tabs'. The tab takes the next Command-number, and the hidden Hotkeys tab moves to stay last. Emoji Picker took ⌘7, then Translation took ⌘8 and Hotkeys moved to ⌘9. Moving Hotkeys also changes:
    - `KeyboardShortcutterModule`'s `commandKey`;
    - the README and architecture.md tab lists, and the release notes;
    - Shortcut Coach's `commandKey` in the website's `plugins.ts`, whose test requires unique numbers.

    The palette matches one typed digit, and Hotkeys now has ⌘9, the last one: a tenth tab needs another way in.
  - **`isOnByDefault`:** most plugins ship on. Emoji Picker and Translation ship off. Several tests depend on this choice (§2).
  - **`minimumMacOS`:** set it when the plugin needs a newer macOS than Keybumps does, as Translation needs 15. `PluginCompatibility` then keeps it off on older Macs and Settings says why; give its macOS-only code an inert path for the older ones.
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

- **Plugin lists:** `CapabilityCommandTests`, `CapabilityModuleTests`, `KeybumpsFeatureTests`, `PluginManifestTests`, `QuickSearchCommandTests`, `SettingsSidebarTests`, `UITestLaunchConfigurationTests`.
- **Palette numbering:** a new tab moves Hotkeys and the first unused number, which these check:
  - `SnippetTests`' tab order and tab keys;
  - `EmojiPickerTests` (Hotkeys' number);
  - `KeybumpsFeatureTests`, which expects ⌘0 to match nothing.
- **Upgrades:** `ScreenshotToolsTests` lists the plugins an upgrade turns on, so a plugin that ships on changes it.
- **Smoke tests:** `SmokeUITests`' section list in `testEverySettingsPageOpens`, and `testPaletteCommandNumberSwitchesTabs`, which expects the number after the last visible tab to do nothing.
- **Wiring snapshot:** `KeybumpsTests/Fixtures/capability-wiring.json`. Re-record it with `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1` in `xcodebuild`'s environment, before the command (after it, it's a build setting and never reaches the tests), and review the diff. It records every combination of plugins, so each new plugin roughly doubles it.

Add the plugin's own tests in Swift Testing (`docs/testing.md`).

## 3. Docs in the same PR

- **README:** the plugin list and the Command Palette tab list.
- **architecture.md:** its lists of palette tabs and shortcut owners, plus any new boundary or seam. Keep it a map.
- **testing.md:** the `-KBOpenPalette` and `-KBOpenSettings` tokens.
- **CONTEXT.md:** any new term.
- **Release notes:** `docs/releases/v<version>.md`, merged before the release PR.

## 4. The website

The website lists every plugin on `/plugins/`, gives each its own page, and builds the home page grid from the same list. Website PRs change only `apps/web/**` (`apps/web/AGENTS.md`).

- **Before the release** that ships the plugin: add it to the privacy page (`src/app/(analytics)/legal/privacy/page.tsx`), which names every plugin. Say what it keeps on the Mac and anything it sends off it (ADR 0007).
- **After the release:**
  - an entry in `src/lib/plugins.ts`, copied from the Swift. Move `isNew` to it. A new SF Symbol also goes in the `PluginSystemImage` type;
  - its route folder `src/app/(analytics)/plugins/<slug>/page.tsx`, which `plugins.test.ts` requires;
  - a tile in the hero list in `src/app/(analytics)/plugins/page.tsx`;
  - the new symbol mapped in `src/components/plugin-icon.tsx`, and a new tint in `iconTints`;
  - the plugin-count floor in `scripts/smoke.sh`.
