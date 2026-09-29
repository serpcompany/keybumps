# Keybumps approved-artwork brand pack

This corrected pack is generated directly from the two approved source images:

- `source/keybumps-key-with-accents.png` — the approved keycap logo, unchanged.
- `source/keybumps-mascot-no-accents.png` — the approved standalone mascot, trimmed and centered without redrawing it.

All platform icons are resized or composited from those exact sources. No substitute geometry was introduced.

## Folder guide

- `apple/ios/AppIcon.appiconset/` — current Xcode light, dark, and tinted 1024px icon appearances.
- `apple/macos/Keybumps.icon` — the macOS app icon as an Icon Composer file (keycap and mascot layers on a purple gradient), the same file the app uses. `Keybumps.icns` and `png/` (16–1024 px) are renders of it for other uses; regenerate them from a built app with `swift scripts/render-app-icon.swift <Keybumps.app> <out.iconset>`, then `iconutil -c icns <out.iconset> -o brand/apple/macos/Keybumps.icns` and `cp <out.iconset>/*.png brand/apple/macos/png/`.
- `android/res/` — legacy density icons and adaptive icon resources.
- `web/` — favicon, Apple touch icon, PWA assets, maskable icons, and manifest.
- `social/` — avatar, Open Graph card, and wide banner using the approved artwork.
- `png/` — common-size exports of the approved keycap and mascot.
- `svg/` — faithful SVG containers linked to the approved raster sources. These are intentionally not fake vector redraws.
- `monochrome/` — silhouette variants derived mechanically from the approved pixels for one-color contexts.
- `press/` — PDF and JPEG versions for press use.
- `tokens/` — brand colors as CSS and JSON tokens.
- `brand-preview.png` — both approved marks side by side.

Provenance: original Keybumps artwork approved by the owner; no third-party assets.

## Important SVG note

The approved artwork contains soft raster shading. The SVG files preserve the approved appearance by referencing the corresponding PNG in `source/`. Keep the folder structure together. A true path-only SVG would require a separate vector-redesign approval and would not be pixel-identical.
