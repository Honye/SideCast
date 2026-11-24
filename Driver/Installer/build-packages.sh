#!/bin/sh
# Xcode build phase of the SideCast app (macOS only): copies the built audio driver into the
# app's resources and wraps it in an installer package plus an uninstaller package.
#
# The packages are unsigned here; scripts/release-website.sh rebuilds them signed with
# Developer ID for distribution.
set -e
[ "$PLATFORM_NAME" = "macosx" ] || exit 0

RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
# The Mac App Store version can't install drivers (PRD 3.2): ship neither the driver nor packages.
if [ "$SIDECAST_DISTRIBUTION" = "APP_STORE" ]; then
    rm -rf "$RESOURCES/SideCastAudio.driver" "$RESOURCES/SideCast Audio Driver.pkg" "$RESOURCES/Uninstall SideCast Audio Driver.pkg"
    exit 0
fi

DRIVER="$BUILT_PRODUCTS_DIR/SideCastAudio.driver"
"$SRCROOT/Driver/Installer/make-packages.sh" "$DRIVER" "$RESOURCES"
rm -rf "$RESOURCES/SideCastAudio.driver"
ditto "$DRIVER" "$RESOURCES/SideCastAudio.driver"
