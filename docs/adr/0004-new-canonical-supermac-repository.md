---
status: accepted
---

# ADR 0006: Build SuperMac in a new canonical repository

SuperMac will be built in a new repository rather than renaming the Shortcut Coach repository. The new product uses the stable bundle identifier `com.serp.supermac`; this identity must remain stable before installed permission acceptance begins because macOS associates permission grants with the signed application identity.

The Shortcut Coach, SERPy, and Window Manager repositories remain intact as donor and evidence sources. `/Users/devin/dev/repos/supermac-macos-app` is the canonical implementation repository. Donor history remains documented through the provenance ledger rather than copied Git history.
