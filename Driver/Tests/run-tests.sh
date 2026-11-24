#!/bin/sh
# Builds the audio driver together with its tests and runs them, without installing anything.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/sidecast-driver-tests"
clang -Wall -Wextra -Wno-unused-parameter -Wno-four-char-constants -fblocks \
    -DkSideCastHeartbeatTimeout=1.0 \
    -framework CoreFoundation -framework CoreAudio \
    -o "$OUT" DriverTests.c ../Source/SideCastAudioDriver.c
"$OUT"
