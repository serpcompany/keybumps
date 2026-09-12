# ADR 0005: Rename the product and start with a fresh permission identity

Status: accepted

## Decision

The product name is **SuperMac** and its bundle identifier is `com.serp.supermac`.

The repository directory, Xcode project, schemes, targets, Swift module, executable, source root, test root, app entry type, assets, storage directory, and current documentation all use the SuperMac name. The stable permission-sensitive bundle identifier remains `com.serp.supermac`.

SuperMac uses its own `SuperMac` Application Support directory. This is an intentional clean baseline while the product is still pre-release.

## Consequences

- macOS will treat SuperMac as a new app when requesting Accessibility, Input Monitoring, Microphone, and Speech Recognition access.
- The user must grant the new signed SuperMac build its own permissions.
- The bundle identifier becomes stable again after this pre-release rename.
