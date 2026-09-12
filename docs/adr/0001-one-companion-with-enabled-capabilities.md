---
status: accepted
---

# ADR 0003: One companion with independently enabled capabilities

The product, named SuperMac, will be installed and experienced as one sellable macOS app rather than a launcher for several separately visible utilities. It will behave as a quiet companion with one Dock icon, one normal macOS Settings window organized by a sidebar, and a `Command-Space` Quick Search surface for applications, files, and folders. Clicking the Dock icon opens Settings/Home, and the app launches at login by default. Its menu-bar menu remains deliberately limited to Settings, Check for Updates, and Quit rather than duplicating feature commands.

Key Bumps, Dictation, Window Management, Quick Search, and Clipboard History will be independently controllable capabilities under the companion's shared identity and permissions experience. They begin enabled for a simpler first-run experience, Home displays one master switch per capability, and each capability's sidebar screen owns its detailed settings. A capability that the user disables releases its global shortcuts and stops its active monitoring.

Skipping a permission does not block completion of onboarding; the affected capability remains visibly marked as requiring permission and can be repaired later. Clipboard History persists the ten most recent text items locally. Text Snippets are outside the MVP. Any technically necessary invisible helper processes remain a separate decision.

The first release targets Apple Silicon and macOS 14.2 or newer. Distribution, commercial, privacy, and update boundaries are recorded in ADR 0004.

Reversible implementation details—including the new repository's exact name, internal target layout, visual polish, provider selection, and minor interaction behavior—are delegated to implementation judgment and may be adjusted after the integrated MVP can be used.
