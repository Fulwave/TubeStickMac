#!/bin/sh
# Read-only idle test: every INTERVAL seconds read the bridge registers and report whether the stick still answers.
# Usage: tools/idlewatch.sh [interval-seconds] [rounds]
cd "$(dirname "$0")/.."
I="${1:-20}"; N="${2:-12}"; i=0
while [ $i -lt $N ]; do
  i=$((i+1)); sleep $I
  if NOSCAN=1 ./build/em28xxprobe-host 2>&1 | grep -q "chip id (reg 0x0a) = 0x24"; then echo "$(date +%H:%M:%S) after $((i*I)) s idle: answers"; else echo "$(date +%H:%M:%S) after $((i*I)) s idle: NOT RESPONDING"; fi
done
