# Keybumps approved-artwork brand pack

This corrected pack is generated directly from the two approved source images:

- `source/keybumps-approved.png` — the approved keycap logo, unchanged.
- `source/keybumps-mascot-approved.png` — the approved standalone mascot, trimmed and centered without redrawing it.

All platform icons are resized or composited from those exact sources. No substitute geometry was introduced.

## Folder guide

- `apple/ios/AppIcon.appiconset/` — current Xcode light, dark, and tinted 1024px icon appearances.
- `apple/macos/AppIcon.appiconset/` and `Keybumps.icns` — complete macOS assets.
- `android/res/` — legacy density icons and adaptive icon resources.
- `web/` — favicon, Apple touch icon, PWA assets, maskable icons, and manifest.
- `social/` — avatar, Open Graph card, and wide banner using the approved artwork.
- `png/` — common-size exports of the approved keycap and mascot.
- `svg/` — faithful SVG containers linked to the approved raster sources. These are intentionally not fake vector redraws.
- `monochrome/` — silhouette variants derived mechanically from the approved pixels for one-color contexts.

## Important SVG note

The approved artwork contains soft raster shading. The SVG files preserve the approved appearance by referencing the corresponding PNG in `source/`. Keep the folder structure together. A true path-only SVG would require a separate vector-redesign approval and would not be pixel-identical.
