#!/bin/sh
# Repeated start/stop test: N captures of SECS seconds on one RF channel; reports bytes each time, stops at the first failure.
# Usage: tools/cyclewatch.sh [channel] [rounds] [secs] [pause-seconds]
cd "$(dirname "$0")/.."
CH="${1:-3}"; N="${2:-12}"; S="${3:-5}"; P="${4:-0}"; i=0
NOSCAN=1 XCFW=local/xc5000_sequence.bin ./build/em28xxprobe-host --i2c 2>&1 | grep -E "product id: 0x1388" | head -1
while [ $i -lt $N ]; do
  i=$((i+1))
  OUT=$(NOSCAN=1 USBHOST=1 ALT=4 EP=84 SECS=$S OUT=- ./build/em28xxprobe-host --i2c --capture "$CH" 2>&1 | grep -E "^captured" )
  B=$(echo "$OUT" | sed -n 's/^captured \([0-9]*\) bytes.*/\1/p')
  echo "$(date +%H:%M:%S) capture $i: ${B:-FAILED} bytes"
  [ -z "$B" ] || [ "$B" = "0" ] && { echo "stopped: the stick stopped streaming at capture $i"; break; }
  [ "$P" -gt 0 ] && sleep "$P"
done
