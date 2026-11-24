#!/bin/sh
# Builds the website (Developer ID) version of SideCast: archive, sign with Developer ID
# (app, audio driver and its installer packages), notarize, staple, and wrap in a DMG.
#
#   scripts/release-website.sh [output folder]
#
# Needs, once:
#   - "Developer ID Application" and "Developer ID Installer" certificates of team
#     JUWHF23XW6 in the login keychain (Xcode › Settings › Accounts › Manage Certificates).
#   - Notarization credentials saved in the keychain:
#       xcrun notarytool store-credentials SideCast --apple-id <Apple ID> --team-id JUWHF23XW6
#     (use an app-specific password). Set NOTARY_PROFILE to use another profile name.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="${1:-$ROOT/build/website}"
TEAM=JUWHF23XW6
NOTARY_PROFILE="${NOTARY_PROFILE:-SideCast}"

identity() {
    security find-identity -v -p "$1" | sed -n "s/.*\"\($2: .*($TEAM)\)\"/\1/p" | head -1
}
APP_IDENTITY=$(identity codesigning "Developer ID Application")
INSTALLER_IDENTITY=$(identity basic "Developer ID Installer")
if [ -z "$APP_IDENTITY" ] || [ -z "$INSTALLER_IDENTITY" ]; then
    echo "error: missing Developer ID certificates of team $TEAM in the keychain:" >&2
    [ -z "$APP_IDENTITY" ] && echo "  - Developer ID Application" >&2
    [ -z "$INSTALLER_IDENTITY" ] && echo "  - Developer ID Installer" >&2
    echo "Create them in Xcode › Settings › Accounts › Manage Certificates." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarization credentials named \"$NOTARY_PROFILE\". Save them with:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/SideCast.xcarchive"
WORK="$OUT/work"
mkdir -p "$WORK"

echo "› Archiving (Release, website version)"
xcodebuild archive -quiet \
    -project SideCast.xcodeproj -scheme SideCast -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

echo "› Exporting with Developer ID"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export"
APP="$WORK/export/SideCast.app"
RESOURCES="$APP/Contents/Resources"

echo "› Signing the audio driver and its packages with Developer ID"
DRIVER="$WORK/SideCastAudio.driver"
ditto "$RESOURCES/SideCastAudio.driver" "$DRIVER"
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$DRIVER"
rm -rf "$RESOURCES/SideCastAudio.driver" "$RESOURCES/SideCast Audio Driver.pkg" "$RESOURCES/Uninstall SideCast Audio Driver.pkg"
"$ROOT/Driver/Installer/make-packages.sh" "$DRIVER" "$RESOURCES" "$INSTALLER_IDENTITY"
ditto "$DRIVER" "$RESOURCES/SideCastAudio.driver"

echo "› Re-signing the app"
codesign -d --entitlements - --xml "$APP" > "$WORK/entitlements.plist" 2>/dev/null
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" \
    --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
pkgutil --check-signature "$RESOURCES/SideCast Audio Driver.pkg" >/dev/null

notarize() {
    echo "› Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
ditto -c -k --keepParent "$APP" "$WORK/SideCast.zip"
notarize "$WORK/SideCast.zip"
xcrun stapler staple "$APP"

echo "› Making the disk image"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/SideCast-$VERSION.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SideCast.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname SideCast -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --timestamp --sign "$APP_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"

echo "Done: $DMG"
