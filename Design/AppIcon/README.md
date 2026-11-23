# SideCast app icon

A music note flies along a dotted arc from a MacBook (playing media) to an iPad (play button),
on a deep purple background.

| File | Use |
|---|---|
| `make_svgs.py` | Generates every SVG source below. Edit the artwork here |
| `icon-light.svg` | Main art: iOS (full bleed) and macOS 64–1024 px |
| `icon-dark.svg` | iOS dark appearance (transparent background) and tinted appearance (grayscale) |
| `icon-small.svg` | macOS 16 and 32 px: simplified, enlarged |
| `vision-*.svg` | visionOS layers (back, middle, front), scaled into the circle |
| `render.swift` | Renders an SVG to PNG (plain, opaque, macOS rounded square with shadow, grayscale) |
| `export.sh` | Regenerates all icon PNGs into `SideCast/Assets.xcassets` |

After changing the artwork, run `Design/AppIcon/export.sh`.
