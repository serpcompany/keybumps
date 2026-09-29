# Keybumps domain

Keybumps is one installed native macOS companion with six independently enabled capabilities presented through shared app surfaces.

## Language

**Capability**:
A user-enabled area providing one coherent outcome. Disabling it stops the resources and shortcuts it owns.
_Avoid_: Mini-app, embedded app

**Capability Module**:
The first-party unit that implements one Capability and is registered with the app shell: a descriptor (names, icon, required permissions, dependencies, optional Command Palette tab, Settings page, onboarding card, and update-safety operations) plus the runtime owner of its resources and shortcuts. Internal only; not an extension point.
_Avoid_: Plugin, extension, mini-app

**Command Palette**:
The single floating, keyboard-first surface with Search, Clipboard, Screenshots, Dictation, and Hotkeys tabs (Command-1 to 5; Hotkeys hidden by default).
_Avoid_: Quick Search panel, Clipboard panel, Alfred clone, Raycast clone

**Quick Search**:
The default Command Palette tab for finding local applications, files, and folders.
_Avoid_: Web search, workflow launcher

**Clipboard History**:
The Command Palette tab containing the fifty most recent user-originated local text or image clipboard items, with visual previews for images. Keybumps's temporary pasteboard writes for automatic Dictation delivery are not clipboard activity.
_Avoid_: Permanent clipboard archive, Dictation History duplicate

**Dictation**:
The Option-Space session that records speech, transcribes locally, and inserts text at the original cursor.
_Avoid_: Voice guide, assistant

**Dictation History**:
The local per-recording archive of completed Dictation transcripts and playable audio, shown in its dedicated History screen and exposed for transcript reuse in the Command Palette.
_Avoid_: Cloud transcript, monolithic history file

**Window Manager**:
Rectangle-derived window movement and sizing under the owner's selected shortcuts.
_Avoid_: Rectangle app, Window Management

**Shortcut Coach**:
Passive recognition of currently supported manual actions, durable history, and selected presentations.
_Avoid_: Keyboard Shortcutter (its former name; code types still use `KeyboardShortcutter`), Shortcut Coaching, Keylume app

**Hotkeys**:
The Command Palette tab label for Shortcut Coach history, hidden unless the owner shows it. Settings and the capability keep the name Shortcut Coach.

**Screenshot Tools**:
The capability that takes screenshots with its own hotkeys (Shift-Command-2 screens, Shift-Command-3 screens then edit, Shift-Command-4 area), adds screenshots macOS or Keybumps saves to Clipboard History as screenshot items, and owns the **Screenshot Editor**. While its hotkeys use macOS's Shift-Command-3/4, it turns those macOS shortcuts off and gives them back when it stops using them.
_Avoid_: Screen capture, screenshot app, CleanShot clone

**Screenshots tab**:
The ⌘3 Command Palette tab showing screen-capture items from Clipboard History as a grid of thumbnail cards; Return opens the Screenshot Editor. Owned by Screenshot Tools.
_Avoid_: Screenshot library, gallery

**Screenshot Editor**:
The Screenshot Tools window that marks up a Clipboard History image with pixelate, redact, arrow, draw, and text, then copies the flattened result and saves an `(edited)` copy.
_Avoid_: Image editor, annotation app, Markup

**Notch notice**:
A brief message, such as Copied to Clipboard or a Shortcut Coach tip, that grows out of the notch (or the top of the menu bar on screens without one) and fades on its own.
_Avoid_: Toast, HUD, banner

**License**:
A customer's right to use Keybumps, created by the SERP licensing service when a purchase is paid and revoked on refund, dispute, or an ended subscription. It carries one Entitlement. See `docs/adr/0001-licensing.md`.
_Avoid_: Account, subscription (a subscription is only one kind of Offer)

**License Key**:
The customer-facing code (`KB-XXXX-XXXX-XXXX-XXXX`) that identifies a License and is entered in the app to activate it.
_Avoid_: Serial, registration code, password

**Entitlement**:
What a License allows: `validUntil` (absent means perpetual), `updatesUntil` (builds released after it are not entitled), and `maxActivations`. The app enforces only these fields and never sees prices.
_Avoid_: Plan, tier

**Offer**:
One purchasable checkout variant (price, provider product, and the Entitlement it grants). Offers are how pricing is tested. They live only on the licensing service and the website.
_Avoid_: SKU, price (in app code)

**Activation**:
Binding a License to one Mac's device hash, up to `maxActivations`. Deactivating from the app frees the slot.
_Avoid_: Registration, login

**Lease**:
The Ed25519-signed payload the licensing service returns on Activation or refresh. The app verifies it offline, refreshes it after `refreshAfter`, and stops honoring it after `expiresAt`. Revocation takes effect when the Lease is refreshed or expires.
_Avoid_: Token, license file

**Locked**:
The app state without an entitled Lease. Capabilities do not start, and only onboarding, the License settings page, and Quit are available. There is no trial.
_Avoid_: Trial mode, demo mode, unregistered
