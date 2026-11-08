#!/bin/sh
# Live ATSC viewing: firmware load, tune, stream to VLC over loopback UDP. Ctrl-C stops the stream cleanly.
# Usage: tools/live.sh [rf-channel]      (default 27; needs local/xc5000_sequence.bin and build/em28xxprobe-host)
set -e
cd "$(dirname "$0")/.."
CH="${1:-27}"; PORT=1234
[ -x build/em28xxprobe-host ] || clang -w -fobjc-arc -DUSE_USBHOST -o build/em28xxprobe-host tools/em28xxprobe.c tools/tshost.m \
  -framework IOKit -framework CoreFoundation -framework Foundation -framework IOUSBHost
echo "Loading tuner firmware..."
NOSCAN=1 XCFW=local/xc5000_sequence.bin ./build/em28xxprobe-host --i2c | grep -E "firmware load|product id: 0x1388" | head -2
echo "Opening VLC on udp://@127.0.0.1:$PORT ..."
osascript -e 'tell application "VLC" to quit' >/dev/null 2>&1 || true
sleep 1
# Start VLC's own binary with the address: "open -a VLC --args" is ignored when VLC is already running.
/Applications/VLC.app/Contents/MacOS/VLC --network-caching=1000 "udp://@127.0.0.1:$PORT" >/dev/null 2>&1 &
sleep 3
echo "Streaming RF channel $CH. Press Ctrl-C here to stop."
UDP=127.0.0.1:$PORT OUT=- SECS="${SECS:-86400}" NOSCAN=1 USBHOST=1 ALT=4 EP=84 ./build/em28xxprobe-host --i2c --capture "$CH"
