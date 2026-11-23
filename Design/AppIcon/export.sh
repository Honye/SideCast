#!/bin/zsh
# Regenerates every app icon image from the SVG sources into SideCast/Assets.xcassets.
# Usage: Design/AppIcon/export.sh
set -euo pipefail
here=${0:A:h}
assets=${here:h:h}/SideCast/Assets.xcassets
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

cd $here
python3 make_svgs.py >/dev/null
swiftc -O render.swift -o $tmp/render

# iOS / iPadOS: full-bleed squares; the system applies the corner mask.
icons=$assets/AppIcon.appiconset
$tmp/render icon-light.svg $icons/ios-1024.png 1024 opaque
$tmp/render icon-dark.svg $icons/ios-1024-dark.png 1024 plain
$tmp/render icon-dark.svg $icons/ios-1024-tinted.png 1024 grayscale

# macOS: rounded square on the macOS icon grid, with shadow.
for size in 16 32; do
  $tmp/render icon-small.svg $icons/mac-$size.png $size mac
done
for size in 64 128 256 512 1024; do
  $tmp/render icon-light.svg $icons/mac-$size.png $size mac
done

# visionOS: three layers of a circular icon.
stack=$assets/AppIcon-vision.solidimagestack
for layer in Back Middle Front; do
  lower=${(L)layer}
  $tmp/render vision-$lower.svg $stack/$layer.solidimagestacklayer/Content.imageset/$lower.png 1024 plain
done
echo "Exported app icons to $assets"
