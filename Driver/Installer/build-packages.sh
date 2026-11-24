#!/bin/sh
# Xcode build phase of the SideCast app (macOS only): copies the built audio driver into the
# app's resources and wraps it in an installer package plus an uninstaller package.
#
# The packages are unsigned. For distribution, sign them with a Developer ID Installer
# certificate (productsign) and notarize the app.
set -e
[ "$PLATFORM_NAME" = "macosx" ] || exit 0

DRIVER="$BUILT_PRODUCTS_DIR/SideCastAudio.driver"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
WORK="$DERIVED_FILE_DIR/driver-packages"
INSTALLER="$SRCROOT/Driver/Installer"
IDENTIFIER="com.imarkr.SideCast.AudioDriver"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :SideCastDriverVersion" "$DRIVER/Contents/Info.plist")

rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/install-scripts" "$WORK/uninstall-scripts" "$RESOURCES"
ditto "$DRIVER" "$WORK/root/SideCastAudio.driver"
cp "$INSTALLER/postinstall" "$WORK/install-scripts/postinstall"
cp "$INSTALLER/uninstall-postinstall" "$WORK/uninstall-scripts/postinstall"
chmod 755 "$WORK/install-scripts/postinstall" "$WORK/uninstall-scripts/postinstall"

# Always install into /Library/Audio/Plug-Ins/HAL, even if a copy exists somewhere else.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/components.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"

pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --install-location /Library/Audio/Plug-Ins/HAL \
    --identifier "$IDENTIFIER" --version "$VERSION" \
    --scripts "$WORK/install-scripts" \
    "$RESOURCES/SideCast Audio Driver.pkg"
pkgbuild --quiet --nopayload \
    --identifier "$IDENTIFIER.uninstall" --version "$VERSION" \
    --scripts "$WORK/uninstall-scripts" \
    "$RESOURCES/Uninstall SideCast Audio Driver.pkg"

rm -rf "$RESOURCES/SideCastAudio.driver"
ditto "$DRIVER" "$RESOURCES/SideCastAudio.driver"
