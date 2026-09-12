---
status: accepted
---

# ADR 0006: Build SERP Companion in a new canonical repository

SERP Companion will be built in a new repository rather than renaming the Shortcut Coach repository. The new product uses the stable bundle identifier `com.serp.companion`; this identity must remain stable before installed permission acceptance begins because macOS associates permission grants with the signed application identity.

The Shortcut Coach, SERPy, and Window Manager repositories remain intact as donor and evidence sources. This planning repository records the selected behavior and architectural decisions until the new repository exists. The new repository's exact name, source-import strategy, and treatment of donor history remain open decisions.
