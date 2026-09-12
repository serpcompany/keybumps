# ADR 0005: Rename the product and start with a fresh permission identity

Status: accepted

## Decision

The product name is **SuperMac** and its bundle identifier is `com.serp.supermac`.

The repository directory, Xcode project, scheme, Swift module, and executable may retain the internal `SERPCompanion` name. Those identifiers are implementation details and do not appear as the installed app name.

SuperMac uses its own `SuperMac` Application Support directory and does not migrate preferences, history, or macOS permission state from `com.serp.companion`. This is an intentional fresh start while the product is still pre-release.

## Consequences

- macOS will treat SuperMac as a new app when requesting Accessibility, Input Monitoring, Microphone, and Speech Recognition access.
- The user must grant the new signed SuperMac build its own permissions.
- Previously granted `com.serp.companion` permissions do not satisfy SuperMac permission checks.
- The bundle identifier becomes stable again after this pre-release rename.
