<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# SuperMac 0.0.2-beta.4

- Promotes the owner-accepted issue #15 permission and notification recovery work onto the canonical `main` branch.
- Keeps all permission rows visible and restores convenient System Settings actions for missing permissions.
- Preserves working native Key Bumps notification delivery and click routing.
- Embeds the exact source commit, branch, and build kind in every app bundle.
- Adds fail-closed release guards so public builds must come from clean, synchronized `main`.
- Gives feature-branch candidates development-only versions and build manifests instead of public-looking beta numbers.
