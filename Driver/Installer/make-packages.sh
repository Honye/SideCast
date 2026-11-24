#!/bin/sh
# Wraps a built SideCast audio driver in an installer package and an uninstaller package.
#
#   make-packages.sh <SideCastAudio.driver> <output folder> [installer signing identity]
#
# Used by build-packages.sh (Xcode build, unsigned packages) and by
# scripts/release-website.sh (signed with a Developer ID Installer certificate).
set -e
DRIVER="$1"
OUT="$2"
SIGN_IDENTITY="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
IDENTIFIER="com.imarkr.SideCast.AudioDriver"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :SideCastDriverVersion" "$DRIVER/Contents/Info.plist")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidecast-packages.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/root" "$WORK/install-scripts" "$WORK/uninstall-scripts" "$OUT"
ditto "$DRIVER" "$WORK/root/SideCastAudio.driver"
cp "$HERE/postinstall" "$WORK/install-scripts/postinstall"
cp "$HERE/uninstall-postinstall" "$WORK/uninstall-scripts/postinstall"
chmod 755 "$WORK/install-scripts/postinstall" "$WORK/uninstall-scripts/postinstall"

# Always install into /Library/Audio/Plug-Ins/HAL, even if a copy exists somewhere else.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/components.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"

set -- --quiet
if [ -n "$SIGN_IDENTITY" ]; then
    set -- --quiet --sign "$SIGN_IDENTITY" --timestamp
fi
pkgbuild "$@" --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --install-location /Library/Audio/Plug-Ins/HAL \
    --identifier "$IDENTIFIER" --version "$VERSION" \
    --scripts "$WORK/install-scripts" \
    "$OUT/SideCast Audio Driver.pkg"
pkgbuild "$@" --nopayload \
    --identifier "$IDENTIFIER.uninstall" --version "$VERSION" \
    --scripts "$WORK/uninstall-scripts" \
    "$OUT/Uninstall SideCast Audio Driver.pkg"
