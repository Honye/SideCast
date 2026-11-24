#!/bin/sh
# Archives the Mac App Store version of SideCast (AppStore build configuration: no audio
# driver, no non-public APIs). The archive shows up in Xcode › Window › Organizer, where
# "Distribute App › App Store Connect" uploads it.
#
#   scripts/archive-app-store.sh [archive path]
set -e
cd "$(dirname "$0")/.."
STAMP=$(date +%Y-%m-%d)
ARCHIVE="${1:-$HOME/Library/Developer/Xcode/Archives/$STAMP/SideCast App Store $(date +%H.%M.%S).xcarchive}"

xcodebuild archive -quiet \
    -project SideCast.xcodeproj -scheme SideCast -configuration AppStore \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

APP="$ARCHIVE/Products/Applications/SideCast.app"
if ls "$APP/Contents/Resources" | grep -q -i -E 'driver|\.pkg$'; then
    echo "error: the App Store build contains the audio driver or its packages" >&2
    exit 1
fi
if strings -a "$APP/Contents/MacOS/SideCast" | grep -q responsibility_get_pid; then
    echo "error: the App Store build references a non-public API" >&2
    exit 1
fi
echo "Archived the Mac App Store version: $ARCHIVE"
echo "Upload it from Xcode › Window › Organizer › Distribute App › App Store Connect."
